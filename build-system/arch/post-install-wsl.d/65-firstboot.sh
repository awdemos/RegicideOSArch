#!/bin/bash
# Prevent systemd-firstboot from prompting interactively on first boot.
set -euo pipefail

systemd-machine-id-setup || true
systemctl mask systemd-firstboot.service || true
