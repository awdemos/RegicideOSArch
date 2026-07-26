#!/bin/bash
# Post-install configuration for the headless UltraWork workspace container.
# This is run inside the Dockerfile build and is intentionally minimal:
# no desktop, no kernel, no initramfs, no GRUB.

set -euo pipefail

# Create the ultrawork runtime user.
useradd -m -s /bin/bash -u 1000 uwuser || true

# Allow passwordless sudo for podman/distrobox only.
mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/uwuser <<'EOF'
uwuser ALL=(ALL) NOPASSWD: /usr/bin/podman, /usr/bin/distrobox
EOF
chmod 0440 /etc/sudoers.d/uwuser

# SSH: allow public-key auth only.
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config

# Ensure host keys directory exists (keys are persisted via volume at runtime).
mkdir -p /data/etc/ssh

# Install opencode-ai globally so the agent is available system-wide.
npm install -g --allow-scripts=opencode-ai opencode-ai@latest || true

# Clean pacman cache to keep image size down.
rm -rf /var/cache/pacman/pkg/*

# Create runtime directories.
mkdir -p /opt/ultrawork/sbin /opt/ultrawork/etc /opt/ultrawork/var

# Mark the build as complete.
touch /opt/ultrawork/.built
