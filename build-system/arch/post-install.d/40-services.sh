#!/bin/bash
# Enable system services and generate SSH host keys.
set -euo pipefail

systemctl enable NetworkManager || true
systemctl enable cups || true
systemctl enable systemd-timesyncd || true
systemctl enable cosmic-greeter || true
systemctl enable qemu-guest-agent || true
systemctl enable spice-vdagentd || true
systemctl enable sshd || true

# Ensure SSH host keys exist before first boot.
ssh-keygen -A || true

systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service || true

systemctl enable regicide-rollback-apply.service || true
