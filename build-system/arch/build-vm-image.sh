#!/bin/bash
# RegicideOSArch VM-based disk image builder
#
# Builds a bootable QCOW2 disk image from a RegicideOSArch tarball by booting
# the Arch rootfs inside a KVM VM and running build-qemu-image.sh against a
# virtio block device. This avoids loop devices, which are unavailable in the
# unprivileged container build environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARBALL=""
OUTPUT="${SCRIPT_DIR}/output/regicide-arch-enc.qcow2"
DISK_SIZE="${REGICIDE_DISK_SIZE:-30G}"
ENCRYPT=false
PASSPHRASE_FILE=""
SQUASHFS=""
_positional_index=0

usage() {
    cat << EOF
Usage: $0 [OPTIONS] <regicide-arch-tarball> [output-qcow2] [disk-size]

  regicide-arch-tarball  Path to the regicide-arch rootfs archive.
                         Accepted formats: .tar.xz tarball or the live
                         SquashFS image (.img).
  output-qcow2           Path for the output .qcow2 file (optional)
  disk-size              Disk size for the image, e.g. 20G (optional, default: 20G)

Options:
  --encrypt              Encrypt the ROOTS partition with LUKS2
  --passphrase-file      Path to a file containing the LUKS passphrase
                         (required with --encrypt; use - for stdin)
  --squashfs             Path to the live SquashFS image used to extract the
                         kernel and initramfs (optional; defaults to the
                         regicide-arch.img sibling of the output)

Examples:
  $0 /path/to/regicide-arch.tar.xz ./regicide-arch-enc.qcow2 20G
  $0 --encrypt --passphrase-file /run/luks-pass /path/to/regicide-arch.tar.xz ./image.qcow2
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
        --squashfs)
            SQUASHFS="${2:-}"
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
            _positional_index=$((_positional_index + 1))
            if [[ "${_positional_index}" -eq 1 ]]; then
                TARBALL="$1"
            elif [[ "${_positional_index}" -eq 2 ]]; then
                OUTPUT="$1"
            elif [[ "${_positional_index}" -eq 3 ]]; then
                DISK_SIZE="$1"
            else
                echo "Error: unexpected positional argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "${TARBALL}" ]]; then
    echo "Error: stage4 archive path is required."
    usage
fi
if [[ ! -f "${TARBALL}" ]]; then
    echo "Error: stage4 archive not found: ${TARBALL}"
    exit 1
fi
if [[ "${ENCRYPT}" == true && -z "${PASSPHRASE_FILE}" ]]; then
    echo "Error: --passphrase-file is required when --encrypt is used."
    usage
fi
if [[ "${ENCRYPT}" == true && "${PASSPHRASE_FILE}" != "-" && ! -f "${PASSPHRASE_FILE}" ]]; then
    echo "Error: passphrase file not found: ${PASSPHRASE_FILE}"
    exit 1
fi

TARBALL="$(realpath -e "${TARBALL}")"
OUTPUT="$(realpath -m "${OUTPUT}")"
OUTPUT_DIR="$(dirname "${OUTPUT}")"
mkdir -p "${OUTPUT_DIR}"

if [[ -z "${SQUASHFS}" ]]; then
    for candidate in \
        "${OUTPUT_DIR}/regicide-arch.img" \
        "${SCRIPT_DIR}/output/regicide-arch.img" \
        "$(dirname "${TARBALL}")/regicide-arch.img" \
        "${SCRIPT_DIR}/../regicide-arch.img"; do
        if [[ -f "${candidate}" ]]; then
            SQUASHFS="${candidate}"
            break
        fi
    done
fi
if [[ ! -f "${SQUASHFS}" ]]; then
    echo "Error: SquashFS image not found: ${SQUASHFS}"
    echo "       Build the SquashFS first, or pass --squashfs."
    exit 1
fi
SQUASHFS="$(realpath -e "${SQUASHFS}")"

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
REQUIRED_CMDS=(qemu-img qemu-system-x86_64 unsquashfs mksquashfs tar cpio zstd cryptsetup depmod parted python3)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "${cmd}" &> /dev/null; then
        echo "Error: required command '${cmd}' not found."
        exit 1
    fi
done

if [[ ! -e /dev/kvm ]]; then
    echo "Error: /dev/kvm is required for the VM-based builder."
    exit 1
