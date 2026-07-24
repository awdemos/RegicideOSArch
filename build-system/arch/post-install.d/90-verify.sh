#!/bin/bash
# Post-install verification checks for the RegicideOSArch VM image.
set -euo pipefail

ERRORS=0

error() {
    echo "VERIFY ERROR: $1" >&2
    ERRORS=$((ERRORS + 1))
}

# 1. Greetd auto-login configuration.
if [[ ! -f /etc/greetd/cosmic-greeter.toml ]]; then
    error "/etc/greetd/cosmic-greeter.toml missing"
else
    if ! grep -q 'command = "/usr/bin/cosmic-session"' /etc/greetd/cosmic-greeter.toml; then
        error "greetd is not configured to auto-start cosmic-session"
    fi
    if ! grep -q 'user = "regicide"' /etc/greetd/cosmic-greeter.toml; then
        error "greetd auto-login user is not regicide"
    fi
fi

# 2. No getty on tty1 fighting the greeter.
if [[ -L /etc/systemd/system/getty.target.wants/getty@tty1.service ]]; then
    error "getty@tty1.service is still enabled and will conflict with greetd"
fi

# 3. COSMIC session binary present.
if [[ ! -x /usr/bin/cosmic-session ]]; then
    error "/usr/bin/cosmic-session missing or not executable"
fi

# 4. Idle blanking disabled for regicide.
IDLE_CONF="/home/regicide/.config/cosmic/com.system76.CosmicIdle/v1/cosmic-idle"
if [[ ! -f "${IDLE_CONF}" ]]; then
    error "CosmicIdle config missing at ${IDLE_CONF}"
else
    if ! grep -q 'screen_off_time: None' "${IDLE_CONF}"; then
        error "screen_off_time is not disabled in CosmicIdle config"
    fi
fi

# 5. Keep-awake fallback service present and enabled for regicide.
if [[ ! -f /etc/systemd/user/keep-cosmic-awake.service ]]; then
    error "keep-cosmic-awake.service missing"
fi
if [[ ! -L /home/regicide/.config/systemd/user/default.target.wants/keep-cosmic-awake.service ]]; then
    error "keep-cosmic-awake.service is not enabled for regicide"
fi

# 6. regicide user exists and home config files are present.
if ! id regicide &>/dev/null; then
    error "regicide user does not exist"
else
    if [[ ! -d /home/regicide/.config/cosmic/com.system76.CosmicIdle/v1 ]]; then
        error "regicide CosmicIdle config directory missing"
    fi
fi

# 7. NVIDIA open drivers (when requested).
REGICIDE_ENABLE_NVIDIA="${REGICIDE_ENABLE_NVIDIA:-1}"
if [[ "${REGICIDE_ENABLE_NVIDIA}" == "1" ]]; then
    if ! pacman -Q nvidia-open-dkms &>/dev/null && ! pacman -Q nvidia-open &>/dev/null; then
        error "NVIDIA open driver package (nvidia-open-dkms or nvidia-open) is not installed"
    fi
    if ! pacman -Q nvidia-utils &>/dev/null; then
        error "nvidia-utils is not installed"
    fi
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo "VERIFY FAILED: ${ERRORS} error(s)" >&2
    exit 1
fi

echo "Post-install verification passed."
