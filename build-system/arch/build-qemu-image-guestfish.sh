#!/bin/bash
# RegicideOSArch QEMU Disk Image Builder (pure guestfish + systemd-boot)
# Creates a bootable QCOW2 disk image from a RegicideOSArch tarball.
# Uses only libguestfs/guestfish; no host loop devices, no chroot, no guestmount.
# This is the default builder for UNENCRYPTED images. Use build-qemu-image.sh for LUKS2.

set -euo pipefail

# Use the libguestfs direct backend so we do not depend on libvirt.
export LIBGUESTFS_BACKEND=direct

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARBALL=""
OUTPUT="${SCRIPT_DIR}/output/regicide-arch.qcow2"
DISK_SIZE="${REGICIDE_DISK_SIZE:-20G}"
EFI_SIZE="${REGICIDE_EFI_SIZE:-512M}"
ROOTS_SIZE="${REGICIDE_ROOTS_SIZE:-14G}"
OVERLAY_SIZE="${REGICIDE_OVERLAY_SIZE:-4G}"
ENCRYPT=false
PASSPHRASE_FILE=""
POS=0

usage() {
    cat << EOF
Usage: $0 [OPTIONS] <regicide-arch-tarball> [output-qcow2] [disk-size]

  regicide-arch-tarball  Path to the regicide-arch .tar or .tar.xz tarball (required)
  output-qcow2           Path for the output .qcow2 file (optional)
  disk-size              Disk size for the image, e.g. 20G (optional, default: 20G)

Options:
  --encrypt              Not supported by the guestfish builder; use build-qemu-image.sh for LUKS2.
  --passphrase-file      Path to a file containing the LUKS passphrase
                         (required with --encrypt; use - for stdin)

Examples:
  $0 /path/to/regicide-arch.tar.xz
  $0 /path/to/regicide-arch.tar.xz ./my-image.qcow2 30G
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --encrypt)
            ENCRYPT=true
            shift
            ;;
        --passphrase-file)
            PASSPHRASE_FILE="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Error: unknown option: $1"
            usage
            ;;
        *)
            case "${POS}" in
                0) TARBALL="$1" ;;
                1) OUTPUT="$1" ;;
                2) DISK_SIZE="$1" ;;
                *)
                    echo "Error: unexpected positional argument: $1"
                    usage
                    ;;
            esac
            POS=$((POS + 1))
            shift
            ;;
    esac
done

if [[ -z "${TARBALL}" ]]; then
    echo "Error: tarball path is required."
    usage
fi

if [[ ! -f "${TARBALL}" ]]; then
    echo "Error: tarball not found: ${TARBALL}"
    exit 1
fi

if [[ "${ENCRYPT}" == true ]]; then
    echo "Error: encrypted images are not supported by the guestfish builder yet."
    echo "Use build-qemu-image.sh on a host with loop device support for encryption."
    exit 1
fi

REQUIRED_CMDS=(qemu-img guestfish sgdisk)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "${cmd}" &> /dev/null; then
        echo "Error: required command '${cmd}' not found."
        exit 1
    fi
done

TARBALL="$(realpath -e "${TARBALL}")"
OUTPUT="$(realpath -m "${OUTPUT}")"
OUTPUT_DIR="$(dirname "${OUTPUT}")"
mkdir -p "${OUTPUT_DIR}"

TAR_COMPRESS=""
if [[ "${TARBALL}" == *.tar.xz || "${TARBALL}" == *.txz ]]; then
    TAR_COMPRESS="compress:xz"
elif [[ "${TARBALL}" == *.tar.gz || "${TARBALL}" == *.tgz ]]; then
    TAR_COMPRESS="compress:gz"
fi

RAW_IMG="$(mktemp --suffix=.raw)"

