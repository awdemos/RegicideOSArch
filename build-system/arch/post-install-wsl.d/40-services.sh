#!/bin/bash
# Enable system services for WSL.
set -euo pipefail

systemctl enable NetworkManager || true
systemctl enable cups || true
systemctl enable systemd-timesyncd || true
systemctl enable sshd || true

# Ensure SSH host keys exist before first boot.
ssh-keygen -A || true

systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service || true
