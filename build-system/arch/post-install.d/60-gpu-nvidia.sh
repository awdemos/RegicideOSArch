#!/bin/bash
# NVIDIA open-source kernel driver and container toolkit.
set -euo pipefail

if [[ "${REGICIDE_ENABLE_NVIDIA:-1}" != "1" ]]; then
    echo "NVIDIA stack disabled by REGICIDE_ENABLE_NVIDIA; skipping"
    exit 0
fi

pacman -S --noconfirm linux-headers nvidia-open-dkms nvidia-utils egl-wayland || true
pacman -S --noconfirm nvidia-container-toolkit || true
