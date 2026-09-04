#!/bin/bash
# Stage 7: verify RegicideOSArch build artifacts before producing a VM image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"

TARBALL="${OUTPUT_DIR}/regicide-arch.tar.xz"
SQUASHFS="${OUTPUT_DIR}/regicide-arch.img"
ROOTS_DIR="$(mktemp -d -p /var/tmp -t regicide-arch-verify-XXXXXX)"
trap 'rm -rf "${ROOTS_DIR}"' EXIT

ERRORS=0
error() { echo "  VERIFY FAIL: $1" >&2; ERRORS=$((ERRORS + 1)); }
pass() { echo "  VERIFY PASS: $1"; }

echo "Stage 7: verifying RegicideOSArch artifacts..."

if [[ ! -f "${TARBALL}" ]]; then
    error "tarball missing: ${TARBALL}"
    exit 1
fi
if [[ ! -f "${SQUASHFS}" ]]; then
    error "SquashFS missing: ${SQUASHFS}"
    exit 1
fi

tar -C "${ROOTS_DIR}" -xpJf "${TARBALL}"

# 1. Default user exists.
if grep -q '^regicide:' "${ROOTS_DIR}/etc/passwd"; then
    pass "user regicide exists"
else
    error "user regicide missing"
fi

if [[ -d "${ROOTS_DIR}/home/regicide" ]]; then
    pass "/home/regicide exists"
else
    error "/home/regicide missing"
fi

# 2. Root password is locked.
ROOT_SHADOW="$(awk -F: '/^root:/ {print $2}' "${ROOTS_DIR}/etc/shadow")"
if [[ "${ROOT_SHADOW}" == "!"* || -z "${ROOT_SHADOW}" ]]; then
    pass "root password locked"
else
    error "root password is set"
fi

# 3. Sudoers drop-in.
if [[ -f "${ROOTS_DIR}/etc/sudoers.d/10-regicide-wheel" ]]; then
    pass "sudoers drop-in exists"
else
    error "sudoers drop-in missing"
fi

# 3a. Ownership metadata (ground truth from tarball, works unprivileged).
UNPRIVILEGED=0
OWNER_DUMP=""
if [[ "$(id -u)" -ne 0 ]]; then
    UNPRIVILEGED=1
    OWNER_DUMP="$(mktemp -p /var/tmp -t regicide-arch-owners-XXXXXX)"
    trap 'rm -f "${OWNER_DUMP}"' EXIT
    tar -tvf "${TARBALL}" | awk 'NF>=2 {print $0}' > "${OWNER_DUMP}"
fi

rec_owner() {
    local p="${1#.}"  # strip leading . from tarball member path
    if [[ "${UNPRIVILEGED}" -eq 1 ]]; then
        awk -v member="${p#/}" '
            {
                # tar -tvf format: perms owner/group size date ... path
                # Find the last field as the path.
                path = $NF
                if (path == member || path == "./"member) {
                    split($2, parts, "/"); print parts[1]  # owner before /
                }
            }
        ' "${OWNER_DUMP}"
    else
        stat -c '%U' "/${p#/}"
    fi
}

# 3b. Ownership checks.
for owner_check in     "/home/regicide regicide"     "/etc/hosts regicide"     "/etc/fstab regicide"     "/etc/sudoers.d root"; do
    set -- ${owner_check}
    path="${1}"
    expected="${2}"
    actual="$(rec_owner "${path}")"
    if [[ "${actual}" == "${expected}" ]]; then
        pass "${path} owned by ${expected}"
    else
        error "${path} owner '${actual}', expected '${expected}'"
    fi
done

# 4. COSMIC session binary.
if [[ -x "${ROOTS_DIR}/usr/bin/cosmic-session" ]]; then
    pass "cosmic-session present"
else
    error "cosmic-session missing"
fi

# 5. Critical binaries.
for bin in flatpak distrobox podman btrfs cryptsetup; do
    if [[ -x "${ROOTS_DIR}/usr/bin/${bin}" ]]; then
        pass "binary ${bin} present"
    else
        error "binary ${bin} missing"
    fi
done

# 6. Boot files.
if [[ -f "${ROOTS_DIR}/boot/vmlinuz-linux" ]]; then
    pass "kernel present"
else
    error "kernel missing"
fi
if [[ -f "${ROOTS_DIR}/boot/initramfs-linux.img" ]]; then
    pass "initramfs present"
else
    error "initramfs missing"
fi

# 7. Btrfs overlay mount units.
for unit in etc.mount var.mount usr.mount; do
    if [[ -f "${ROOTS_DIR}/etc/systemd/system/${unit}" ]]; then
        pass "${unit} present"
    else
        error "${unit} missing"
    fi
done

# 8. No pre-baked SSH host keys.
BAKED_KEY=0
for key in ssh_host_rsa_key ssh_host_ecdsa_key ssh_host_ed25519_key; do
    if [[ -f "${ROOTS_DIR}/etc/ssh/${key}" ]]; then
        BAKED_KEY=1
        error "pre-baked SSH host key ${key} must not be in image"
    fi
done
if [[ ${BAKED_KEY} -eq 0 ]]; then
    pass "no pre-baked SSH host keys"
fi

# 9. mkinitcpio LUKS hooks present when cryptsetup is installed.
if [[ -x "${ROOTS_DIR}/usr/bin/cryptsetup" ]]; then
    if [[ -f "${ROOTS_DIR}/etc/mkinitcpio.conf" ]] && grep -qE '^(HOOKS=.*\b(sd-encrypt|encrypt)\b|HOOKS=.*\bkeyboard\b)' "${ROOTS_DIR}/etc/mkinitcpio.conf"; then
        pass "mkinitcpio LUKS hooks present"
    else
        error "mkinitcpio LUKS hooks missing"
    fi
fi

if [[ ${ERRORS} -eq 0 ]]; then
    echo "Stage 7 verification passed."
    exit 0
else
    echo "Stage 7 verification failed with ${ERRORS} error(s)." >&2
    exit 1
fi
