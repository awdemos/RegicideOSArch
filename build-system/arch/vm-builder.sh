#!/bin/bash
# RegicideOSArch in-VM image builder
# Runs inside a KVM appliance that boots the Arch rootfs. It mounts the data
# disk, locates the rootfs archive and optional LUKS passphrase, then invokes
# build-qemu-image.sh in direct-device mode against /dev/vda.

set -euo pipefail

# Ensure standard Arch paths are available inside the initramfs chroot.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# /data is mounted by the host initramfs overlay as a SquashFS and contains
# the rootfs archive, optional passphrase file, and the in-VM builder script.
DATA_DIR="/data"

TARBALL=""
for ext in .tar.xz .tar.gz .tgz .tar; do
    CANDIDATE="$(find "${DATA_DIR}" -maxdepth 1 -name "*${ext}" -type f | head -n1 || true)"
    if [[ -n "${CANDIDATE}" && -f "${CANDIDATE}" ]]; then
        TARBALL="${CANDIDATE}"
        break
    fi
done
if [[ -z "${TARBALL}" || ! -f "${TARBALL}" ]]; then
    echo "Error: rootfs archive not found on data disk (looked for *.tar.xz, *.tar.gz, *.tar)."
    exit 1
fi

PASSPHRASE_FILE=""
ENCRYPT_FLAG=""
if [[ -f "/run/regicide-luks-passphrase" ]]; then
    PASSPHRASE_FILE="/run/regicide-luks-passphrase"
    ENCRYPT_FLAG="--encrypt"
fi

TARGET="/dev/vda"
OUTPUT="/run/regicide-output/regicide-arch.qcow2"
DISK_SIZE="20G"
if [[ -f "${DATA_DIR}/disk-size" ]]; then
    DISK_SIZE="$(cat "${DATA_DIR}/disk-size")"
fi

mkdir -p /run/regicide-output

# Copy extra packages from the data disk into the chroot so the image builder
# has tools that may not be installed in the base rootfs (e.g. gptfdisk/sgdisk).
for extra_pkg in /data/extra-packages/*; do
    if [[ -d "${extra_pkg}/usr" ]]; then
        cp -a "${extra_pkg}/usr/." /usr/
    fi
done

cp "${SCRIPT_DIR}/build-qemu-image.sh" /run/regicide-output/build-qemu-image.sh
chmod +x /run/regicide-output/build-qemu-image.sh

if [[ -n "${ENCRYPT_FLAG}" ]]; then
    exec /run/regicide-output/build-qemu-image.sh \
        --direct-device "${TARGET}" \
        --no-convert \
        --encrypt \
        --passphrase-file "${PASSPHRASE_FILE}" \
        "${TARBALL}" \
        "${OUTPUT}" \
        "${DISK_SIZE}"
else
    exec /run/regicide-output/build-qemu-image.sh \
        --direct-device "${TARGET}" \
        --no-convert \
        "${TARBALL}" \
        "${OUTPUT}" \
        "${DISK_SIZE}"
fi
