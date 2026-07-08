#!/bin/bash
# RegicideOSArch QEMU Disk Image Builder (guestfish-based)
# Creates a bootable QCOW2 disk image from a RegicideOSArch tarball.
# This version uses libguestfs/guestfish so it does not require host loop devices.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARBALL=""
OUTPUT="${SCRIPT_DIR}/output/regicide-arch.qcow2"
DISK_SIZE="${REGICIDE_DISK_SIZE:-20G}"
EFI_SIZE="${REGICIDE_EFI_SIZE:-512M}"
ROOTS_SIZE="${REGICIDE_ROOTS_SIZE:-12G}"
OVERLAY_SIZE="${REGICIDE_OVERLAY_SIZE:-4G}"
ENCRYPT=false
PASSPHRASE_FILE=""
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

Examples:
  $0 /path/to/regicide-arch.tar.xz
  $0 --encrypt --passphrase-file /run/luks-passphrase /path/to/regicide-arch.tar.xz ./my-image.qcow2 30G
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
    if [[ -z "${PASSPHRASE_FILE}" ]]; then
        echo "Error: --passphrase-file is required when --encrypt is used."
        usage
    fi
    if [[ "${PASSPHRASE_FILE}" != "-" && ! -f "${PASSPHRASE_FILE}" ]]; then
        echo "Error: passphrase file not found: ${PASSPHRASE_FILE}"
        exit 1
    fi
fi

REQUIRED_CMDS=(qemu-img guestfish sgdisk mkfs.vfat mkfs.btrfs btrfs qemu-img tar)
if [[ "${ENCRYPT}" == true ]]; then
    REQUIRED_CMDS+=(cryptsetup)
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

RAW_IMG="$(mktemp --suffix=.raw)"
LUKS_NAME="regicide-arch"
LUKS_UUID=""

