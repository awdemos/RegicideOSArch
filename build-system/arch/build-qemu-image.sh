#!/bin/bash
# RegicideOSArch QEMU Disk Image Builder
# Creates a bootable QCOW2 disk image from a RegicideOSArch tarball.
# Supports both loop-device (host) and direct-block-device (in-VM) modes.

set -euo pipefail

# Ensure tools installed under /usr/sbin are discoverable inside chroots.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:${PATH}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARBALL=""
OUTPUT="${SCRIPT_DIR}/output/regicide-arch.qcow2"
DISK_SIZE="${REGICIDE_DISK_SIZE:-30G}"
EFI_SIZE="${REGICIDE_EFI_SIZE:-512M}"
ROOTS_SIZE="${REGICIDE_ROOTS_SIZE:-12G}"
OVERLAY_SIZE="${REGICIDE_OVERLAY_SIZE:-4G}"
ENCRYPT=false
PASSPHRASE_FILE=""
DIRECT_DEVICE=""
NO_CONVERT=false
POS=0

usage() {
    cat << EOF
Usage: $0 [OPTIONS] <regicide-arch-tarball> [output-qcow2] [disk-size]

  regicide-arch-tarball  Path to the regicide-arch .tar.xz tarball (required)
  output-qcow2           Path for the output .qcow2 file (optional)
  disk-size              Disk size for the image, e.g. 20G (optional, default: 20G)

Options:
  --encrypt              Encrypt the ROOTS partition with LUKS2
  --passphrase-file      Path to a file containing the LUKS passphrase
                         (required with --encrypt; use - for stdin)
  --direct-device        Use an existing raw block device instead of creating a
                         temporary raw file and loop device (e.g. /dev/vda).
  --no-convert           Do not convert the raw image to QCOW2 at the end.
                         Useful when a wrapper will convert the raw disk.

Examples:
  $0 /path/to/regicide-arch.tar.xz
  $0 --encrypt --passphrase-file /run/luks-passphrase /path/to/regicide-arch.tar.xz ./my-image.qcow2 30G
  $0 --direct-device /dev/vda --no-convert /path/to/regicide-arch.tar.xz /tmp/image.qcow2 20G
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
        --direct-device)
            DIRECT_DEVICE="${2:-}"
            shift 2
            ;;
        --no-convert)
            NO_CONVERT=true
            shift
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

