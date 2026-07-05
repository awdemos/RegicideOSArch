#!/bin/bash
# RegicideOSArch QEMU Disk Image Builder (guestmount-based)
# Creates a bootable QCOW2 disk image from a RegicideOSArch tarball.
# This version uses libguestfs/guestmount so it does not require host loop devices.

set -euo pipefail

# Use the libguestfs direct backend so we do not depend on libvirt.
export LIBGUESTFS_BACKEND=direct

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARBALL=""
OUTPUT="${SCRIPT_DIR}/output/regicide-arch.qcow2"
DISK_SIZE="20G"
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

REQUIRED_CMDS=(qemu-img guestfish sgdisk mkfs.vfat mkfs.btrfs btrfs qemu-img tar guestmount fusermount3)
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

ROOTS_TMP=""
OVERLAY_TMP=""

IS_MOUNTED=false
IS_LUKS_OPEN=false

cleanup() {
    echo "Cleaning up..."
    if [[ "${IS_MOUNTED}" == true && -n "${ROOTS_TMP}" ]]; then
        guestunmount "${ROOTS_TMP}" 2>/dev/null || true
    fi
    if [[ "${ENCRYPT}" == true && "${IS_LUKS_OPEN}" == true ]]; then
        cryptsetup close "${LUKS_NAME}" 2>/dev/null || true
    fi
    rm -rf "${ROOTS_TMP}" 2>/dev/null || true
    rm -f "${RAW_IMG}" 2>/dev/null || true
}
trap cleanup EXIT

echo "Creating raw disk image (${DISK_SIZE})..."
qemu-img create -f raw "${RAW_IMG}" "${DISK_SIZE}"

echo "Partitioning disk image..."
sgdisk --clear "${RAW_IMG}"
sgdisk --new=1:0:+512M   --typecode=1:ef00 --change-name=1:EFI     "${RAW_IMG}"
sgdisk --new=2:0:+12G    --typecode=2:8300 --change-name=2:ROOTS   "${RAW_IMG}"
sgdisk --new=3:0:+4G     --typecode=3:8300 --change-name=3:OVERLAY "${RAW_IMG}"
sgdisk --new=4:0:0       --typecode=4:8300 --change-name=4:HOME    "${RAW_IMG}"

# Partition indexes for guestfish (1-based)
EFI_IDX=1
ROOTS_IDX=2
OVERLAY_IDX=3
HOME_IDX=4

echo "Formatting partitions inside guestfish..."
guestfish <<GFISH
  add-drive "${RAW_IMG}" format:raw
  run
  mkfs vfat "/dev/sda${EFI_IDX}" label:EFI
  mkfs btrfs "/dev/sda${OVERLAY_IDX}" label:OVERLAY
  mkfs btrfs "/dev/sda${HOME_IDX}" label:HOME
GFISH

if [[ "${ENCRYPT}" == true ]]; then
    echo "Setting up LUKS encryption on ROOTS partition..."
    if [[ "${PASSPHRASE_FILE}" == "-" ]]; then
        guestfish <<GFISH
          add-drive "${RAW_IMG}" format:raw
          run
          luks-format "/dev/sda${ROOTS_IDX}" "-" 0
GFISH
        # Open with cryptsetup on the partition device exposed by guestfish
        CRYPT_DEV=$(guestfish add-drive:"${RAW_IMG}" format:raw : run : blockdev-getsz "/dev/sda${ROOTS_IDX}" 2>/dev/null || true)
    else
        guestfish <<GFISH
          add-drive "${RAW_IMG}" format:raw
          run
          luks-format "/dev/sda${ROOTS_IDX}" "file:${PASSPHRASE_FILE}" 0
GFISH
    fi
    echo "LUKS formatting complete. Opening container..."
    # Use guestfish to expose the raw device and open it via cryptsetup using a device-mapper name
    # guestfish luks-open creates /dev/mapper/<name> inside the appliance, but for host mount we
    # need a different approach. Fallback: mount ROOTS after luks-open inside guestfish and copy.
    echo "Encrypted images require loop devices or a libguestfs-only workflow; guestmount/chroot is"
    echo "not practical for LUKS inside this environment. Please use the original"
    echo "build-qemu-image.sh on a host with loop device support for encryption."
    exit 1
fi

echo "Formatting ROOTS partition..."
guestfish <<GFISH
  add-drive "${RAW_IMG}" format:raw
  run
  mkfs btrfs "/dev/sda${ROOTS_IDX}" label:ROOTS
GFISH

echo "Creating overlay subvolumes..."
guestfish <<GFISH
  add-drive "${RAW_IMG}" format:raw
  run
  mount "/dev/sda${OVERLAY_IDX}" /
  btrfs-subvolume-create /etc
  btrfs-subvolume-create /var
  btrfs-subvolume-create /usr
  btrfs-subvolume-create /home
  mkdir-p /etcw
  mkdir-p /varw
  mkdir-p /usrw
  umount /
