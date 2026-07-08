#!/bin/bash
# RegicideOSArch post-install orchestrator.
# Runs every numbered script under post-install.d in sorted order.
# Each script owns one domain (initramfs, users, a11y, services, flatpak, ...)
# so changes are localized and reviewable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST_INSTALL_D="${SCRIPT_DIR}/post-install.d"

# Build profiles passed from the Dagger pipeline. They control optional
# domains such as NVIDIA drivers or first-boot app installation.
REGICIDE_ENABLE_NVIDIA="${REGICIDE_ENABLE_NVIDIA:-1}"
REGICIDE_DEFER_FLATPAKS="${REGICIDE_DEFER_FLATPAKS:-0}"

if [[ ! -d "${POST_INSTALL_D}" ]]; then
    echo "ERROR: ${POST_INSTALL_D} not found"
    exit 1
fi

shopt -s nullglob
for script in "${POST_INSTALL_D}"/*.sh; do
    echo "== Running $(basename "${script}") =="
    bash "${script}"
done
shopt -u nullglob

echo "RegicideOSArch post-install complete."