fi

# ---------------------------------------------------------------------------
# Temp workspace
# ---------------------------------------------------------------------------
REGICIDE_WORK_DIR="/var/home/a/.regicide-work"
mkdir -p "${REGICIDE_WORK_DIR}"
WORK_DIR="$(TMPDIR="${REGICIDE_WORK_DIR}" mktemp -d)"
cleanup() {
    if [[ "${REGICIDE_DEBUG_KEEP_WORK_DIR:-0}" == "1" ]]; then
        echo "Debug: keeping work directory: ${WORK_DIR}"
    else
        rm -rf "${WORK_DIR}" 2>/dev/null || true
    fi
    if [[ -n "${FW_CFG_PASSPHRASE_FILE:-}" && -f "${FW_CFG_PASSPHRASE_FILE}" ]]; then
        python3 - "${FW_CFG_PASSPHRASE_FILE}" <<'PYEOF'
import os, sys
try:
    with open(sys.argv[1], "rb+") as f:
        size = f.seek(0, os.SEEK_END)
        f.seek(0)
        f.write(b"\x00" * size)
        f.flush()
        os.fsync(f.fileno())
except OSError:
    pass
PYEOF
        rm -f "${FW_CFG_PASSPHRASE_FILE}" 2>/dev/null || true
    fi
}
trap cleanup EXIT
REGICIDE_DEBUG_KEEP_WORK_DIR="${REGICIDE_DEBUG_KEEP_WORK_DIR:-0}"

TARGET_RAW="${WORK_DIR}/target.raw"
KERNEL="${WORK_DIR}/kernel"
INITRD="${WORK_DIR}/initrd"

# ---------------------------------------------------------------------------
# Create target disk
# ---------------------------------------------------------------------------
echo "Creating target raw disk (${DISK_SIZE})..."
qemu-img create -f raw "${TARGET_RAW}" "${DISK_SIZE}" > /dev/null

# ---------------------------------------------------------------------------
# Create data disk with rootfs archive, passphrase and in-VM script
# ---------------------------------------------------------------------------
echo "Packing builder data squashfs..."
DATA_SQUASHFS="${WORK_DIR}/data.squashfs"
DATA_STAGING="${WORK_DIR}/data-staging"
mkdir -p "${DATA_STAGING}"

ARCHIVE_BASENAME="$(basename "${TARBALL}")"
cp "${TARBALL}" "${DATA_STAGING}/${ARCHIVE_BASENAME}"
cp "${SCRIPT_DIR}/vm-builder.sh" "${DATA_STAGING}/vm-builder.sh"
chmod 0755 "${DATA_STAGING}/vm-builder.sh"
cp "${SCRIPT_DIR}/build-qemu-image.sh" "${DATA_STAGING}/build-qemu-image.sh"
chmod 0755 "${DATA_STAGING}/build-qemu-image.sh"
printf '%s\n' "${DISK_SIZE}" > "${DATA_STAGING}/disk-size"

# Stage the gptfdisk package (provides sgdisk) on the data disk so the builder
# VM can install it without network access, even when the rootfs tarball was
# built before gptfdisk was added to the package list. This is best-effort:
# the builder script already falls back to parted when sgdisk is unavailable.
GPTFDISK_DIR="${DATA_STAGING}/extra-packages/gptfdisk"
mkdir -p "${GPTFDISK_DIR}"
GPTFDISK_PKG="${GPTFDISK_DIR}/gptfdisk.pkg.tar.zst"
GPTFDISK_JSON="${GPTFDISK_DIR}/gptfdisk.json"
if curl -fsSLk -o "${GPTFDISK_JSON}" "https://archlinux.org/packages/extra/x86_64/gptfdisk/json/" 2>/dev/null; then
    filename="$(python3 -c "import json; print(json.load(open('${GPTFDISK_JSON}'))['filename'])" 2>/dev/null)" || true
    if [[ -n "${filename}" ]] && curl -fsSLk -o "${GPTFDISK_PKG}" "https://archive.archlinux.org/packages/g/gptfdisk/${filename}" 2>/dev/null; then
        tar --zstd -C "${GPTFDISK_DIR}" -xf "${GPTFDISK_PKG}" 2>/dev/null || true
    else
        echo "Warning: unable to download gptfdisk package; builder will use parted fallback."
    fi