validate_block_device() {
    local dev="${1:-}"
    if [[ -z "${dev}" ]]; then
        return 0
    fi
    if [[ "${dev}" != /dev/* ]]; then
        echo "Error: direct device must be an absolute /dev path: ${dev}" >&2
        exit 1
    fi
    if [[ "${dev}" =~ \.\.|//|\.$ ]]; then
        echo "Error: invalid direct device path: ${dev}" >&2
        exit 1
    fi
    if [[ ! -b "${dev}" ]]; then
        echo "Error: direct device is not a block device: ${dev}" >&2
        exit 1
    fi
}

validate_block_device "${DIRECT_DEVICE}"

if [[ "${ENCRYPT}" == true ]]; then
    if [[ -z "${PASSPHRASE_FILE}" ]]; then
        echo "Error: --passphrase-file is required when --encrypt is used."
        usage
    fi
    if [[ "${PASSPHRASE_FILE}" != "-" && ! -f "${PASSPHRASE_FILE}" ]]; then
        echo "Error: passphrase file not found: ${PASSPHRASE_FILE}"
        exit 1
    fi
fi

if [[ -n "${DIRECT_DEVICE}" ]]; then
    REQUIRED_CMDS=(mkfs.vfat mkfs.btrfs btrfs tar)
else
    REQUIRED_CMDS=(mkfs.vfat mkfs.btrfs btrfs tar losetup partprobe)
fi
if [[ "${ENCRYPT}" == true ]]; then
    REQUIRED_CMDS+=(cryptsetup)
fi
if ! command -v sgdisk >/dev/null 2>&1 && ! command -v parted >/dev/null 2>&1; then
    echo "Error: either sgdisk or parted is required for partitioning."
    exit 1
fi
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

if [[ -n "${DIRECT_DEVICE}" ]]; then
    RAW_IMG="${DIRECT_DEVICE}"
else
    RAW_IMG="$(mktemp --suffix=.raw)"
fi
LUKS_NAME="regicide-arch"
LUKS_UUID=""

LOOP_DEV=""

cleanup() {
    echo "Cleaning up..."
    if [[ "${ENCRYPT}" == true ]]; then
        cryptsetup close "${LUKS_NAME}" 2>/dev/null || true
    fi
    if [[ -n "${LOOP_DEV}" ]]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
    if [[ -z "${DIRECT_DEVICE}" ]]; then
        rm -f "${RAW_IMG}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ -z "${DIRECT_DEVICE}" ]]; then
    echo "Creating raw disk image (${DISK_SIZE})..."
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img create -f raw "${RAW_IMG}" "${DISK_SIZE}"
    else
        truncate -s "${DISK_SIZE}" "${RAW_IMG}"
    fi
fi

# Convert an IEC size string (512M, 12G, ...) to an integer number of MiB so
# parted can use uniform units regardless of how the inputs were written.
_size_to_mib() {
    local bytes
    bytes=$(numfmt --from=iec "$1")
    echo "$(( bytes / 1024 / 1024 ))"
}

EFI_MIB=$(_size_to_mib "${EFI_SIZE}")
ROOTS_MIB=$(_size_to_mib "${ROOTS_SIZE}")
OVERLAY_MIB=$(_size_to_mib "${OVERLAY_SIZE}")
DISK_MIB=$(_size_to_mib "${DISK_SIZE}")

# Ensure the requested partitions fit on the target disk. If they do not,
# scale ROOTS and OVERLAY proportionally, always leaving at least 1 GiB for HOME.
MIN_HOME_MIB=1024
if [[ "$(( EFI_MIB + ROOTS_MIB + OVERLAY_MIB + MIN_HOME_MIB ))" -gt "${DISK_MIB}" ]]; then
    echo "Warning: requested partitions (${EFI_SIZE} + ${ROOTS_SIZE} + ${OVERLAY_SIZE}) do not fit on ${DISK_SIZE}; scaling down."
    AVAILABLE_MIB=$(( DISK_MIB - EFI_MIB - MIN_HOME_MIB ))
    ROOTS_MIB=$(( AVAILABLE_MIB / 2 ))
    OVERLAY_MIB=$(( AVAILABLE_MIB - ROOTS_MIB ))
fi

ROOTS_END_MIB=$(( EFI_MIB + ROOTS_MIB ))
OVERLAY_END_MIB=$(( EFI_MIB + ROOTS_MIB + OVERLAY_MIB ))

echo "Partitioning disk image..."
echo "  EFI:     ${EFI_MIB}MiB"
echo "  ROOTS:   ${EFI_MIB}MiB - ${ROOTS_END_MIB}MiB"
echo "  OVERLAY: ${ROOTS_END_MIB}MiB - ${OVERLAY_END_MIB}MiB"
echo "  HOME:    ${OVERLAY_END_MIB}MiB - end"
PARTITION_TARGET="${DIRECT_DEVICE:-${RAW_IMG}}"
if command -v sgdisk > /dev/null 2>&1; then
    sgdisk --clear "${PARTITION_TARGET}"
    sgdisk --new=1:0:+"${EFI_MIB}M"     --typecode=1:ef00 --change-name=1:EFI     "${PARTITION_TARGET}"
    sgdisk --new=2:0:+"${ROOTS_MIB}M"   --typecode=2:8300 --change-name=2:ROOTS   "${PARTITION_TARGET}"
    sgdisk --new=3:0:+"${OVERLAY_MIB}M" --typecode=3:8300 --change-name=3:OVERLAY "${PARTITION_TARGET}"
    sgdisk --new=4:0:0                   --typecode=4:8300 --change-name=4:HOME    "${PARTITION_TARGET}"
else
    parted -s "${PARTITION_TARGET}" mklabel gpt
    parted -s "${PARTITION_TARGET}" mkpart EFI fat32 1MiB "${EFI_MIB}MiB"
    parted -s "${PARTITION_TARGET}" mkpart ROOTS btrfs "${EFI_MIB}MiB" "${ROOTS_END_MIB}MiB"
    parted -s "${PARTITION_TARGET}" mkpart OVERLAY btrfs "${ROOTS_END_MIB}MiB" "${OVERLAY_END_MIB}MiB"
    parted -s "${PARTITION_TARGET}" mkpart HOME btrfs "${OVERLAY_END_MIB}MiB" 100%
    parted -s "${PARTITION_TARGET}" set 1 esp on
    parted -s "${PARTITION_TARGET}" name 1 EFI
    parted -s "${PARTITION_TARGET}" name 2 ROOTS
    parted -s "${PARTITION_TARGET}" name 3 OVERLAY
    parted -s "${PARTITION_TARGET}" name 4 HOME
fi

# Determine partition path convention for the target device.
if [[ -n "${DIRECT_DEVICE}" ]]; then
    if [[ "${DIRECT_DEVICE}" =~ /dev/loop[0-9]+$ || "${DIRECT_DEVICE}" =~ /dev/nbd[0-9]+$ ]]; then
        PART_SUFFIX="p"
    else
        PART_SUFFIX=""
    fi
    EFI_PART="${DIRECT_DEVICE}${PART_SUFFIX}1"
    ROOTS_PART="${DIRECT_DEVICE}${PART_SUFFIX}2"
    OVERLAY_PART="${DIRECT_DEVICE}${PART_SUFFIX}3"
    HOME_PART="${DIRECT_DEVICE}${PART_SUFFIX}4"
else
    # Attach the raw image to a loop device so partitions are addressable as
    # ${LOOP_DEV}pN. Requires a kernel with loop support (i.e. a real VM/host,
    # not a container).
    LOOP_DEV="$(losetup -fP --show "${RAW_IMG}")"
    # The -P scan can race udev; make sure partition nodes (${LOOP_DEV}pN) exist.
    partprobe "${LOOP_DEV}" 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || sleep 2

    EFI_PART="${LOOP_DEV}p1"
    ROOTS_PART="${LOOP_DEV}p2"
    OVERLAY_PART="${LOOP_DEV}p3"
    HOME_PART="${LOOP_DEV}p4"
fi

# When running inside the builder VM against a virtio disk, the kernel may not
# expose partition nodes synchronously. Wait until all four partitions appear.
if [[ -n "${DIRECT_DEVICE}" && ! "${DIRECT_DEVICE}" =~ /dev/loop[0-9]+$ && ! "${DIRECT_DEVICE}" =~ /dev/nbd[0-9]+$ ]]; then
    echo "Waiting for partitions on ${DIRECT_DEVICE}..."
    for _ in $(seq 1 30); do
        if [[ -b "${EFI_PART}" && -b "${ROOTS_PART}" && -b "${OVERLAY_PART}" && -b "${HOME_PART}" ]]; then
            break
        fi
        sleep 1
    done
fi

# Partition indexes for guestfish (1-based)
EFI_IDX=1
ROOTS_IDX=2
OVERLAY_IDX=3
HOME_IDX=4

ROOTS_TARGET="${ROOTS_PART}"

_secure_wipe_file() {
    local path="${1:-}"
    [[ -z "${path}" ]] && return 0
    local size
    size="$(stat -c %s "${path}" 2>/dev/null || echo 0)"
    if [[ "${size}" -gt 0 ]]; then
        dd if=/dev/zero of="${path}" bs=1 count="${size}" status=none 2>/dev/null || true
        sync "${path}" 2>/dev/null || true
    fi
    rm -f "${path}" 2>/dev/null || true
}

if [[ "${ENCRYPT}" == true ]]; then
    echo "Setting up LUKS encryption on ROOTS partition..."
    # Canonicalize the passphrase in /dev/shm with 0600 permissions.  Strip any
    # trailing newline because cryptsetup --key-file consumes the file verbatim.
    PASS_KEY_FILE="$(mktemp -p /dev/shm regicide-luks-XXXXXX)"
    chmod 0600 "${PASS_KEY_FILE}"
    if [[ "${PASSPHRASE_FILE}" == "-" ]]; then
        pass="$(cat)"
    else
        pass="$(cat "${PASSPHRASE_FILE}")"
    fi
    printf '%s' "${pass}" > "${PASS_KEY_FILE}"
    # GRUB's cryptomount only supports PBKDF2 (not Argon2id) for LUKS2.
    cryptsetup --batch-mode luksFormat --type luks2 --pbkdf pbkdf2 --label "${LUKS_NAME}" --key-file "${PASS_KEY_FILE}" "${ROOTS_PART}"
    cryptsetup open --type luks2 --key-file "${PASS_KEY_FILE}" "${ROOTS_PART}" "${LUKS_NAME}"
    _secure_wipe_file "${PASS_KEY_FILE}"
    ROOTS_TARGET="/dev/mapper/${LUKS_NAME}"
    LUKS_UUID=$(cryptsetup luksUUID "${ROOTS_PART}")
    echo "LUKS container opened: ${ROOTS_TARGET} (UUID: ${LUKS_UUID})"
fi

echo "Formatting partitions..."
mkfs.vfat -F 32 -n EFI "${EFI_PART}"
mkfs.btrfs -L OVERLAY "${OVERLAY_PART}"
mkfs.btrfs -L HOME "${HOME_PART}"
mkfs.btrfs -L ROOTS "${ROOTS_TARGET}"

echo "Creating overlay subvolumes..."
OVERLAY_TMP="$(mktemp -d)"
mount "${OVERLAY_PART}" "${OVERLAY_TMP}"
btrfs subvolume create "${OVERLAY_TMP}/etc"
btrfs subvolume create "${OVERLAY_TMP}/var"
btrfs subvolume create "${OVERLAY_TMP}/usr"
btrfs subvolume create "${OVERLAY_TMP}/home"
# Overlayfs workdirs must live INSIDE the matching subvolume: overlayfs
# creates files via workdir->upperdir rename, and renames across btrfs
# subvolume boundaries fail with EXDEV.
mkdir -p "${OVERLAY_TMP}/etc/upper" "${OVERLAY_TMP}/etc/work" "${OVERLAY_TMP}/var/upper" "${OVERLAY_TMP}/var/work" "${OVERLAY_TMP}/usr/upper" "${OVERLAY_TMP}/usr/work"
umount "${OVERLAY_TMP}"
rm -rf "${OVERLAY_TMP}"

echo "Creating home subvolume on HOME partition..."
HOME_TMP="$(mktemp -d)"
mount "${HOME_PART}" "${HOME_TMP}"
btrfs subvolume create "${HOME_TMP}/home"
umount "${HOME_TMP}"
rm -rf "${HOME_TMP}"

echo "Extracting tarball to ROOTS partition..."
ROOTS_TMP="$(mktemp -d)"
mount "${ROOTS_TARGET}" "${ROOTS_TMP}"

TAR_FLAGS="-xpf"
if [[ "${TARBALL}" == *.tar.xz || "${TARBALL}" == *.txz ]]; then
    TAR_FLAGS="-xpJf"
elif [[ "${TARBALL}" == *.tar.gz || "${TARBALL}" == *.tgz ]]; then
    TAR_FLAGS="-xpzf"
fi

if [[ "${TARBALL}" =~ \.(img|squashfs)$ ]]; then
    if ! command -v unsquashfs &> /dev/null; then
        echo "Error: unsquashfs is required to extract a SquashFS archive."
        exit 1
    fi
    unsquashfs -no-xattrs -f -d "${ROOTS_TMP}" "${TARBALL}"
    chown -R root:root "${ROOTS_TMP}/etc" "${ROOTS_TMP}/var" "${ROOTS_TMP}/usr/lib/systemd" 2>/dev/null || true
else
    tar -C "${ROOTS_TMP}" ${TAR_FLAGS} "${TARBALL}"
fi

mkdir -p "${ROOTS_TMP}/overlay" "${ROOTS_TMP}/home" "${ROOTS_TMP}/boot/efi"

# Pre-create state directories so systemd services do not attempt
# cross-device provisioning on the /var overlay (EXDEV), and pam_lastlog2
# has a writable database directory.
mkdir -p "${ROOTS_TMP}/var/lib/systemd" "${ROOTS_TMP}/var/lib/lastlog"

echo "Seeding home subvolume from rootfs /home..."
HOME_TMP="$(mktemp -d)"
mount "${HOME_PART}" "${HOME_TMP}"
cp -a "${ROOTS_TMP}/home/." "${HOME_TMP}/home/"
# The rootfs cleanup pass chowns uid-1000 files to root; restore the user
# home to uid 1000 so the session can chdir into it.
chown -R 1000:1000 "${HOME_TMP}/home/regicide" 2>/dev/null || true
umount "${HOME_TMP}"
rm -rf "${HOME_TMP}"

echo "Creating /etc/fstab..."
ROOTS_FSTAB_SPEC="LABEL=ROOTS"
if [[ "${ENCRYPT}" == true ]]; then
    ROOTS_FSTAB_SPEC="/dev/mapper/${LUKS_NAME}"
fi

cat > "${ROOTS_TMP}/etc/fstab" << EOF
# RegicideOSArch QEMU image fstab
# Generated by build-qemu-image.sh

${ROOTS_FSTAB_SPEC}   /       btrfs   defaults,noatime           0 0
LABEL=OVERLAY /overlay btrfs   defaults,noatime           0 0
LABEL=HOME    /home   btrfs   subvol=home,defaults,noatime  0 0
EOF

# Mount /etc, /var and /usr as overlayfs via systemd .mount units, NOT fstab.
# A /usr overlay in fstab gets mounted by the initramfs's initrd-parse-etc
# with the initramfs's own (busybox) /usr as lowerdir, which hides the real
# /usr after switch-root (and trips the initrd assert targets). The .mount
# units only run in the real root, after overlay.mount.
install -d "${ROOTS_TMP}/etc/systemd/system/local-fs.target.wants"
for dir in etc var usr; do
    cat > "${ROOTS_TMP}/etc/systemd/system/${dir}.mount" << EOF
[Unit]
Description=Overlay mount for /${dir}
Requires=overlay.mount
After=overlay.mount local-fs-pre.target
Before=local-fs.target
DefaultDependencies=no

[Mount]
What=overlay
Where=/${dir}
Type=overlay
# Overlayfs workdirs must live inside the matching subvolume (renames
# across btrfs subvolumes fail with EXDEV).
Options=lowerdir=/${dir},upperdir=/overlay/${dir}/upper,workdir=/overlay/${dir}/work

[Install]
WantedBy=local-fs.target
EOF
    ln -sf "../${dir}.mount" \
        "${ROOTS_TMP}/etc/systemd/system/local-fs.target.wants/${dir}.mount"
done

if [[ "${ENCRYPT}" == true ]]; then
    cat >> "${ROOTS_TMP}/etc/fstab" << EOF

# Encrypted ROOTS backing device (informational)
# UUID=${LUKS_UUID} /dev/mapper/${LUKS_NAME} luks defaults 0 0
EOF
    cat > "${ROOTS_TMP}/etc/crypttab" << EOF
${LUKS_NAME} UUID=${LUKS_UUID} none luks
EOF
fi

echo "Running GRUB installation and initramfs rebuild inside chroot..."
# Bind-mount targets may not exist in the extracted rootfs (e.g. empty /dev).
mkdir -p "${ROOTS_TMP}/dev" "${ROOTS_TMP}/proc" "${ROOTS_TMP}/sys" \
    "${ROOTS_TMP}/run" "${ROOTS_TMP}/boot/efi"
mount "${EFI_PART}" "${ROOTS_TMP}/boot/efi"
mount --bind /dev "${ROOTS_TMP}/dev"
mount --bind /proc "${ROOTS_TMP}/proc"
mount --bind /sys "${ROOTS_TMP}/sys"
mount --bind /run "${ROOTS_TMP}/run"
mkdir -p "${ROOTS_TMP}/tmp"
mount -t tmpfs -o mode=1777,nodev,nosuid,size=2G tmpfs "${ROOTS_TMP}/tmp"

# Unset TMPDIR so mkinitcpio inside the chroot does not try to use the
# host-side temporary directory (which does not exist in the chroot).
env -u TMPDIR chroot "${ROOTS_TMP}" /bin/bash -c '
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    if [[ ! -f /etc/default/grub ]]; then
        mkdir -p /etc/default
        cat > /etc/default/grub << GRUBDEFAULT
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="RegicideOSArch"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_PRELOAD_MODULES="part_gpt"
GRUBDEFAULT
    fi

    mkinitcpio -P

    grub-install \
        --modules="cryptodisk luks luks2 gcry_rijndael gcry_sha256 gcry_sha1 argon2 part_gpt lvm" \
        --force \
        --target="x86_64-efi" \
        --efi-directory="/boot/efi" \
        --boot-directory="/boot/efi" \
        --removable \
        --recheck \
        --no-nvram
'

echo "Creating GRUB configuration..."
mkdir -p "${ROOTS_TMP}/boot/efi/grub"
mkdir -p "${ROOTS_TMP}/boot/efi/EFI/fedora"

if [[ ! -f "${ROOTS_TMP}/boot/vmlinuz-linux" ]]; then
    KERNEL_SRC=$(find "${ROOTS_TMP}/boot" -maxdepth 1 -name 'vmlinuz-*' -type f | head -n1 || true)
    if [[ -n "${KERNEL_SRC}" ]]; then
        cp "${KERNEL_SRC}" "${ROOTS_TMP}/boot/vmlinuz-linux"
    else
        echo "Error: no kernel found in /boot"
        exit 1
    fi
fi

if [[ ! -f "${ROOTS_TMP}/boot/initramfs-linux.img" ]]; then
    INITRD_SRC=$(find "${ROOTS_TMP}/boot" -maxdepth 1 \( -name 'initramfs-*' -o -name 'initrd-*' \) -type f | head -n1 || true)
    if [[ -n "${INITRD_SRC}" ]]; then
        cp "${INITRD_SRC}" "${ROOTS_TMP}/boot/initramfs-linux.img"
    else
        echo "Error: no initramfs found in /boot"
        exit 1
    fi
fi

ROOTS_GRUB="root=LABEL=ROOTS"
if [[ "${ENCRYPT}" == true ]]; then
    # rd.luks.name maps the container under a stable name without relying on
    # /etc/crypttab being embedded in the initramfs (mkinitcpio's sd-encrypt
    # hook does not include it, which would leave root= unresolvable).
    ROOTS_GRUB="rd.luks.name=${LUKS_UUID}=${LUKS_NAME} root=/dev/mapper/${LUKS_NAME}"
fi

cat > "${ROOTS_TMP}/boot/efi/grub/grub.cfg" << GRUBEOF
set default="RegicideOSArch"
set timeout=5
set color_normal=light-gray/black
set color_highlight=green/black

GRUBEOF

if [[ "${ENCRYPT}" == true ]]; then
    # The ROOTS label lives inside the LUKS container; unlock it first so
    # the search below can find the btrfs filesystem (as crypto0).
    cat >> "${ROOTS_TMP}/boot/efi/grub/grub.cfg" << GRUBEOF
cryptomount -u ${LUKS_UUID//-/}
GRUBEOF
fi

cat >> "${ROOTS_TMP}/boot/efi/grub/grub.cfg" << GRUBEOF
search --no-floppy --label --set=roots ROOTS

menuentry "RegicideOSArch" {
    linux (\$roots)/boot/vmlinuz-linux ${ROOTS_GRUB} quiet splash rw console=ttyS0,115200n8
    initrd (\$roots)/boot/initramfs-linux.img
}

menuentry "RegicideOSArch (Recovery)" {
    linux (\$roots)/boot/vmlinuz-linux ${ROOTS_GRUB} quiet splash rw single console=ttyS0,115200n8
    initrd (\$roots)/boot/initramfs-linux.img
}

menuentry "RegicideOSArch (Verbose)" {
    linux (\$roots)/boot/vmlinuz-linux ${ROOTS_GRUB} verbose rw console=ttyS0,115200n8
    initrd (\$roots)/boot/initramfs-linux.img
}
GRUBEOF

ln -sf "${ROOTS_TMP}/boot/efi/grub/grub.cfg" "${ROOTS_TMP}/boot/efi/EFI/fedora/grub.cfg" 2>/dev/null || \
    cp "${ROOTS_TMP}/boot/efi/grub/grub.cfg" "${ROOTS_TMP}/boot/efi/EFI/fedora/grub.cfg"

mkdir -p "${ROOTS_TMP}/etc/default"
GRUB_CMDLINE=""
if [[ "${ENCRYPT}" == true ]]; then
    GRUB_CMDLINE="rd.luks.name=${LUKS_UUID}=${LUKS_NAME} root=/dev/mapper/${LUKS_NAME}"
fi

cat > "${ROOTS_TMP}/etc/default/grub" << GRUBDEFAULT
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="RegicideOSArch"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash console=ttyS0,115200n8"
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE}"
GRUB_ENABLE_CRYPTODISK=y
GRUB_PRELOAD_MODULES="cryptodisk luks luks2 gcry_rijndael gcry_sha256 gcry_sha1 argon2 part_gpt lvm"
GRUBDEFAULT

echo "Unmounting chroot filesystems..."
umount "${ROOTS_TMP}/tmp"  2>/dev/null || true
umount "${ROOTS_TMP}/run"  2>/dev/null || true
umount "${ROOTS_TMP}/sys"  2>/dev/null || true
umount "${ROOTS_TMP}/proc" 2>/dev/null || true
umount "${ROOTS_TMP}/dev"  2>/dev/null || true
umount "${ROOTS_TMP}/boot/efi" 2>/dev/null || true
umount "${ROOTS_TMP}"      2>/dev/null || true

if [[ "${ENCRYPT}" == true ]]; then
    echo "Closing LUKS container..."
    cryptsetup close "${LUKS_NAME}" 2>/dev/null || true
fi

rm -rf "${ROOTS_TMP}"

if [[ "${NO_CONVERT}" == false ]]; then
    echo "Converting raw image to QCOW2..."
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img convert -f raw -O qcow2 "${RAW_IMG}" "${OUTPUT}"
    else
        # No qemu-img available (e.g. inside a minimal builder VM): keep the raw
        # image; convert on the host afterwards.
        echo "qemu-img not found; leaving raw image at ${OUTPUT}"
        mv "${RAW_IMG}" "${OUTPUT}"
        RAW_IMG=""
    fi

    rm -f "${RAW_IMG}"
fi

RUNNER_PATH="${OUTPUT_DIR}/run-qemu.sh"
cat > "${RUNNER_PATH}" << QEMUEOF
#!/bin/bash
# RegicideOSArch QEMU Runner
# Auto-generated by build-qemu-image.sh

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
    -drive file="\${IMAGE_PATH}",format=qcow2,if=virtio \\
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \\
    -device virtio-net-pci,netdev=net0 \\
    -vga virtio \\
    -display sdl,gl=on \\
    -machine type=q35,accel=kvm \\
    \${UEFI_FLAGS} \\
    \$@
QEMUEOF

chmod +x "${RUNNER_PATH}"

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