cleanup() {
    echo "Cleaning up..."
    rm -f "${RAW_IMG}" 2>/dev/null || true
    rm -f "${PLAIN_TAR}" 2>/dev/null || true
    rm -rf "${UNTARRED_DIR}" 2>/dev/null || true
    rm -f "${SEED_TARBALL}" 2>/dev/null || true
    rm -f "${SEED_SCRIPT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "Creating raw disk image (${DISK_SIZE})..."
qemu-img create -f raw "${RAW_IMG}" "${DISK_SIZE}"

echo "Partitioning disk image..."
sgdisk --clear "${RAW_IMG}"
sgdisk --new=1:0:+"${EFI_SIZE}"   --typecode=1:ef00 --change-name=1:EFI     "${RAW_IMG}"
sgdisk --new=2:0:+"${ROOTS_SIZE}"  --typecode=2:8300 --change-name=2:ROOTS   "${RAW_IMG}"
sgdisk --new=3:0:+"${OVERLAY_SIZE}" --typecode=3:8300 --change-name=3:OVERLAY "${RAW_IMG}"
sgdisk --new=4:0:0         --typecode=4:8300 --change-name=4:HOME    "${RAW_IMG}"

EFI_IDX=1
ROOTS_IDX=2
OVERLAY_IDX=3
HOME_IDX=4

echo "Decompressing tarball on host for efficient guestfish tar-in..."
UNTARRED_DIR="/var/tmp/regicide-rootfs-staging"
rm -rf "${UNTARRED_DIR}"
mkdir -p "${UNTARRED_DIR}"
PLAIN_TAR="/var/tmp/regicide-arch.tar"
rm -f "${PLAIN_TAR}"
if [[ "${TARBALL}" == *.tar.xz || "${TARBALL}" == *.txz ]]; then
    xz -cd "${TARBALL}" > "${PLAIN_TAR}"
elif [[ "${TARBALL}" == *.tar.gz || "${TARBALL}" == *.tgz ]]; then
    gzip -cd "${TARBALL}" > "${PLAIN_TAR}"
else
    cp "${TARBALL}" "${PLAIN_TAR}"
fi

echo "Formatting partitions, creating overlay subvolumes, and extracting tarball via guestfish..."
guestfish <<GFISH
  add-drive "${RAW_IMG}" format:raw
  run
  mkfs vfat "/dev/sda${EFI_IDX}" label:EFI
  mkfs btrfs "/dev/sda${ROOTS_IDX}" label:ROOTS
  mkfs btrfs "/dev/sda${OVERLAY_IDX}" label:OVERLAY
  mkfs btrfs "/dev/sda${HOME_IDX}" label:HOME

  # Create overlay subvolumes and workdirs
  mount "/dev/sda${OVERLAY_IDX}" /
  btrfs-subvolume-create /etc
  btrfs-subvolume-create /var
  btrfs-subvolume-create /usr
  btrfs-subvolume-create /home
  mkdir-p /etcw
  mkdir-p /varw
  mkdir-p /usrw
  umount /

  # Extract plain tarball into ROOTS (avoids xz decompression inside appliance).
  # ROOTS was enlarged to 14G to accommodate the NVIDIA stack + podman/distrobox
  # + Flatpak apps that now live in /var.
  mount "/dev/sda${ROOTS_IDX}" /
  tar-in "${PLAIN_TAR}" /
  mkdir-p /overlay
  mkdir-p /home
  mkdir-p /boot/efi
  mkdir-p /tmp
GFISH

rm -f "${PLAIN_TAR}"

# Populate the separate HOME partition with /home contents from the tarball.
# Without this, LABEL=HOME mounts an empty /home and the regicide user has no home directory.
echo "Extracting /home contents for HOME partition..."
rm -rf /tmp/regicide-home-staging
mkdir -p /tmp/regicide-home-staging
if [[ "${TARBALL}" == *.tar.xz || "${TARBALL}" == *.txz ]]; then
    xz -cd "${TARBALL}" | tar -C /tmp/regicide-home-staging -f - --wildcards --extract 'home/*' 2>/dev/null || true
elif [[ "${TARBALL}" == *.tar.gz || "${TARBALL}" == *.tgz ]]; then
    tar -C /tmp/regicide-home-staging -f "${TARBALL}" --wildcards --extract 'home/*' 2>/dev/null || true
else
    tar -C /tmp/regicide-home-staging -f "${TARBALL}" --wildcards --extract 'home/*' 2>/dev/null || true
fi
# Fix ownership of staged home contents on the host before copying into the image.
if [[ -d /tmp/regicide-home-staging/home/regicide ]]; then
    chown -R 1000:1000 /tmp/regicide-home-staging/home/regicide
    chmod 0700 /tmp/regicide-home-staging/home/regicide
    find /tmp/regicide-home-staging/home/regicide -type f -exec chmod 0644 {} \;
    guestfish <<GFISH
      add-drive "${RAW_IMG}" format:raw
      run
      mount "/dev/sda${HOME_IDX}" /
      chmod 0755 /
      copy-in /tmp/regicide-home-staging/home/regicide /
      umount /
GFISH
fi
rm -rf /tmp/regicide-home-staging

echo "Verifying kernel and initramfs in ROOTS..."
guestfish <<GFISH &> /tmp/guestfish-verify.log
  add-drive "${RAW_IMG}" format:raw
  run
  mount "/dev/sda${ROOTS_IDX}" /
  is-file /boot/vmlinuz-linux
  is-file /boot/initramfs-linux.img
GFISH
if [[ "$(grep -c '^true$' /tmp/guestfish-verify.log 2>/dev/null || echo 0)" -ne 2 ]]; then
    echo "Error: /boot/vmlinuz-linux or /boot/initramfs-linux.img not found in tarball."
    echo "Make sure the tarball was built with mkinitcpio run before packaging."
    cat /tmp/guestfish-verify.log
    exit 1
fi
rm -f /tmp/guestfish-verify.log

echo "Pre-seeding overlay upperdir directory trees to prevent overlayfs EXDEV..."
SEED_TARBALL="$(mktemp --suffix=.tar)"
SEED_SCRIPT="$(mktemp)"
cat > "${SEED_SCRIPT}" <<'PYEOF'
import os
import sys
import tarfile

src_path = sys.argv[1]
out_path = sys.argv[2]

dirs_to_seed = {"etc", "var", "usr"}
added = set()

def should_skip_symlink(m):
    if not m.issym():
        return False
    top = m.name.split("/", 1)[0]
    # /var contains symlinks that escape the overlay (run, lock, tmp). Skip all
    # symlinks there so the overlay can provide real directories instead.
    if top == "var":
        return True
    target = (m.linkname or "").strip()
    # Skip absolute symlinks that escape their top-level directory.
    if target.startswith("/") and not target.startswith("/" + top + "/"):
        return True
    return False

with tarfile.open(src_path, "r") as src, tarfile.open(out_path, "w") as out:
    for member in src.getmembers():
        top = member.name.split("/", 1)[0]
        if top not in dirs_to_seed:
            continue
        if not member.isdir() and not member.issym():
            continue
        if should_skip_symlink(member):
            continue
        if member.name in added:
            continue
        added.add(member.name)
        out.addfile(member)

    for extra in ["etcw", "varw", "usrw"]:
        info = tarfile.TarInfo(extra)
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        info.uid = 0
        info.gid = 0
        out.addfile(info)
PYEOF
python3 "${SEED_SCRIPT}" "${TARBALL}" "${SEED_TARBALL}"
rm -f "${SEED_SCRIPT}"

guestfish <<GFISH
  add-drive "${RAW_IMG}" format:raw
  run
  mount "/dev/sda${OVERLAY_IDX}" /
  tar-in "${SEED_TARBALL}" /
  umount /
GFISH

rm -f "${SEED_TARBALL}"
echo "Done seeding overlay directory trees."

echo "Writing /etc/fstab inside guestfish..."
FSTAB_TMP="$(mktemp)"
cat > "${FSTAB_TMP}" << EOF
# RegicideOSArch QEMU image fstab
# Generated by build-qemu-image-guestfish.sh

LABEL=ROOTS   /       btrfs   defaults,noatime,ro           0 0
LABEL=OVERLAY /overlay btrfs   defaults,noatime           0 0
LABEL=HOME    /home   btrfs   defaults,noatime           0 0
EOF

MODULES_TMP="$(mktemp)"
cat > "${MODULES_TMP}" << EOF
btrfs
EOF

MASK_TMP="$(mktemp)"
cat > "${MASK_TMP}" << EOF
#!/bin/bash
systemctl mask systemd-nsresourced.service
systemctl mask systemd-confext.service
systemctl mask systemd-sysext.service
systemctl mask systemd-homed.service
systemctl mask systemd-homed-activate.service
EOF

echo "Creating overlay runtime directories and systemd mount units..."

HOSTNAME_TMP="$(mktemp)"
cat > "${HOSTNAME_TMP}" << EOF
RegicideOSArch
EOF

HOSTS_TMP="$(mktemp)"
cat > "${HOSTS_TMP}" << EOF
127.0.0.1\tlocalhost
127.0.1.1\tRegicideOSArch\tRegicideOSArch
::1\t\tlocalhost ip6-localhost ip6-loopback
ff02::1\t\tip6-allnodes
ff02::2\t\tip6-allrouters
EOF

ETC_MOUNT_TMP="$(mktemp)"
cat > "${ETC_MOUNT_TMP}" << EOF
[Unit]
Description=Overlay mount for /etc
Requires=overlay.mount
After=overlay.mount local-fs-pre.target
Before=local-fs.target
DefaultDependencies=no

[Mount]
What=overlay
Where=/etc
Type=overlay
Options=lowerdir=/etc,upperdir=/overlay/etc,workdir=/overlay/etcw

[Install]
WantedBy=local-fs.target
EOF

VAR_MOUNT_TMP="$(mktemp)"
cat > "${VAR_MOUNT_TMP}" << EOF
[Unit]
Description=Overlay mount for /var
Requires=overlay.mount
After=overlay.mount local-fs-pre.target
Before=local-fs.target
DefaultDependencies=no

[Mount]
What=overlay
Where=/var
Type=overlay
Options=lowerdir=/var,upperdir=/overlay/var,workdir=/overlay/varw

[Install]
WantedBy=local-fs.target
EOF

USR_MOUNT_TMP="$(mktemp)"
cat > "${USR_MOUNT_TMP}" << EOF
[Unit]
Description=Overlay mount for /usr
Requires=overlay.mount
After=overlay.mount local-fs-pre.target
Before=local-fs.target
DefaultDependencies=no

[Mount]
What=overlay
Where=/usr
Type=overlay
Options=lowerdir=/usr,upperdir=/overlay/usr,workdir=/overlay/usrw

[Install]
WantedBy=local-fs.target
EOF

VAR_RUN_MOUNT_TMP="$(mktemp)"
cat > "${VAR_RUN_MOUNT_TMP}" << EOF
[Unit]
Description=Bind /run onto /var/run
After=var.mount local-fs-pre.target
Before=local-fs.target
DefaultDependencies=no

[Mount]
What=/run
Where=/var/run
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
EOF

VAR_LIB_LASTLOG_MOUNT_TMP="$(mktemp)"
cat > "${VAR_LIB_LASTLOG_MOUNT_TMP}" << EOF
[Unit]
Description=Writable bind mount for /var/lib/lastlog
Requires=var.mount
After=var.mount local-fs-pre.target
Before=local-fs.target
DefaultDependencies=no

[Mount]
What=/overlay/var/lib/lastlog
Where=/var/lib/lastlog
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
EOF

VAR_LIB_TIMESYNC_MOUNT_TMP="$(mktemp)"
cat > "${VAR_LIB_TIMESYNC_MOUNT_TMP}" << EOF
[Unit]
Description=Writable bind mount for /var/lib/timesyncd
Requires=overlay.mount var.mount
After=overlay.mount var.mount local-fs-pre.target
Before=local-fs.target
DefaultDependencies=no

[Mount]
What=/overlay/var/lib/timesyncd
Where=/var/lib/timesyncd
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
EOF

# Paths containing '-' or '.' cannot be represented as plain .mount units,
# so use lightweight oneshot services for the remaining bind mounts.
COSMIC_BIND_SVC_TMP="$(mktemp)"
cat > "${COSMIC_BIND_SVC_TMP}" << EOF
[Unit]
Description=Bind /overlay/var/lib/cosmic-greeter onto /var/lib/cosmic-greeter
Requires=var.mount
After=var.mount local-fs-pre.target
Before=local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mount --bind /overlay/var/lib/cosmic-greeter /var/lib/cosmic-greeter
ExecStop=/usr/bin/umount /var/lib/cosmic-greeter

[Install]
WantedBy=local-fs.target
EOF

PACMAN_GNUPG_BIND_SVC_TMP="$(mktemp)"
cat > "${PACMAN_GNUPG_BIND_SVC_TMP}" << EOF
[Unit]
Description=Bind /overlay/etc/pacman.d/gnupg onto /etc/pacman.d/gnupg
Requires=etc.mount
After=etc.mount local-fs-pre.target
Before=local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mount --bind /overlay/etc/pacman.d/gnupg /etc/pacman.d/gnupg
ExecStop=/usr/bin/umount /etc/pacman.d/gnupg

[Install]
WantedBy=local-fs.target
EOF

LOGIND_DROPIN_TMP="$(mktemp)"
cat > "${LOGIND_DROPIN_TMP}" << EOF
[Service]
# overlayfs returns EXDEV for the atomic rename that systemd uses to set up
# StateDirectory=, so disable the managed state directory for logind.
StateDirectory=
RuntimeDirectory=systemd/sessions systemd/seats systemd/users systemd/inhibit systemd/shutdown
EOF

UPDATE_UTMP_DROPIN_TMP="$(mktemp)"
cat > "${UPDATE_UTMP_DROPIN_TMP}" << EOF
[Unit]
Requires=var-run.mount regicide-wtmp-bind.service
After=var-run.mount regicide-wtmp-bind.service
EOF

TIMESYNC_DROPIN_TMP="$(mktemp)"
cat > "${TIMESYNC_DROPIN_TMP}" << EOF
[Service]
# overlayfs returns EXDEV for the atomic rename that systemd uses to set up
# StateDirectory=, so disable the managed state directory for timesyncd.
StateDirectory=
[Unit]
Requires=var-lib-timesyncd.mount
After=var-lib-timesyncd.mount
EOF

GNUPG_SOCKET_DROPIN_TMP="$(mktemp)"
cat > "${GNUPG_SOCKET_DROPIN_TMP}" << EOF
[Unit]
Requires=regicide-bind-pacman-gnupg.service
After=regicide-bind-pacman-gnupg.service
EOF

WTMP_BIND_SVC_TMP="$(mktemp)"
cat > "${WTMP_BIND_SVC_TMP}" << EOF
[Unit]
Description=Bind /run/utmp onto /var/log/wtmp to avoid EXDEV on overlayfs
After=systemd-tmpfiles-setup.service var.mount
Before=systemd-update-utmp.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mount --bind /run/utmp /var/log/wtmp
ExecStop=/usr/bin/umount /var/log/wtmp

[Install]
WantedBy=sysinit.target
EOF

GREETD_TMPFILES_TMP="$(mktemp)"
cat > "${GREETD_TMPFILES_TMP}" << EOF
# Ensure greetd runtime directory exists for cosmic-greeter-daemon
d /run/greetd 0755 cosmic-greeter cosmic-greeter -
EOF

guestfish <<GFISH
  add-drive "${RAW_IMG}" format:raw
  run
  mount "/dev/sda${OVERLAY_IDX}" /
  # Create writable runtime directories on the overlay partition.
  # Numeric ownership matches the guest's system users (cosmic-greeter=968,
  # systemd-timesync=973, utmp=996). The bind mounts expose these onto the
  # overlay so services can write without hitting EXDEV.
  mkdir-p /var/lib/cosmic-greeter
  chown 968 968 /var/lib/cosmic-greeter
  chmod 0755 /var/lib/cosmic-greeter
  mkdir-p /var/lib/lastlog
  chown 0 996 /var/lib/lastlog
  chmod 0755 /var/lib/lastlog
  mkdir-p /var/lib/timesyncd
  chown 973 973 /var/lib/timesyncd
  chmod 0755 /var/lib/timesyncd
  mkdir-p /etc/pacman.d/gnupg
  chown 0 0 /etc/pacman.d/gnupg
  chmod 0755 /etc/pacman.d/gnupg
  # Mask the tarball's /var/run symlink with a real directory in the overlay
  # upperdir, and provide a writable upperdir directory for /var/lib/systemd.
  mkdir-p /var/run
  chmod 0755 /var/run
  mkdir-p /var/lib/systemd
  chmod 0755 /var/lib/systemd
  mkdir-p /varw
  mkdir-p /etcw
  mkdir-p /usrw
  umount /

  mount "/dev/sda${ROOTS_IDX}" /
  # Create /efi mountpoint so systemd-gpt-auto-generator's efi.automount succeeds.
  mkdir-p /efi
  chmod 0755 /efi
  upload "${FSTAB_TMP}" /etc/fstab
  chmod 0644 /etc/fstab
  mkdir-p /etc/modules-load.d
  upload "${MODULES_TMP}" /etc/modules-load.d/regicide-btrfs.conf
  chmod 0644 /etc/modules-load.d/regicide-btrfs.conf
  upload "${MASK_TMP}" /root/regicide-mask.sh
  chmod 0755 /root/regicide-mask.sh
  command "/root/regicide-mask.sh"

  # Hostname
  upload "${HOSTNAME_TMP}" /etc/hostname
  chmod 0644 /etc/hostname
  upload "${HOSTS_TMP}" /etc/hosts
  chmod 0644 /etc/hosts

  # Overlay mount units
  mkdir-p /etc/systemd/system
  upload "${ETC_MOUNT_TMP}" /etc/systemd/system/etc.mount
  chmod 0644 /etc/systemd/system/etc.mount
  upload "${VAR_MOUNT_TMP}" /etc/systemd/system/var.mount
  chmod 0644 /etc/systemd/system/var.mount
  upload "${USR_MOUNT_TMP}" /etc/systemd/system/usr.mount
  chmod 0644 /etc/systemd/system/usr.mount
  upload "${VAR_RUN_MOUNT_TMP}" /etc/systemd/system/var-run.mount
  chmod 0644 /etc/systemd/system/var-run.mount
  upload "${VAR_LIB_LASTLOG_MOUNT_TMP}" /etc/systemd/system/var-lib-lastlog.mount
  chmod 0644 /etc/systemd/system/var-lib-lastlog.mount
  upload "${VAR_LIB_TIMESYNC_MOUNT_TMP}" /etc/systemd/system/var-lib-timesyncd.mount
  chmod 0644 /etc/systemd/system/var-lib-timesyncd.mount
  upload "${COSMIC_BIND_SVC_TMP}" /etc/systemd/system/regicide-bind-cosmic-greeter.service
  chmod 0644 /etc/systemd/system/regicide-bind-cosmic-greeter.service
  upload "${PACMAN_GNUPG_BIND_SVC_TMP}" /etc/systemd/system/regicide-bind-pacman-gnupg.service
  chmod 0644 /etc/systemd/system/regicide-bind-pacman-gnupg.service

  # Enable mount/service units
  mkdir-p /etc/systemd/system/local-fs.target.wants
  ln-sf /etc/systemd/system/etc.mount /etc/systemd/system/local-fs.target.wants/etc.mount
  ln-sf /etc/systemd/system/var.mount /etc/systemd/system/local-fs.target.wants/var.mount
  ln-sf /etc/systemd/system/usr.mount /etc/systemd/system/local-fs.target.wants/usr.mount
  ln-sf /etc/systemd/system/var-run.mount /etc/systemd/system/local-fs.target.wants/var-run.mount
  ln-sf /etc/systemd/system/var-lib-lastlog.mount /etc/systemd/system/local-fs.target.wants/var-lib-lastlog.mount
  ln-sf /etc/systemd/system/var-lib-timesyncd.mount /etc/systemd/system/local-fs.target.wants/var-lib-timesyncd.mount
  ln-sf /etc/systemd/system/regicide-bind-cosmic-greeter.service /etc/systemd/system/local-fs.target.wants/regicide-bind-cosmic-greeter.service
  ln-sf /etc/systemd/system/regicide-bind-pacman-gnupg.service /etc/systemd/system/local-fs.target.wants/regicide-bind-pacman-gnupg.service

  # Lock root password so only regicide can log in (tarball may be stale).
  command "usermod -p '!*' root"

  # Drop-ins
  mkdir-p /etc/systemd/system/systemd-logind.service.d
  upload "${LOGIND_DROPIN_TMP}" /etc/systemd/system/systemd-logind.service.d/overlay-fix.conf
  chmod 0644 /etc/systemd/system/systemd-logind.service.d/overlay-fix.conf
  mkdir-p /etc/systemd/system/systemd-update-utmp.service.d
  upload "${UPDATE_UTMP_DROPIN_TMP}" /etc/systemd/system/systemd-update-utmp.service.d/var-run.conf
  chmod 0644 /etc/systemd/system/systemd-update-utmp.service.d/var-run.conf
  mkdir-p /etc/systemd/system/systemd-timesyncd.service.d
  upload "${TIMESYNC_DROPIN_TMP}" /etc/systemd/system/systemd-timesyncd.service.d/overlay-fix.conf
  chmod 0644 /etc/systemd/system/systemd-timesyncd.service.d/overlay-fix.conf
  mkdir-p /etc/systemd/system/dirmngr@etc-pacman.d-gnupg.service.d
  upload "${GNUPG_SOCKET_DROPIN_TMP}" /etc/systemd/system/dirmngr@etc-pacman.d-gnupg.service.d/after-bind.conf
  chmod 0644 /etc/systemd/system/dirmngr@etc-pacman.d-gnupg.service.d/after-bind.conf
  mkdir-p /etc/systemd/system/gpg-agent@etc-pacman.d-gnupg.service.d
  upload "${GNUPG_SOCKET_DROPIN_TMP}" /etc/systemd/system/gpg-agent@etc-pacman.d-gnupg.service.d/after-bind.conf
  chmod 0644 /etc/systemd/system/gpg-agent@etc-pacman.d-gnupg.service.d/after-bind.conf
  mkdir-p /etc/systemd/system/gpg-agent-browser@etc-pacman.d-gnupg.service.d
  upload "${GNUPG_SOCKET_DROPIN_TMP}" /etc/systemd/system/gpg-agent-browser@etc-pacman.d-gnupg.service.d/after-bind.conf
  chmod 0644 /etc/systemd/system/gpg-agent-browser@etc-pacman.d-gnupg.service.d/after-bind.conf
  mkdir-p /etc/systemd/system/gpg-agent-extra@etc-pacman.d-gnupg.service.d
  upload "${GNUPG_SOCKET_DROPIN_TMP}" /etc/systemd/system/gpg-agent-extra@etc-pacman.d-gnupg.service.d/after-bind.conf
  chmod 0644 /etc/systemd/system/gpg-agent-extra@etc-pacman.d-gnupg.service.d/after-bind.conf
  mkdir-p /etc/systemd/system/gpg-agent-ssh@etc-pacman.d-gnupg.service.d
  upload "${GNUPG_SOCKET_DROPIN_TMP}" /etc/systemd/system/gpg-agent-ssh@etc-pacman.d-gnupg.service.d/after-bind.conf
  chmod 0644 /etc/systemd/system/gpg-agent-ssh@etc-pacman.d-gnupg.service.d/after-bind.conf
  mkdir-p /etc/systemd/system/keyboxd@etc-pacman.d-gnupg.service.d
  upload "${GNUPG_SOCKET_DROPIN_TMP}" /etc/systemd/system/keyboxd@etc-pacman.d-gnupg.service.d/after-bind.conf
  chmod 0644 /etc/systemd/system/keyboxd@etc-pacman.d-gnupg.service.d/after-bind.conf

  # tmpfiles for greetd
  mkdir-p /etc/tmpfiles.d
  upload "${GREETD_TMPFILES_TMP}" /etc/tmpfiles.d/regicide-greetd.conf
  chmod 0644 /etc/tmpfiles.d/regicide-greetd.conf

  # wtmp bind service
  upload "${WTMP_BIND_SVC_TMP}" /etc/systemd/system/regicide-wtmp-bind.service
  chmod 0644 /etc/systemd/system/regicide-wtmp-bind.service
  mkdir-p /etc/systemd/system/sysinit.target.wants
  ln-sf /etc/systemd/system/regicide-wtmp-bind.service /etc/systemd/system/sysinit.target.wants/regicide-wtmp-bind.service
GFISH

rm -f "${MODULES_TMP}" "${MASK_TMP}" "${FSTAB_TMP}" \
  "${HOSTNAME_TMP}" "${HOSTS_TMP}" \
  "${ETC_MOUNT_TMP}" "${VAR_MOUNT_TMP}" "${USR_MOUNT_TMP}" \
  "${VAR_RUN_MOUNT_TMP}" "${VAR_LIB_LASTLOG_MOUNT_TMP}" \
  "${VAR_LIB_TIMESYNC_MOUNT_TMP}" "${COSMIC_BIND_SVC_TMP}" "${PACMAN_GNUPG_BIND_SVC_TMP}" \
  "${LOGIND_DROPIN_TMP}" "${UPDATE_UTMP_DROPIN_TMP}" "${TIMESYNC_DROPIN_TMP}" \
  "${GNUPG_SOCKET_DROPIN_TMP}" "${WTMP_BIND_SVC_TMP}" "${GREETD_TMPFILES_TMP}"

echo "Installing systemd-boot to EFI partition via guestfish..."
BOOT_ENTRY_TMP="$(mktemp)"
cat > "${BOOT_ENTRY_TMP}" << EOF
title   RegicideOSArch
linux   /EFI/arch/vmlinuz-linux
initrd  /EFI/arch/initramfs-linux.img
options root=LABEL=ROOTS rw console=ttyS0,115200n8 systemd.firstboot=no
EOF

LOADER_CONF_TMP="$(mktemp)"
cat > "${LOADER_CONF_TMP}" << EOF
default arch
timeout 5
console-mode max
editor  no
EOF

guestfish <<GFISH
  add-drive "${RAW_IMG}" format:raw
  run
  mount "/dev/sda${EFI_IDX}" /
  mkdir-p /EFI/BOOT
  mkdir-p /loader/entries
  mkdir-p /EFI/arch
  mkdir-p /roots
  mount "/dev/sda${ROOTS_IDX}" /roots
  copy-file-to-file /roots/usr/lib/systemd/boot/efi/systemd-bootx64.efi /EFI/BOOT/BOOTX64.EFI
  copy-file-to-file /roots/boot/vmlinuz-linux /EFI/arch/vmlinuz-linux
  copy-file-to-file /roots/boot/initramfs-linux.img /EFI/arch/initramfs-linux.img
  umount /roots
  upload "${LOADER_CONF_TMP}" /loader/loader.conf
  upload "${BOOT_ENTRY_TMP}" /loader/entries/arch.conf
  chmod 0644 /loader/loader.conf
  chmod 0644 /loader/entries/arch.conf
GFISH

rm -f "${BOOT_ENTRY_TMP}" "${LOADER_CONF_TMP}"

echo "Converting raw image to QCOW2..."
qemu-img convert -f raw -O qcow2 "${RAW_IMG}" "${OUTPUT}"
chmod 644 "${OUTPUT}"
RUNNER_PATH="${OUTPUT_DIR}/run-qemu.sh"
cat > "${RUNNER_PATH}" << QEMUEOF
#!/bin/bash
# RegicideOSArch QEMU Runner
# Auto-generated by build-qemu-image-guestfish.sh

set -euo pipefail

IMAGE="$(realpath -m --relative-to="${OUTPUT_DIR}" "${OUTPUT}" 2>/dev/null || basename "${OUTPUT}")"
IMAGE_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
IMAGE_PATH="\${IMAGE_DIR}/\${IMAGE}"

if [[ ! -f "\${IMAGE_PATH}" ]]; then
    echo "Error: disk image not found: \${IMAGE_PATH}"
    exit 1
fi

echo "Starting RegicideOSArch QEMU VM..."
echo "  Image: \${IMAGE_PATH}"
echo "  Memory: 4G"
echo "  CPUs: 2"
echo "  SSH: localhost:2222 -> :22"
echo ""
echo "To connect via SSH: ssh -p 2222 regicide@localhost"
echo "To stop: Ctrl+A then X (if using -nographic) or close window"
echo ""

LOG_DIR="\${IMAGE_DIR}/logs"
mkdir -p "\${LOG_DIR}"

OVMF_CODE=""
OVMF_VARS=""
for path in \\
    /usr/share/OVMF/OVMF_CODE.fd \\
    /usr/share/edk2/ovmf/OVMF_CODE.fd \\
    /usr/share/qemu/OVMF_CODE.fd \\
    /usr/share/ovmf/x64/OVMF_CODE.fd
do
    if [[ -f "\${path}" ]]; then
        OVMF_CODE="\${path}"
        break
    fi
done
for path in \\
    /usr/share/OVMF/OVMF_VARS.fd \\
    /usr/share/edk2/ovmf/OVMF_VARS.fd \\
    /usr/share/qemu/OVMF_VARS.fd \\
    /usr/share/ovmf/x64/OVMF_VARS.fd
do
    if [[ -f "\${path}" ]]; then
        OVMF_VARS="\${path}"
        break
    fi
done

if [[ -z "\${OVMF_CODE}" ]]; then
    echo "Error: OVMF firmware not found. Install ovmf or edk2-ovmf."
    exit 1
fi

UEFI_FLAGS="-drive if=pflash,format=raw,readonly=on,file=\${OVMF_CODE}"
if [[ -n "\${OVMF_VARS}" ]]; then
    TMP_VARS=\$(mktemp --suffix=_OVMF_VARS.fd)
    cp "\${OVMF_VARS}" "\${TMP_VARS}"
    UEFI_FLAGS="\${UEFI_FLAGS} -drive if=pflash,format=raw,file=\${TMP_VARS}"
fi

qemu-system-x86_64 \\
    -enable-kvm \\
    -m 4G \\
    -smp 2 \\
    -cpu host \\
    -drive file="${OUTPUT}",format=qcow2,if=virtio \\
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \\
    -device virtio-net-pci,netdev=net0 \\
    -machine type=q35,accel=kvm \\
    -serial file:\${LOG_DIR}/regicide-serial.log \\
    -monitor unix:\${LOG_DIR}/regicide-monitor.sock,server,nowait \\
    \${UEFI_FLAGS} \\
    \$@
QEMUEOF

chmod +x "${RUNNER_PATH}"
chmod 755 "${OUTPUT_DIR}"
echo ""
echo "========================================"
echo "RegicideOSArch QEMU image build complete!"
echo "========================================"
echo ""
echo "Disk image: ${OUTPUT}"
echo "Runner:     ${RUNNER_PATH}"
echo ""
echo "To start the VM:"
echo "  ${RUNNER_PATH}"
echo ""
echo "To start headless (VNC):"
echo "  ${RUNNER_PATH} -display vnc=:1"
echo ""
