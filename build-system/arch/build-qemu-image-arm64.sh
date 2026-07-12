#!/bin/bash
# RegicideOSArch ARM64 QEMU Disk Image Builder (loopback mount)
# Creates a bootable ARM64 QCOW2 disk from a RegicideOSArch tarball.
# Runs natively on an ARM64 host using host tools (no guestfish required).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARBALL=""
OUTPUT="${SCRIPT_DIR}/output/regicide-arch-arm64.qcow2"
DISK_SIZE="${REGICIDE_DISK_SIZE:-20G}"
EFI_SIZE="${REGICIDE_EFI_SIZE:-512M}"
ROOTS_SIZE="${REGICIDE_ROOTS_SIZE:-14G}"
OVERLAY_SIZE="${REGICIDE_OVERLAY_SIZE:-4G}"
POS=0

usage() {
    cat << EOF
Usage: $0 [OPTIONS] <regicide-arch-tarball> [output-qcow2] [disk-size]

  regicide-arch-tarball  Path to the ARM64 regicide-arch .tar or .tar.xz tarball (required)
  output-qcow2           Path for the output .qcow2 file (optional)
  disk-size              Disk size for the image, e.g. 20G (optional, default: 20G)

Examples:
  $0 /path/to/regicide-arch-arm64.tar.xz
  $0 /path/to/regicide-arch-arm64.tar.xz ./my-image.qcow2 30G
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
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

[[ -n "${TARBALL}" ]] || { echo "Error: tarball path is required."; usage; }
[[ -f "${TARBALL}" ]] || { echo "Error: tarball not found: ${TARBALL}"; exit 1; }

REQUIRED_CMDS=(qemu-img qemu-system-aarch64 sgdisk mkfs.vfat mkfs.btrfs losetup tar xz python3 partprobe partx kpartx)
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

RAW_IMG="$(mktemp --suffix=.raw)"
PLAIN_TAR="/var/tmp/regicide-arch-arm64.tar"
SEED_TARBALL=""
SEED_SCRIPT=""
LOOP=""
LOOP_PART_PREFIX=""
MNT_ROOT=""
MNT_OVERLAY=""
MNT_HOME=""
MNT_EFI=""

_cleanup() {
    set +e
    [[ -n "${MNT_EFI}" ]] && umount -R "${MNT_EFI}" 2>/dev/null
    [[ -n "${MNT_ROOT}" ]] && umount -R "${MNT_ROOT}" 2>/dev/null
    [[ -n "${MNT_HOME}" ]] && umount -R "${MNT_HOME}" 2>/dev/null
    [[ -n "${MNT_OVERLAY}" ]] && umount -R "${MNT_OVERLAY}" 2>/dev/null
    if [[ -n "${LOOP}" ]]; then
        kpartx -d "${LOOP}" 2>/dev/null || true
        losetup -d "${LOOP}" 2>/dev/null || true
    fi
    rm -f "${RAW_IMG}" 2>/dev/null
    rm -f "${PLAIN_TAR}" 2>/dev/null
    [[ -n "${SEED_TARBALL}" ]] && rm -f "${SEED_TARBALL}" 2>/dev/null
    [[ -n "${SEED_SCRIPT}" ]] && rm -f "${SEED_SCRIPT}" 2>/dev/null
    [[ -n "${MNT_EFI}" ]] && rmdir "${MNT_EFI}" 2>/dev/null
    [[ -n "${MNT_ROOT}" ]] && rmdir "${MNT_ROOT}" 2>/dev/null
    [[ -n "${MNT_HOME}" ]] && rmdir "${MNT_HOME}" 2>/dev/null
    [[ -n "${MNT_OVERLAY}" ]] && rmdir "${MNT_OVERLAY}" 2>/dev/null
}
trap _cleanup EXIT

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

echo "Attaching loop device..."
LOOP="$(losetup -f --show -P "${RAW_IMG}")"
partprobe "${LOOP}" 2>/dev/null || partx -u "${LOOP}" 2>/dev/null || true
sleep 2

# Some container/CI environments don't create loop partition nodes via udev.
# Fall back to kpartx device-mapper nodes if the simple loop partitions are missing.
LOOP_PART_PREFIX="${LOOP}p"
if [[ ! -e "${LOOP_PART_PREFIX}${EFI_IDX}" ]]; then
    KP_NAME="$(basename "${LOOP}")"
    kpartx -avs "${LOOP}" >/dev/null 2>&1 || true
    sleep 1
    if [[ -e "/dev/mapper/${KP_NAME}p${EFI_IDX}" ]]; then
        LOOP_PART_PREFIX="/dev/mapper/${KP_NAME}p"
    fi
fi

echo "Formatting partitions..."
mkfs.vfat "${LOOP_PART_PREFIX}${EFI_IDX}" -n EFI
mkfs.btrfs "${LOOP_PART_PREFIX}${ROOTS_IDX}" -L ROOTS
mkfs.btrfs "${LOOP_PART_PREFIX}${OVERLAY_IDX}" -L OVERLAY
mkfs.btrfs "${LOOP_PART_PREFIX}${HOME_IDX}" -L HOME

echo "Decompressing tarball..."
rm -f "${PLAIN_TAR}"
if [[ "${TARBALL}" == *.tar.xz || "${TARBALL}" == *.txz ]]; then
    xz -cd "${TARBALL}" > "${PLAIN_TAR}"
elif [[ "${TARBALL}" == *.tar.gz || "${TARBALL}" == *.tgz ]]; then
    gzip -cd "${TARBALL}" > "${PLAIN_TAR}"
else
    cp "${TARBALL}" "${PLAIN_TAR}"
fi

MNT_ROOT="$(mktemp -d)"
MNT_OVERLAY="$(mktemp -d)"
MNT_HOME="$(mktemp -d)"
MNT_EFI="$(mktemp -d)"

echo "Creating overlay subvolumes..."
mount "${LOOP_PART_PREFIX}${OVERLAY_IDX}" "${MNT_OVERLAY}"
btrfs subvolume create "${MNT_OVERLAY}/etc"
btrfs subvolume create "${MNT_OVERLAY}/var"
btrfs subvolume create "${MNT_OVERLAY}/usr"
btrfs subvolume create "${MNT_OVERLAY}/home"
mkdir -p "${MNT_OVERLAY}/etcw" "${MNT_OVERLAY}/varw" "${MNT_OVERLAY}/usrw"
umount "${MNT_OVERLAY}"

echo "Extracting rootfs..."
mount "${LOOP_PART_PREFIX}${ROOTS_IDX}" "${MNT_ROOT}"
tar -C "${MNT_ROOT}" -xpf "${PLAIN_TAR}"
mkdir -p "${MNT_ROOT}/overlay" "${MNT_ROOT}/home" "${MNT_ROOT}/boot/efi" "${MNT_ROOT}/tmp"

echo "Extracting /home contents for HOME partition..."
rm -rf /tmp/regicide-home-staging
mkdir -p /tmp/regicide-home-staging
tar -C /tmp/regicide-home-staging -xf "${PLAIN_TAR}" --wildcards 'home/*' 2>/dev/null || true
mount "${LOOP_PART_PREFIX}${HOME_IDX}" "${MNT_HOME}"
if [[ -d /tmp/regicide-home-staging/home/regicide ]]; then
    chown -R 1000:1000 /tmp/regicide-home-staging/home/regicide
    chmod 0700 /tmp/regicide-home-staging/home/regicide
    find /tmp/regicide-home-staging/home/regicide -type f -exec chmod 0644 {} \;
    cp -a /tmp/regicide-home-staging/home/regicide "${MNT_HOME}/"
fi
umount "${MNT_HOME}"
rm -rf /tmp/regicide-home-staging

echo "Pre-seeding overlay upperdir trees..."
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
    if top == "var":
        return True
    target = (m.linkname or "").strip()
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

mount "${LOOP_PART_PREFIX}${OVERLAY_IDX}" "${MNT_OVERLAY}"
tar -C "${MNT_OVERLAY}" -xpf "${SEED_TARBALL}"
mkdir -p "${MNT_OVERLAY}/var/lib/cosmic-greeter"
chown 968:968 "${MNT_OVERLAY}/var/lib/cosmic-greeter"
chmod 0755 "${MNT_OVERLAY}/var/lib/cosmic-greeter"
mkdir -p "${MNT_OVERLAY}/var/lib/lastlog"
chown 0:996 "${MNT_OVERLAY}/var/lib/lastlog"
chmod 0755 "${MNT_OVERLAY}/var/lib/lastlog"
mkdir -p "${MNT_OVERLAY}/var/lib/timesyncd"
chown 973:973 "${MNT_OVERLAY}/var/lib/timesyncd"
chmod 0755 "${MNT_OVERLAY}/var/lib/timesyncd"
mkdir -p "${MNT_OVERLAY}/etc/pacman.d/gnupg"
chown 0:0 "${MNT_OVERLAY}/etc/pacman.d/gnupg"
chmod 0755 "${MNT_OVERLAY}/etc/pacman.d/gnupg"
mkdir -p "${MNT_OVERLAY}/var/run"
chmod 0755 "${MNT_OVERLAY}/var/run"
mkdir -p "${MNT_OVERLAY}/var/lib/systemd"
chmod 0755 "${MNT_OVERLAY}/var/lib/systemd"
mkdir -p "${MNT_OVERLAY}/varw" "${MNT_OVERLAY}/etcw" "${MNT_OVERLAY}/usrw"
umount "${MNT_OVERLAY}"

echo "Writing system configuration..."
cat > "${MNT_ROOT}/etc/fstab" << EOF
# RegicideOSArch ARM64 QEMU image fstab
LABEL=ROOTS   /       btrfs   defaults,noatime,ro           0 0
LABEL=OVERLAY /overlay btrfs   defaults,noatime           0 0
LABEL=HOME    /home   btrfs   defaults,noatime           0 0
EOF
chmod 0644 "${MNT_ROOT}/etc/fstab"

mkdir -p "${MNT_ROOT}/etc/modules-load.d"
cat > "${MNT_ROOT}/etc/modules-load.d/regicide-btrfs.conf" << EOF
btrfs
EOF
chmod 0644 "${MNT_ROOT}/etc/modules-load.d/regicide-btrfs.conf"

cat > "${MNT_ROOT}/etc/hostname" << EOF
RegicideOSArch-ARM64
EOF
chmod 0644 "${MNT_ROOT}/etc/hostname"

cat > "${MNT_ROOT}/etc/hosts" << EOF
127.0.0.1\tlocalhost
127.0.1.1\tRegicideOSArch-ARM64\tRegicideOSArch-ARM64
::1\t\tlocalhost ip6-localhost ip6-loopback
ff02::1\t\tip6-allnodes
ff02::2\t\tip6-allrouters
EOF
chmod 0644 "${MNT_ROOT}/etc/hosts"

echo "Masking services..."
mkdir -p "${MNT_ROOT}/etc/systemd/system"
for svc in systemd-nsresourced.service systemd-confext.service systemd-sysext.service systemd-homed.service systemd-homed-activate.service; do
    ln -sf /dev/null "${MNT_ROOT}/etc/systemd/system/${svc}"
done

echo "Writing overlay mount units..."
mkdir -p "${MNT_ROOT}/etc/systemd/system/local-fs.target.wants"

cat > "${MNT_ROOT}/etc/systemd/system/etc.mount" << EOF
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
chmod 0644 "${MNT_ROOT}/etc/systemd/system/etc.mount"
ln -sf /etc/systemd/system/etc.mount "${MNT_ROOT}/etc/systemd/system/local-fs.target.wants/etc.mount"

cat > "${MNT_ROOT}/etc/systemd/system/var.mount" << EOF
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
chmod 0644 "${MNT_ROOT}/etc/systemd/system/var.mount"
ln -sf /etc/systemd/system/var.mount "${MNT_ROOT}/etc/systemd/system/local-fs.target.wants/var.mount"

cat > "${MNT_ROOT}/etc/systemd/system/usr.mount" << EOF
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
chmod 0644 "${MNT_ROOT}/etc/systemd/system/usr.mount"
ln -sf /etc/systemd/system/usr.mount "${MNT_ROOT}/etc/systemd/system/local-fs.target.wants/usr.mount"

cat > "${MNT_ROOT}/etc/systemd/system/var-run.mount" << EOF
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
chmod 0644 "${MNT_ROOT}/etc/systemd/system/var-run.mount"
ln -sf /etc/systemd/system/var-run.mount "${MNT_ROOT}/etc/systemd/system/local-fs.target.wants/var-run.mount"

cat > "${MNT_ROOT}/etc/systemd/system/var-lib-lastlog.mount" << EOF
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
chmod 0644 "${MNT_ROOT}/etc/systemd/system/var-lib-lastlog.mount"
ln -sf /etc/systemd/system/var-lib-lastlog.mount "${MNT_ROOT}/etc/systemd/system/local-fs.target.wants/var-lib-lastlog.mount"

cat > "${MNT_ROOT}/etc/systemd/system/var-lib-timesyncd.mount" << EOF
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
chmod 0644 "${MNT_ROOT}/etc/systemd/system/var-lib-timesyncd.mount"
ln -sf /etc/systemd/system/var-lib-timesyncd.mount "${MNT_ROOT}/etc/systemd/system/local-fs.target.wants/var-lib-timesyncd.mount"

cat > "${MNT_ROOT}/etc/systemd/system/regicide-bind-cosmic-greeter.service" << EOF
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
chmod 0644 "${MNT_ROOT}/etc/systemd/system/regicide-bind-cosmic-greeter.service"
ln -sf /etc/systemd/system/regicide-bind-cosmic-greeter.service "${MNT_ROOT}/etc/systemd/system/local-fs.target.wants/regicide-bind-cosmic-greeter.service"

cat > "${MNT_ROOT}/etc/systemd/system/regicide-bind-pacman-gnupg.service" << EOF
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
chmod 0644 "${MNT_ROOT}/etc/systemd/system/regicide-bind-pacman-gnupg.service"
ln -sf /etc/systemd/system/regicide-bind-pacman-gnupg.service "${MNT_ROOT}/etc/systemd/system/local-fs.target.wants/regicide-bind-pacman-gnupg.service"

echo "Writing drop-ins..."
mkdir -p "${MNT_ROOT}/etc/systemd/system/systemd-logind.service.d"
cat > "${MNT_ROOT}/etc/systemd/system/systemd-logind.service.d/overlay-fix.conf" << EOF
[Service]
StateDirectory=
RuntimeDirectory=systemd/sessions systemd/seats systemd/users systemd/inhibit systemd/shutdown
EOF
chmod 0644 "${MNT_ROOT}/etc/systemd/system/systemd-logind.service.d/overlay-fix.conf"

mkdir -p "${MNT_ROOT}/etc/systemd/system/systemd-update-utmp.service.d"
cat > "${MNT_ROOT}/etc/systemd/system/systemd-update-utmp.service.d/var-run.conf" << EOF
[Unit]
Requires=var-run.mount regicide-wtmp-bind.service
After=var-run.mount regicide-wtmp-bind.service
EOF
chmod 0644 "${MNT_ROOT}/etc/systemd/system/systemd-update-utmp.service.d/var-run.conf"

mkdir -p "${MNT_ROOT}/etc/systemd/system/systemd-timesyncd.service.d"
cat > "${MNT_ROOT}/etc/systemd/system/systemd-timesyncd.service.d/overlay-fix.conf" << EOF
[Service]
StateDirectory=
[Unit]
Requires=var-lib-timesyncd.mount
After=var-lib-timesyncd.mount
EOF
chmod 0644 "${MNT_ROOT}/etc/systemd/system/systemd-timesyncd.service.d/overlay-fix.conf"

for svc in dirmngr@etc-pacman.d-gnupg gpg-agent@etc-pacman.d-gnupg gpg-agent-browser@etc-pacman.d-gnupg gpg-agent-extra@etc-pacman.d-gnupg gpg-agent-ssh@etc-pacman.d-gnupg keyboxd@etc-pacman.d-gnupg; do
    mkdir -p "${MNT_ROOT}/etc/systemd/system/${svc}.service.d"
    cat > "${MNT_ROOT}/etc/systemd/system/${svc}.service.d/after-bind.conf" << EOF
[Unit]
Requires=regicide-bind-pacman-gnupg.service
After=regicide-bind-pacman-gnupg.service
EOF
    chmod 0644 "${MNT_ROOT}/etc/systemd/system/${svc}.service.d/after-bind.conf"
done

echo "Writing tmpfiles and wtmp bind service..."
mkdir -p "${MNT_ROOT}/etc/tmpfiles.d"
cat > "${MNT_ROOT}/etc/tmpfiles.d/regicide-greetd.conf" << EOF
d /run/greetd 0755 cosmic-greeter cosmic-greeter -
EOF
chmod 0644 "${MNT_ROOT}/etc/tmpfiles.d/regicide-greetd.conf"

cat > "${MNT_ROOT}/etc/systemd/system/regicide-wtmp-bind.service" << EOF
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
chmod 0644 "${MNT_ROOT}/etc/systemd/system/regicide-wtmp-bind.service"
mkdir -p "${MNT_ROOT}/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/regicide-wtmp-bind.service "${MNT_ROOT}/etc/systemd/system/sysinit.target.wants/regicide-wtmp-bind.service"

echo "Locking root password..."
if [[ -f "${MNT_ROOT}/etc/shadow" ]]; then
    sed -i 's/^root:[^:]*:/root:!*:/' "${MNT_ROOT}/etc/shadow"
fi

echo "Installing systemd-boot to EFI partition..."
mkdir -p "${MNT_ROOT}/efi"
mount "${LOOP_PART_PREFIX}${EFI_IDX}" "${MNT_EFI}"
mkdir -p "${MNT_EFI}/EFI/BOOT"
mkdir -p "${MNT_EFI}/loader/entries"
mkdir -p "${MNT_EFI}/EFI/arch"
cp "${MNT_ROOT}/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" "${MNT_EFI}/EFI/BOOT/BOOTAA64.EFI"
cp "${MNT_ROOT}/boot/Image" "${MNT_EFI}/EFI/arch/Image"
cp "${MNT_ROOT}/boot/initramfs-linux.img" "${MNT_EFI}/EFI/arch/initramfs-linux.img"

cat > "${MNT_EFI}/loader/loader.conf" << EOF
default arch
timeout 5
console-mode max
editor  no
EOF
chmod 0644 "${MNT_EFI}/loader/loader.conf"

cat > "${MNT_EFI}/loader/entries/arch.conf" << EOF
title   RegicideOSArch ARM64
linux   /EFI/arch/Image
initrd  /EFI/arch/initramfs-linux.img
options root=LABEL=ROOTS rw console=ttyAMA0,115200n8 console=tty0 systemd.firstboot=no
EOF
chmod 0644 "${MNT_EFI}/loader/entries/arch.conf"

umount "${MNT_EFI}"
umount "${MNT_ROOT}"

echo "Converting raw image to QCOW2..."
qemu-img convert -f raw -O qcow2 "${RAW_IMG}" "${OUTPUT}"
chmod 644 "${OUTPUT}"

echo "Writing runner script..."
RUNNER_PATH="${OUTPUT_DIR}/run-qemu-aarch64.sh"
cat > "${RUNNER_PATH}" << QEMUEOF
#!/bin/bash
# RegicideOSArch ARM64 QEMU Runner (KVM)
# Auto-generated by build-qemu-image-arm64.sh

set -euo pipefail

IMAGE="$(realpath -m --relative-to="${OUTPUT_DIR}" "${OUTPUT}" 2>/dev/null || basename "${OUTPUT}")"
IMAGE_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
IMAGE_PATH="\${IMAGE_DIR}/\${IMAGE}"

if [[ ! -f "\${IMAGE_PATH}" ]]; then
    echo "Error: disk image not found: \${IMAGE_PATH}"
    exit 1
fi

echo "Starting RegicideOSArch ARM64 QEMU VM..."
echo "  Image: \${IMAGE_PATH}"
echo "  Memory: 4G"
echo "  CPUs: 4"
echo "  SSH: localhost:2222 -> :22"
echo "  VNC: localhost:5901"
echo ""
echo "To connect via SSH: ssh -p 2222 regicide@localhost"
echo "To stop: Ctrl+A then X (if using -nographic) or close window"
echo ""

LOG_DIR="\${IMAGE_DIR}/logs"
mkdir -p "\${LOG_DIR}"

OVMF_CODE="/usr/share/AAVMF/AAVMF_CODE.fd"
OVMF_VARS="/usr/share/AAVMF/AAVMF_VARS.fd"

if [[ ! -f "\${OVMF_CODE}" ]]; then
    echo "Error: ARM64 UEFI firmware not found. Install qemu-efi-aarch64 or AAVMF."
    exit 1
fi

TMP_VARS=\$(mktemp --suffix=_AAVMF_VARS.fd)
cp "\${OVMF_VARS}" "\${TMP_VARS}"

qemu-system-aarch64 \\
    -machine virt,gic-version=3,accel=kvm \\
    -cpu host \\
    -enable-kvm \\
    -m 4G \\
    -smp 4 \\
    -drive file="${OUTPUT}",format=qcow2,if=virtio \\
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \\
    -device virtio-net-pci,netdev=net0 \\
    -device virtio-gpu-pci \\
    -device virtio-keyboard-pci \\
    -device virtio-tablet-pci \\
    -serial file:\${LOG_DIR}/regicide-serial-arm64.log \\
    -monitor unix:\${LOG_DIR}/regicide-monitor-arm64.sock,server,nowait \\
    -drive if=pflash,format=raw,readonly=on,file=\${OVMF_CODE} \\
    -drive if=pflash,format=raw,file=\${TMP_VARS} \\
    -display vnc=:1 \\
    \$@
QEMUEOF

chmod +x "${RUNNER_PATH}"
chmod 755 "${OUTPUT_DIR}"

echo ""
echo "========================================"
echo "RegicideOSArch ARM64 QEMU image build complete!"
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