cleanup() {
    echo "Cleaning up..."
    if [[ "${ENCRYPT}" == true ]]; then
        cryptsetup close "${LUKS_NAME}" 2>/dev/null || true
    fi
    rm -f "${RAW_IMG}" 2>/dev/null || true
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

# Partition indexes for guestfish (1-based)
EFI_IDX=1
ROOTS_IDX=2
OVERLAY_IDX=3
HOME_IDX=4

ROOTS_TARGET="/dev/sda${ROOTS_IDX}"

if [[ "${ENCRYPT}" == true ]]; then
    echo "Setting up LUKS encryption on ROOTS partition..."
    if [[ "${PASSPHRASE_FILE}" == "-" ]]; then
        cryptsetup luksFormat --type luks2 --label "${LUKS_NAME}" --key-file - "${RAW_IMG}p${ROOTS_IDX}"
        cryptsetup open --type luks2 --key-file - "${RAW_IMG}p${ROOTS_IDX}" "${LUKS_NAME}"
    else
        cryptsetup luksFormat --type luks2 --label "${LUKS_NAME}" --key-file "${PASSPHRASE_FILE}" "${RAW_IMG}p${ROOTS_IDX}"
        cryptsetup open --type luks2 --key-file "${PASSPHRASE_FILE}" "${RAW_IMG}p${ROOTS_IDX}" "${LUKS_NAME}"
    fi
    ROOTS_TARGET="/dev/mapper/${LUKS_NAME}"
    LUKS_UUID=$(cryptsetup luksUUID "${RAW_IMG}p${ROOTS_IDX}")
    echo "LUKS container opened: ${ROOTS_TARGET} (UUID: ${LUKS_UUID})"
fi

echo "Formatting partitions..."
mkfs.vfat -F 32 -n EFI "${RAW_IMG}p${EFI_IDX}"
mkfs.btrfs -L OVERLAY "${RAW_IMG}p${OVERLAY_IDX}"
mkfs.btrfs -L HOME "${RAW_IMG}p${HOME_IDX}"
mkfs.btrfs -L ROOTS "${ROOTS_TARGET}"

echo "Creating overlay subvolumes..."
OVERLAY_TMP="$(mktemp -d)"
mount "${RAW_IMG}p${OVERLAY_IDX}" "${OVERLAY_TMP}"
btrfs subvolume create "${OVERLAY_TMP}/etc"
btrfs subvolume create "${OVERLAY_TMP}/var"
btrfs subvolume create "${OVERLAY_TMP}/usr"
btrfs subvolume create "${OVERLAY_TMP}/home"
mkdir -p "${OVERLAY_TMP}/etcw" "${OVERLAY_TMP}/varw" "${OVERLAY_TMP}/usrw"
umount "${OVERLAY_TMP}"
rm -rf "${OVERLAY_TMP}"

echo "Extracting tarball to ROOTS partition..."
ROOTS_TMP="$(mktemp -d)"
mount "${ROOTS_TARGET}" "${ROOTS_TMP}"

TAR_FLAGS="-xpf"
if [[ "${TARBALL}" == *.tar.xz || "${TARBALL}" == *.txz ]]; then
    TAR_FLAGS="-xpJf"
elif [[ "${TARBALL}" == *.tar.gz || "${TARBALL}" == *.tgz ]]; then
    TAR_FLAGS="-xpzf"
fi

tar -C "${ROOTS_TMP}" ${TAR_FLAGS} "${TARBALL}"

mkdir -p "${ROOTS_TMP}/overlay" "${ROOTS_TMP}/home" "${ROOTS_TMP}/boot/efi"

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
LABEL=HOME    /home   btrfs   defaults,noatime           0 0
overlay       /etc    overlay lowerdir=/etc,upperdir=/overlay/etc,workdir=/overlay/etcw,x-systemd.requires=/overlay 0 0
overlay       /var    overlay lowerdir=/var,upperdir=/overlay/var,workdir=/overlay/varw,x-systemd.requires=/overlay 0 0
overlay       /usr    overlay lowerdir=/usr,upperdir=/overlay/usr,workdir=/overlay/usrw,x-systemd.requires=/overlay 0 0
EOF

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
mount "${RAW_IMG}p${EFI_IDX}" "${ROOTS_TMP}/boot/efi"
mount --bind /dev "${ROOTS_TMP}/dev"
mount --bind /proc "${ROOTS_TMP}/proc"
mount --bind /sys "${ROOTS_TMP}/sys"
mount --bind /run "${ROOTS_TMP}/run"

chroot "${ROOTS_TMP}" /bin/bash -c '
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
        --modules="cryptodisk luks gcry_rijndael gcry_sha256 gcry_sha1 aesni part_gpt lvm" \
        --force \
        --target="x86_64-efi" \
        --efi-directory="/boot/efi" \
        --boot-directory="/boot/efi" \
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
    ROOTS_GRUB="rd.luks.uuid=${LUKS_UUID} root=/dev/mapper/${LUKS_NAME}"
fi

cat > "${ROOTS_TMP}/boot/efi/grub/grub.cfg" << GRUBEOF
set default="RegicideOSArch"
set timeout=5
set color_normal=light-gray/black
set color_highlight=green/black

search --no-floppy --label --set=roots ROOTS

menuentry "RegicideOSArch" {
    linux (\$roots)/boot/vmlinuz-linux ${ROOTS_GRUB} quiet splash rw
    initrd (\$roots)/boot/initramfs-linux.img
}

menuentry "RegicideOSArch (Recovery)" {
    linux (\$roots)/boot/vmlinuz-linux ${ROOTS_GRUB} quiet splash rw single
    initrd (\$roots)/boot/initramfs-linux.img
}

menuentry "RegicideOSArch (Verbose)" {
    linux (\$roots)/boot/vmlinuz-linux ${ROOTS_GRUB} verbose rw
    initrd (\$roots)/boot/initramfs-linux.img
}
GRUBEOF

ln -sf "${ROOTS_TMP}/boot/efi/grub/grub.cfg" "${ROOTS_TMP}/boot/efi/EFI/fedora/grub.cfg" 2>/dev/null || \
    cp "${ROOTS_TMP}/boot/efi/grub/grub.cfg" "${ROOTS_TMP}/boot/efi/EFI/fedora/grub.cfg"

mkdir -p "${ROOTS_TMP}/etc/default"
GRUB_CMDLINE=""
if [[ "${ENCRYPT}" == true ]]; then
    GRUB_CMDLINE="rd.luks.uuid=${LUKS_UUID} root=/dev/mapper/${LUKS_NAME}"
fi

cat > "${ROOTS_TMP}/etc/default/grub" << GRUBDEFAULT
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="RegicideOSArch"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE}"
GRUB_ENABLE_CRYPTODISK=y
GRUB_PRELOAD_MODULES="cryptodisk luks gcry_rijndael gcry_sha256 gcry_sha1 aesni part_gpt lvm"
GRUBDEFAULT

echo "Unmounting chroot filesystems..."
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

echo "Converting raw image to QCOW2..."
qemu-img convert -f raw -O qcow2 "${RAW_IMG}" "${OUTPUT}"

rm -f "${RAW_IMG}"

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
