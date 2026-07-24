#!/bin/bash
# RegicideOSArch WSL post-install orchestrator.
# Runs every numbered script under post-install-wsl.d in sorted order.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST_INSTALL_D="${SCRIPT_DIR}/post-install-wsl.d"

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

echo "RegicideOSArch WSL post-install complete."