GFISH

echo "Extracting tarball directly into ROOTS via guestfish (faster than FUSE)..."
guestfish <<GFISH
  add-drive "${RAW_IMG}" format:raw
  run
  mount "/dev/sda${ROOTS_IDX}" /
  tar-in "${TARBALL}" / compress:xz
  mkdir-p /overlay
  mkdir-p /home
  mkdir-p /boot/efi
GFISH

echo "Creating /etc/fstab inside guestfish..."
FSTAB_TMP="$(mktemp)"
cat > "${FSTAB_TMP}" << EOF
# RegicideOSArch QEMU image fstab
# Generated by build-qemu-image-guestmount.sh

LABEL=ROOTS   /       btrfs   defaults,noatime           0 0
LABEL=OVERLAY /overlay btrfs   defaults,noatime           0 0
LABEL=HOME    /home   btrfs   defaults,noatime           0 0
overlay       /etc    overlay lowerdir=/etc,upperdir=/overlay/etc,workdir=/overlay/etcw,x-systemd.requires=/overlay 0 0
overlay       /var    overlay lowerdir=/var,upperdir=/overlay/var,workdir=/overlay/varw,x-systemd.requires=/overlay 0 0
overlay       /usr    overlay lowerdir=/usr,upperdir=/overlay/usr,workdir=/overlay/usrw,x-systemd.requires=/overlay 0 0
EOF

guestfish <<GFISH
  add-drive "${RAW_IMG}" format:raw
  run
  mount "/dev/sda${ROOTS_IDX}" /
  upload "${FSTAB_TMP}" /etc/fstab
  chmod 0644 /etc/fstab
GFISH

rm -f "${FSTAB_TMP}"

echo "Mounting ROOTS via guestmount for chroot..."
ROOTS_TMP="$(mktemp -d)"
guestmount -a "${RAW_IMG}" -m "/dev/sda${ROOTS_IDX}" --rw "${ROOTS_TMP}"
IS_MOUNTED=true

echo "Mounting EFI and bind-mounting kernel filesystems..."
guestmount -a "${RAW_IMG}" -m "/dev/sda${EFI_IDX}" --rw "${ROOTS_TMP}/boot/efi"
mount --bind /dev "${ROOTS_TMP}/dev"
mount --bind /proc "${ROOTS_TMP}/proc"
mount --bind /sys "${ROOTS_TMP}/sys"
mount --bind /run "${ROOTS_TMP}/run"

echo "Running GRUB installation and initramfs rebuild inside chroot..."
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
    KERNEL_SRC=$(find "${ROOTS_TMP}/boot" -maxdepth 1 -name '"'"'vmlinuz-*'"'"' -type f | head -n1 || true)
    if [[ -n "${KERNEL_SRC}" ]]; then
        cp "${KERNEL_SRC}" "${ROOTS_TMP}/boot/vmlinuz-linux"
    else
        echo "Error: no kernel found in /boot"
        exit 1
    fi
fi

if [[ ! -f "${ROOTS_TMP}/boot/initramfs-linux.img" ]]; then
    INITRD_SRC=$(find "${ROOTS_TMP}/boot" -maxdepth 1 \( -name '"'"'initramfs-*'"'"' -o -name '"'"'initrd-*'"'"' \) -type f | head -n1 || true)
    if [[ -n "${INITRD_SRC}" ]]; then
        cp "${INITRD_SRC}" "${ROOTS_TMP}/boot/initramfs-linux.img"
    else
        echo "Error: no initramfs found in /boot"
        exit 1
    fi
fi

ROOTS_GRUB="root=LABEL=ROOTS"

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
cat > "${ROOTS_TMP}/etc/default/grub" << GRUBDEFAULT
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="RegicideOSArch"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_PRELOAD_MODULES="part_gpt"
GRUBDEFAULT

echo "Unmounting chroot filesystems..."
umount "${ROOTS_TMP}/run"  2>/dev/null || true
umount "${ROOTS_TMP}/sys"  2>/dev/null || true
umount "${ROOTS_TMP}/proc" 2>/dev/null || true
umount "${ROOTS_TMP}/dev"  2>/dev/null || true
guestunmount "${ROOTS_TMP}/boot/efi" 2>/dev/null || true
guestunmount "${ROOTS_TMP}"      2>/dev/null || true
IS_MOUNTED=false

rm -rf "${ROOTS_TMP}"

echo "Converting raw image to QCOW2..."
qemu-img convert -f raw -O qcow2 "${RAW_IMG}" "${OUTPUT}"

RUNNER_PATH="${OUTPUT_DIR}/run-qemu.sh"
cat > "${RUNNER_PATH}" << QEMUEOF
#!/bin/bash
# RegicideOSArch QEMU Runner
# Auto-generated by build-qemu-image-guestmount.sh

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
    /usr/share/ovmf/x64/OVMF_CODE.fd \\
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
    /usr/share/ovmf/x64/OVMF_VARS.fd \\
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
