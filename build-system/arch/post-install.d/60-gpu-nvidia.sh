#!/bin/bash
# NVIDIA open-source kernel driver and container toolkit.
set -euo pipefail

pacman -S --noconfirm linux-headers nvidia-open-dkms nvidia-utils egl-wayland || true
pacman -S --noconfirm nvidia-container-toolkit || true
