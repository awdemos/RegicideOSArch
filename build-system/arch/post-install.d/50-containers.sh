#!/bin/bash
# Container tooling and rootless Podman permissions.
set -euo pipefail

pacman -S --noconfirm podman distrobox || true
chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap || true
