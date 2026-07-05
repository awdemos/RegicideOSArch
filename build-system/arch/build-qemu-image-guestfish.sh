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
DISK_SIZE="20G"
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
}
cleanup() {
    echo "Cleaning up..."
    rm -f "${RAW_IMG}" 2>/dev/null || true
    rm -f "${PLAIN_TAR}" 2>/dev/null || true
    rm -rf "${UNTARRED_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "Creating raw disk image (${DISK_SIZE})..."
qemu-img create -f raw "${RAW_IMG}" "${DISK_SIZE}"

echo "Partitioning disk image..."
sgdisk --clear "${RAW_IMG}"
sgdisk --new=1:0:+512M   --typecode=1:ef00 --change-name=1:EFI     "${RAW_IMG}"
sgdisk --new=2:0:+14G    --typecode=2:8300 --change-name=2:ROOTS   "${RAW_IMG}"
sgdisk --new=3:0:+4G     --typecode=3:8300 --change-name=3:OVERLAY "${RAW_IMG}"
sgdisk --new=4:0:0       --typecode=4:8300 --change-name=4:HOME    "${RAW_IMG}"

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

  # Create overlay subvolumes
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

echo "Writing /etc/fstab inside guestfish..."
FSTAB_TMP="$(mktemp)"
cat > "${FSTAB_TMP}" << EOF
# RegicideOSArch QEMU image fstab
# Generated by build-qemu-image-guestfish.sh

LABEL=ROOTS   /       btrfs   defaults,noatime           0 0
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

guestfish <<GFISH
  add-drive "${RAW_IMG}" format:raw
  run
  mount "/dev/sda${ROOTS_IDX}" /
  upload "${FSTAB_TMP}" /etc/fstab
  chmod 0644 /etc/fstab
  mkdir-p /etc/modules-load.d
  upload "${MODULES_TMP}" /etc/modules-load.d/regicide-btrfs.conf
  chmod 0644 /etc/modules-load.d/regicide-btrfs.conf
  upload "${MASK_TMP}" /root/regicide-mask.sh
  chmod 0755 /root/regicide-mask.sh
  command "/root/regicide-mask.sh"
GFISH

rm -f "${MODULES_TMP}" "${MASK_TMP}"

rm -f "${FSTAB_TMP}"

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
    -serial file:/tmp/regicide-serial.log \\
    -monitor unix:/tmp/regicide-monitor.sock,server,nowait \\
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