else
    echo "Warning: unable to query gptfdisk package metadata; builder will use parted fallback."
fi

FW_CFG_PASSPHRASE_FILE=""
if [[ "${ENCRYPT}" == true ]]; then
    FW_CFG_PASSPHRASE_FILE="$(mktemp -p /dev/shm regicide-luks-XXXXXX)"
    chmod 0600 "${FW_CFG_PASSPHRASE_FILE}"
    python3 - "${FW_CFG_PASSPHRASE_FILE}" "${PASSPHRASE_FILE}" <<'PYEOF'
import sys
dest, src = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    data = f.read()
if data.endswith(b"\r\n"):
    data = data[:-2]
elif data.endswith(b"\n"):
    data = data[:-1]
with open(dest, "wb") as f:
    f.write(data)
PYEOF
fi

echo "Packing data disk squashfs..."
mksquashfs "${DATA_STAGING}" "${DATA_SQUASHFS}" -comp zstd -Xcompression-level 15 -noappend > /dev/null

# ---------------------------------------------------------------------------
# Extract kernel/initramfs and modules from SquashFS
# ---------------------------------------------------------------------------
echo "Extracting kernel/initramfs from SquashFS..."
unsquashfs -no-xattrs -f -d "${WORK_DIR}/sq" "${SQUASHFS}" boot 2>/dev/null

KERNEL_SRC=$(find "${WORK_DIR}/sq/boot" -maxdepth 1 -name 'vmlinuz*' -type f | sort | head -n1 || true)
INITRD_SRC=$(find "${WORK_DIR}/sq/boot" -maxdepth 1 \( -name 'initramfs-*.img' -o -name 'initrd-*.img' \) -type f | sort | head -n1 || true)

if [[ -z "${KERNEL_SRC}" ]]; then
    echo "Error: no kernel found in SquashFS /boot"
    exit 1
fi
if [[ -z "${INITRD_SRC}" ]]; then
    echo "Error: no initramfs found in SquashFS /boot"
    exit 1
fi

cp "${KERNEL_SRC}" "${KERNEL}"
cp "${INITRD_SRC}" "${INITRD}"

# Extract the modules tree so we can inject missing modules into the initramfs.
echo "Extracting kernel modules from SquashFS..."
unsquashfs -no-xattrs -f -d "${WORK_DIR}/sq" "${SQUASHFS}" usr/lib/modules 2>/dev/null || true

# kmod's modprobe -d <prefix> only searches under lib/modules, so make the
# merged-/usr modules tree reachable from the legacy /lib path as well.
ln -sf usr/lib "${WORK_DIR}/sq/lib" 2>/dev/null || true
ln -sf usr/lib "${WORK_DIR}/sq/lib64" 2>/dev/null || true

KVER=""
for candidate in "${WORK_DIR}/sq/usr/lib/modules/"*; do
    if [[ -d "${candidate}" ]]; then
        KVER="$(basename "${candidate}")"
        break
    fi
done
if [[ -z "${KVER}" ]]; then
    echo "Error: unable to determine kernel version from SquashFS modules tree"
    exit 1
fi
echo "Selected kernel version: ${KVER}"

# ---------------------------------------------------------------------------
# Build custom initramfs overlay
# ---------------------------------------------------------------------------
echo "Building custom initramfs overlay..."
OVERLAY_DIR="${WORK_DIR}/overlay"
mkdir -p "${OVERLAY_DIR}"

# Provide merged-/usr symlinks so module paths resolve through both /lib and /usr/lib.
ln -sf usr/lib "${OVERLAY_DIR}/lib"
ln -sf usr/lib "${OVERLAY_DIR}/lib64"

MODULES_DIR="${OVERLAY_DIR}/usr/lib/modules/${KVER}"
mkdir -p "${MODULES_DIR}/kernel"

# Inject required filesystem/block modules from the Arch rootfs into the
# initramfs.  The mkinitcpio initramfs is systemd-based, so our overlay /init
# must load these itself before mounting the SquashFS rootfs and data disk.
# Modules in the SquashFS are compressed as .ko.zst; resolve the dependency
# closure with modprobe so the actual module paths are used.
BUILTIN_OPTIONAL_MODULES=(
    "nls_cp437"
    "nls_ascii"
    "virtio_blk"
    "virtio_pci"
)

