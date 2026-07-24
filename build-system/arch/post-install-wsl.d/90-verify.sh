#!/bin/bash
# Post-install verification checks for the RegicideOSArch WSL rootfs.
set -euo pipefail

ERRORS=0

error() {
    echo "VERIFY ERROR: $1" >&2
    ERRORS=$((ERRORS + 1))
}

# 1. WSL configuration present.
if [[ ! -f /etc/wsl.conf ]]; then
    error "/etc/wsl.conf missing"
else
    if ! grep -q '^systemd = true' /etc/wsl.conf; then
        error "systemd is not enabled in /etc/wsl.conf"
    fi
    if ! grep -q '^default = regicide' /etc/wsl.conf; then
        error "default WSL user is not regicide"
    fi
fi

# 2. regicide user exists and home config files are present.
if ! id regicide &>/dev/null; then
    error "regicide user does not exist"
fi

# 3. COSMIC session binary present.
if [[ ! -x /usr/bin/cosmic-session ]]; then
    error "/usr/bin/cosmic-session missing or not executable"
fi

# 4. Container tooling.
if ! command -v podman >/dev/null 2>&1; then
    error "podman is not installed"
fi
if ! command -v distrobox >/dev/null 2>&1; then
    error "distrobox is not installed"
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo "VERIFY FAILED: ${ERRORS} error(s)" >&2
    exit 1
fi

echo "WSL post-install verification passed."
