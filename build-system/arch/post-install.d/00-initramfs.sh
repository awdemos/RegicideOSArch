#!/bin/bash
# Configure mkinitcpio for Btrfs + LUKS + systemd boot.
set -euo pipefail

mkdir -p /etc/mkinitcpio.conf.d
rm -f /etc/mkinitcpio.conf.d/99-regicide-luks.conf
cat > /etc/mkinitcpio.conf.d/99-regicide.conf << 'EOF'
MODULES=(btrfs)
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
COMPRESSION="zstd"
EOF