is_builtin() {
    local mod="$1"
    grep -qE "^kernel/.*/${mod}\.ko" "${WORK_DIR}/sq/usr/lib/modules/${KVER}/modules.builtin" 2>/dev/null
}

for mod in squashfs overlay dm_mod dm_crypt fat vfat nls_cp437 nls_ascii virtio_blk virtio_pci virtio_mmio qemu_fw_cfg; do
    if is_builtin "${mod}"; then
        echo "Note: ${mod} is built-in; skipping injection"
        continue
    fi
    deps="$(modprobe -d "${WORK_DIR}/sq" -S "${KVER}" --show-depends "${mod}" 2>/dev/null | awk '{print $NF}' || true)"
    if [[ -z "${deps}" ]]; then
        if [[ " ${BUILTIN_OPTIONAL_MODULES[*]} " =~ " ${mod} " ]]; then
            echo "Note: ${mod}.ko not present for ${KVER}; assuming built-in"
        else
            echo "Warning: unable to resolve dependencies for ${mod}"
        fi
        continue
    fi
    for dep_path in ${deps}; do
        rel_path="$(realpath --relative-to="${WORK_DIR}/sq/lib/modules/${KVER}" "${dep_path}" 2>/dev/null || true)"
        if [[ -z "${rel_path}" || "${rel_path}" == /* || ! -f "${dep_path}" ]]; then
            continue
        fi
        dst="${MODULES_DIR}/${rel_path%.zst}"
        mkdir -p "$(dirname "${dst}")"
        if [[ "${dep_path}" == *.zst ]]; then
            zstd -d -f "${dep_path}" -o "${dst}"
        else
            cp "${dep_path}" "${dst}"
        fi
        chmod 0644 "${dst}"
    done
done

if command -v depmod &> /dev/null; then
    depmod -a -b "${OVERLAY_DIR}" "${KVER}" 2>/dev/null || true
fi

cat > "${OVERLAY_DIR}/init" <<'INITEOF'
#!/bin/sh
# Minimal initramfs init: bring up virtual filesystems, mount the Arch rootfs
# and the data disk, then switch into the rootfs to run the image builder.

mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mkdir -p /dev/shm
mount -t tmpfs -o mode=1777,nodev,nosuid tmpfs /dev/shm
ln -sf /proc/self/fd /dev/fd 2>/dev/null || true
ln -sf /proc/self/fd/0 /dev/stdin 2>/dev/null || true
ln -sf /proc/self/fd/1 /dev/stdout 2>/dev/null || true
ln -sf /proc/self/fd/2 /dev/stderr 2>/dev/null || true


kver=$(ls /usr/lib/modules 2>/dev/null | head -n1 || true)

load_module() {
    local name="$1"
    if [ -d "/sys/module/${name}" ]; then
        return 0
    fi
    if modprobe "${name}" 2>/dev/null; then
        return 0
    fi
    if [ -n "${kver}" ]; then
        local path
        path=$(find "/usr/lib/modules/${kver}" -name "${name}.ko" 2>/dev/null | head -n1 || true)
        if [ -n "${path}" ]; then
            insmod "${path}" 2>/dev/null || true
        fi
    fi
}

for mod in squashfs overlay dm_mod dm_crypt fat vfat nls_cp437 nls_ascii virtio_blk virtio_pci virtio_mmio qemu_fw_cfg; do
    load_module "${mod}"
done

mkdir -p /sysroot /data /lower /overlay-upper

i=0
while [ "$i" -lt 30 ]; do
    if [ -b /dev/vda ] && [ -b /dev/vdb ] && [ -b /dev/vdc ]; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

if [ ! -b /dev/vda ]; then
    echo "Error: target disk /dev/vda not found"
    poweroff -f
fi
if [ ! -b /dev/vdb ]; then
    echo "Error: rootfs disk /dev/vdb not found"
    poweroff -f
fi
if [ ! -b /dev/vdc ]; then
    echo "Error: data disk /dev/vdc not found"
    poweroff -f
fi

mount -t squashfs /dev/vdb /lower || { echo "Failed to mount /dev/vdb"; poweroff -f; }
mount -t tmpfs -o size=4G tmpfs /overlay-upper || { echo "Failed to mount tmpfs for overlay"; poweroff -f; }
mkdir -p /overlay-upper/upper /overlay-upper/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/overlay-upper/upper,workdir=/overlay-upper/work /sysroot || { echo "Failed to mount overlay rootfs"; poweroff -f; }

mount -t squashfs /dev/vdc /data || { echo "Failed to mount /dev/vdc"; poweroff -f; }

mkdir -p /run
if [ -r /sys/firmware/qemu_fw_cfg/by_name/opt/org.regicide/luks/raw ]; then
    cp /sys/firmware/qemu_fw_cfg/by_name/opt/org.regicide/luks/raw /run/regicide-luks-passphrase
    chmod 0600 /run/regicide-luks-passphrase
fi

mkdir -p /sysroot/dev /sysroot/proc /sysroot/sys /sysroot/data /sysroot/run /sysroot/tmp
chmod 1777 /sysroot/tmp
mount --bind /dev /sysroot/dev
mount --bind /proc /sysroot/proc
mount --bind /sys /sysroot/sys
mount --bind /data /sysroot/data
mount --bind /run /sysroot/run
mount --bind /tmp /sysroot/tmp

if ! chroot /sysroot /bin/bash /data/vm-builder.sh; then
    echo "Error: in-VM builder failed"
    poweroff -f
fi

if [ -f /run/regicide-luks-passphrase ]; then
    dd if=/dev/urandom of=/run/regicide-luks-passphrase bs=1 count=$(stat -c '%s' /run/regicide-luks-passphrase) status=none 2>/dev/null || true
    rm -f /run/regicide-luks-passphrase
fi
poweroff -f
INITEOF
chmod +x "${OVERLAY_DIR}/init"

OVERLAY_CPIO="${WORK_DIR}/overlay.cpio"
(
    cd "${OVERLAY_DIR}"
    find . -mindepth 1 -print0 | cpio --null -o -H newc --owner=root:root > "${OVERLAY_CPIO}"
)

CUSTOM_INITRD="${WORK_DIR}/custom-initrd"
MAIN_INITRD="${WORK_DIR}/main-initrd"
MAIN_INITRD_CPIO="${WORK_DIR}/main-initrd.cpio"
INITRD_STAGING="${WORK_DIR}/initrd-staging"

cp "${INITRD}" "${WORK_DIR}/initrd.orig"

# The mkinitcpio initramfs is an early microcode cpio archive followed by a
# compressed main cpio. Appending an uncompressed overlay to the whole file
# confuses the kernel decompressor, so strip the early cpio, merge the overlay
# into the decompressed main archive, and recompress the unified initramfs.
/usr/lib/dracut/skipcpio "${WORK_DIR}/initrd.orig" > "${MAIN_INITRD}"
if zstd -d -f "${MAIN_INITRD}" -o "${MAIN_INITRD_CPIO}" 2>/dev/null; then
    :
elif gzip -d -c "${MAIN_INITRD}" > "${MAIN_INITRD_CPIO}" 2>/dev/null; then
    :
elif xz -d -c "${MAIN_INITRD}" > "${MAIN_INITRD_CPIO}" 2>/dev/null; then
    :
else
    echo "Error: unable to decompress main initramfs."
    exit 1
fi

mkdir -p "${INITRD_STAGING}"
( cd "${INITRD_STAGING}"; cpio -id < "${MAIN_INITRD_CPIO}" 2>/dev/null )
( cd "${INITRD_STAGING}"; cpio -idu < "${OVERLAY_CPIO}" 2>/dev/null )

# Regenerate modules.dep inside the merged initramfs so the injected modules
# can be loaded by modprobe/insmod during early boot.
if command -v depmod &> /dev/null; then
    depmod -a -b "${INITRD_STAGING}" "${KVER}" 2>/dev/null || true
fi

if [[ ! -x "${INITRD_STAGING}/init" ]]; then
    echo "Error: unified initramfs is missing an executable /init"
    ls -la "${INITRD_STAGING}" | head -20
    exit 1
fi

(
    cd "${INITRD_STAGING}"
    find . -mindepth 1 -print0 | cpio --null -o -H newc --owner=root:root > "${WORK_DIR}/merged.cpio"
)
zstd -19 -f "${WORK_DIR}/merged.cpio" -o "${CUSTOM_INITRD}"

# ---------------------------------------------------------------------------
# Boot the VM and run the builder
# ---------------------------------------------------------------------------
echo "Booting KVM builder VM..."
VM_SERIAL_LOG="${WORK_DIR}/builder-vm-serial.log"

QEMU_ARGS=(
    -m 4G
    -smp 4
    -nographic
    -no-reboot
    -nic none
    -kernel "${KERNEL}"
    -initrd "${CUSTOM_INITRD}"
    -drive "file=${TARGET_RAW},format=raw,if=virtio"
    -drive "file=${SQUASHFS},format=raw,if=virtio,readonly=on"
    -drive "file=${DATA_SQUASHFS},format=raw,if=virtio,readonly=on"
)
if [[ "${ENCRYPT}" == true && -n "${FW_CFG_PASSPHRASE_FILE}" ]]; then
    QEMU_ARGS+=(-fw_cfg "name=opt/org.regicide/luks,file=${FW_CFG_PASSPHRASE_FILE}")
fi

timeout 1800 qemu-system-x86_64 -machine type=q35,accel=kvm -enable-kvm -cpu host -append "root=/dev/vdb ro console=ttyS0,115200n8 init=/init" "${QEMU_ARGS[@]}" 2>&1 | tee "${VM_SERIAL_LOG}"

# ---------------------------------------------------------------------------
# Verify the built raw disk
# ---------------------------------------------------------------------------
echo "Verifying built raw disk..."

if grep -E "^(Error:|FATAL ERROR:|Error encountered|Unable to set partition|Could not create partition)" "${VM_SERIAL_LOG}" > /dev/null 2>&1; then
    echo "Error: builder VM reported a fatal error. Serial log:"
    grep -E "^(Error:|FATAL ERROR:|Error encountered|Unable to set partition|Could not create partition)" "${VM_SERIAL_LOG}" || true
    exit 1
fi

if ! grep -q "RegicideOSArch QEMU image build complete" "${VM_SERIAL_LOG}"; then
    echo "Error: builder VM did not report successful completion."
    exit 1
fi

if ! parted -s "${TARGET_RAW}" print > /dev/null 2>&1; then
    echo "Error: built raw disk does not have a valid partition table."
    exit 1
fi

PARTITION_COUNT=$(parted -s "${TARGET_RAW}" print 2>/dev/null | awk '/^ [0-9]+ / {count++} END {print count}')
if [[ -z "${PARTITION_COUNT}" || "${PARTITION_COUNT}" -lt 4 ]]; then
    echo "Error: expected at least 4 partitions, found ${PARTITION_COUNT:-0}."
    exit 1
fi

if [[ "${ENCRYPT}" == true ]]; then
    ROOTS_OFFSET=$(parted -s "${TARGET_RAW}" unit B print 2>/dev/null | awk '/^ 2 / {gsub(/B$/, "", $2); print $2}')
    if [[ -z "${ROOTS_OFFSET}" ]]; then
        echo "Error: could not determine ROOTS partition offset."
        exit 1
    fi
    LUKS_SAMPLE="${WORK_DIR}/luks-sample.bin"
    dd if="${TARGET_RAW}" of="${LUKS_SAMPLE}" bs=1 count=4096 skip="${ROOTS_OFFSET}" status=none
    if ! file "${LUKS_SAMPLE}" | grep -q 'LUKS'; then
        echo "Error: ROOTS partition does not contain a LUKS header."
        exit 1
    fi
    echo "LUKS header verification passed."
fi

# ---------------------------------------------------------------------------
# Convert the built raw image to QCOW2
# ---------------------------------------------------------------------------
echo "Converting target disk to QCOW2..."
qemu-img convert -f raw -O qcow2 "${TARGET_RAW}" "${OUTPUT}"

# ---------------------------------------------------------------------------
# Generate runner script
# ---------------------------------------------------------------------------
RUNNER_PATH="${OUTPUT_DIR}/run-qemu.sh"
cat > "${RUNNER_PATH}" << QEMUEOF
#!/bin/bash
# RegicideOSArch QEMU Runner
# Auto-generated by build-vm-image.sh

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
    -drive file="\${IMAGE_PATH}",format=qcow2,if=virtio \\
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \\
    -device virtio-net-pci,netdev=net0 \\
    -machine type=q35,accel=kvm \\
    -serial file:\${LOG_DIR}/regicide-serial.log \\
    -monitor unix:\${LOG_DIR}/regicide-monitor.sock,server,nowait \\
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
