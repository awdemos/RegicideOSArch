#!/bin/bash
# WSL-specific configuration: systemd, default user, and WSLg integration.
set -euo pipefail

cat > /etc/wsl.conf <<'EOF'
[boot]
systemd = true

[user]
default = regicide

[interop]
enabled = true
appendWindowsPath = true

[automount]
enabled = true
mountFsTab = false
root = /mnt/
options = "metadata,umask=22,fmask=11"
EOF

# Ensure regicide owns its home after any chroot uid drift.
chown -R regicide:regicide /home/regicide || true
