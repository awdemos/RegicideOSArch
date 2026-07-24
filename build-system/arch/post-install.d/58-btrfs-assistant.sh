#!/bin/bash
# Build and install Btrfs Assistant from the AUR.
# makepkg refuses to run as root, so build as an unprivileged user.
set -euo pipefail

pacman -S --needed --noconfirm git

BUILD_USER=btrfsbuild
useradd -m "${BUILD_USER}"
echo "${BUILD_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/99-${BUILD_USER}"
chmod 0440 "/etc/sudoers.d/99-${BUILD_USER}"

su - "${BUILD_USER}" -c '
    set -euo pipefail
    git clone --depth 1 https://aur.archlinux.org/btrfs-assistant.git /tmp/btrfs-assistant
    cd /tmp/btrfs-assistant
    makepkg -sri --noconfirm
'

userdel -r "${BUILD_USER}" 2>/dev/null || true
rm -f "/etc/sudoers.d/99-${BUILD_USER}"
rm -rf /tmp/btrfs-assistant
