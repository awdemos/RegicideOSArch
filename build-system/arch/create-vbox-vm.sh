#!/bin/bash
# RegicideOSArch VirtualBox VM creator
# Converts the generated QCOW2 to a VirtualBox VDI and registers/starts a VM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW2_PATH="${SCRIPT_DIR}/output/regicide-arch.qcow2"
VDI_PATH="${SCRIPT_DIR}/output/regicide-arch.vdi"
VM_NAME="RegicideOSArch"

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Creates and starts a VirtualBox VM from the generated RegicideOSArch QCOW2 image.

Options:
  --qcow2 PATH    Path to the source QCOW2 image (default: ${QCOW2_PATH})
  --vdi PATH      Path for the converted VDI output (default: ${VDI_PATH})
  --name NAME     VirtualBox VM name (default: ${VM_NAME})
  --memory MB     RAM in MB (default: 4096)
  --cpus N        Number of vCPUs (default: 2)
  --headless      Start VM in headless mode
  -h|--help       Show this help
EOF
    exit 1
}

MEMORY="4096"
CPUS="2"
HEADLESS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qcow2)
            QCOW2_PATH="$2"
            shift 2
            ;;
        --vdi)
            VDI_PATH="$2"
            shift 2
            ;;
        --name)
            VM_NAME="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --cpus)
            CPUS="$2"
            shift 2
            ;;
        --headless)
            HEADLESS=("--type" "headless")
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
            usage
            ;;
    esac
done

if ! command -v VBoxManage >/dev/null 2>&1; then
    echo "Error: VBoxManage not found. Install VirtualBox first."
    exit 1
fi

if [[ ! -f "${QCOW2_PATH}" ]]; then
    echo "Error: QCOW2 image not found: ${QCOW2_PATH}"
    echo "Build it first with: python build-system/dagger_pipeline.py --qcow2"
    exit 1
fi

QCOW2_PATH="$(realpath -e "${QCOW2_PATH}")"
VDI_PATH="$(realpath -m "${VDI_PATH}")"
VDI_DIR="$(dirname "${VDI_PATH}")"
mkdir -p "${VDI_DIR}"

# Convert QCOW2 to VDI if it does not already exist or is older than the QCOW2.
if [[ ! -f "${VDI_PATH}" || "${QCOW2_PATH}" -nt "${VDI_PATH}" ]]; then
    echo "Converting ${QCOW2_PATH} to ${VDI_PATH} ..."
    if [[ -f "${VDI_PATH}" ]]; then
        rm -f "${VDI_PATH}"
    fi
    qemu-img convert -f qcow2 -O vdi "${QCOW2_PATH}" "${VDI_PATH}"
else
    echo "VDI is up to date: ${VDI_PATH}"
fi

# Remove existing VM with the same name if present.
if VBoxManage list vms | grep -q "\"${VM_NAME}\""; then
    echo "Removing existing VM: ${VM_NAME}"
    VBoxManage unregistervm "${VM_NAME}" --delete >/dev/null 2>&1 || true
fi

# Create the VM.
echo "Creating VirtualBox VM: ${VM_NAME}"
VBoxManage createvm --name "${VM_NAME}" --ostype Linux_64 --register
VBoxManage modifyvm "${VM_NAME}" \
    --memory "${MEMORY}" \
    --cpus "${CPUS}" \
    --vram 128 \
    --graphicscontroller vmsvga \
    --firmware efi64 \
    --nic1 nat \
    --natpf1 "ssh,tcp,,2222,,22" \
    --audio none \
    --usb ohci --mouse usbtablet

# Attach the VDI.
VBoxManage storagectl "${VM_NAME}" --name "SATA Controller" --add sata --controller IntelAhci
VBoxManage storageattach "${VM_NAME}" \
    --storagectl "SATA Controller" \
    --port 0 --device 0 \
    --type hdd \
    --medium "${VDI_PATH}"

echo ""
echo "========================================"
echo "VirtualBox VM created: ${VM_NAME}"
echo "VDI: ${VDI_PATH}"
echo ""
echo "To start with GUI:"
echo "  VBoxManage startvm ${VM_NAME}"
echo ""
echo "To start headless:"
echo "  VBoxManage startvm ${VM_NAME} --type headless"
echo ""
echo "SSH: ssh -p 2222 regicide@localhost"
echo "========================================"
echo ""

echo "Starting VM..."
VBoxManage startvm "${VM_NAME}" "${HEADLESS[@]}"
