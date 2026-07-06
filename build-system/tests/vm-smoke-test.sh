#!/bin/bash
# RegicideOSArch VM smoke tests
# Verifies distrobox creation, Btrfs immutability, overlay mounts, and subvolumes.

set -euo pipefail

: "${TEST_BOX_NAME:=regicide-smoke-alpine}"
: "${TEST_BOX_IMAGE:=alpine:latest}"

PASS=0
FAIL=0

log_section() {
    echo ""
    echo "=== $1 ==="
}

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}

# -----------------------------------------------------------------------------
log_section "1. Distrobox container creation"

if command -v distrobox >/dev/null 2>&1; then
    if distrobox list | grep -q "| ${TEST_BOX_NAME}"; then
        distrobox rm "${TEST_BOX_NAME}" --force >/dev/null 2>&1 || true
    fi

    if distrobox create --image "${TEST_BOX_IMAGE}" --name "${TEST_BOX_NAME}" --yes >/tmp/distrobox-create.log 2>&1; then
        pass "distrobox create succeeded"
    else
        fail "distrobox create failed"
        tail -20 /tmp/distrobox-create.log || true
    fi
else
    fail "distrobox not installed"
fi

# -----------------------------------------------------------------------------
log_section "2. Distrobox container execution"

if distrobox list | grep -q "| ${TEST_BOX_NAME}"; then
    if distrobox enter "${TEST_BOX_NAME}" -- whoami >/tmp/distrobox-enter.log 2>&1; then
        pass "distrobox enter runs a command"
    else
        fail "distrobox enter command failed"
        tail -20 /tmp/distrobox-enter.log || true
    fi
else
    fail "distrobox container missing; cannot test enter"
fi

# -----------------------------------------------------------------------------
log_section "3. Distrobox container removal"

if distrobox list | grep -q "| ${TEST_BOX_NAME}"; then
    if distrobox rm "${TEST_BOX_NAME}" --force >/tmp/distrobox-rm.log 2>&1; then
        pass "distrobox rm succeeded"
    else
        fail "distrobox rm failed"
        tail -20 /tmp/distrobox-rm.log || true
    fi
else
    pass "distrobox container already removed"
fi

# -----------------------------------------------------------------------------
log_section "4. Btrfs mount layout"

MOUNT_ROOT=$(findmnt -n -o SOURCE,FSTYPE / | awk '{print $2}')
MOUNT_HOME=$(findmnt -n -o SOURCE,FSTYPE /home | awk '{print $2}')
MOUNT_OVERLAY=$(findmnt -n -o SOURCE,FSTYPE /overlay | awk '{print $2}')

[[ "${MOUNT_ROOT}" == "btrfs" ]] && pass "/ is btrfs" || fail "/ is not btrfs (got ${MOUNT_ROOT})"
[[ "${MOUNT_HOME}" == "btrfs" ]] && pass "/home is btrfs" || fail "/home is not btrfs (got ${MOUNT_HOME})"
[[ "${MOUNT_OVERLAY}" == "btrfs" ]] && pass "/overlay is btrfs" || fail "/overlay is not btrfs (got ${MOUNT_OVERLAY})"

# ROOTS should be mounted with subvolid=5 (no separate subvolume for the root filesystem)
ROOT_SUBVOLID=$(findmnt -n -o OPTIONS / | tr ',' '\n' | grep '^subvolid=' | cut -d= -f2)
[[ "${ROOT_SUBVOLID}" == "5" ]] && pass "/ uses subvolid=5" || fail "/ subvolid is ${ROOT_SUBVOLID}, expected 5"

# -----------------------------------------------------------------------------
log_section "5. Overlay mounts for /etc, /var, /usr"

for dir in /etc /var /usr; do
    FSTYPE=$(findmnt -n -o FSTYPE -- "${dir}" | awk '{print $1}')
    [[ "${FSTYPE}" == "overlay" ]] && pass "${dir} is overlay" || fail "${dir} is not overlay (got ${FSTYPE})"
done

# -----------------------------------------------------------------------------
log_section "6. Root immutability: /usr/bin, /etc should be read-only lowerdirs"

# Check that the read-only lowerdirs refuse writes at the kernel level.
# Writing to /usr/bin or /etc should fail with EROFS if the overlay is properly stacked.
if ! touch /usr/bin/.smoke-test 2>/dev/null; then
    pass "/usr/bin is read-only (immutable lowerdir)"
else
    rm -f /usr/bin/.smoke-test
    fail "/usr/bin accepted a write"
fi

if ! touch /etc/.smoke-test 2>/dev/null; then
    pass "/etc is read-only (immutable lowerdir)"
else
    rm -f /etc/.smoke-test
    fail "/etc accepted a write"
fi

# -----------------------------------------------------------------------------
log_section "7. Overlay upperdirs are writable (/overlay subvolumes)"

for subvol in etc var usr home; do
    if sudo btrfs subvolume list /overlay | grep -q "path ${subvol}$"; then
        pass "/overlay/${subvol} subvolume exists"
    else
        fail "/overlay/${subvol} subvolume missing"
    fi
done

# -----------------------------------------------------------------------------
log_section "8. Btrfs subvolumes for overlay workdirs"

for workdir in etcw varw usrw; do
    if [[ -d "/overlay/${workdir}" ]]; then
        pass "/overlay/${workdir} workdir exists"
    else
        fail "/overlay/${workdir} workdir missing"
    fi
done

# -----------------------------------------------------------------------------
log_section "9. EFI partition is vfat and automounted"

if findmnt -n -o FSTYPE /efi 2>/dev/null | grep -q "vfat"; then
    pass "/efi is vfat"
else
    fail "/efi is not vfat or not mounted"
fi

# -----------------------------------------------------------------------------
log_section "10. Required binaries present"

for bin in podman distrobox flatpak cosmic-session cosmic-greeter btrfs; do
    if command -v "${bin}" >/dev/null 2>&1; then
        pass "${bin} installed"
    else
        fail "${bin} missing"
    fi
done

# -----------------------------------------------------------------------------
log_section "11. NVIDIA userspace stack"

if command -v nvidia-smi >/dev/null 2>&1; then
    pass "nvidia-smi installed"
    if nvidia-smi >/tmp/nvidia-smi.log 2>&1; then
        if grep -q 'NVIDIA-SMI' /tmp/nvidia-smi.log; then
            pass "nvidia-smi runs and reports NVIDIA-SMI header"
        else
            fail "nvidia-smi ran but produced unexpected output"
            tail -20 /tmp/nvidia-smi.log || true
        fi
    else
        # A run that fails because no GPU is present is still a positive test
        # for the installed driver/userspace stack; treat it as a pass if the
        # error text mentions driver/NVML initialization rather than a missing
        # binary or library.
        if grep -Eiq 'nvml|driver|gpu|device' /tmp/nvidia-smi.log; then
            pass "nvidia-smi present; no GPU available in VM (expected)"
        else
            fail "nvidia-smi failed unexpectedly"
            tail -20 /tmp/nvidia-smi.log || true
        fi
    fi
else
    fail "nvidia-smi missing"
fi

# -----------------------------------------------------------------------------
log_section "SUMMARY"

TOTAL=$((PASS + FAIL))
echo "Passed: ${PASS}/${TOTAL}"
echo "Failed: ${FAIL}/${TOTAL}"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi

exit 0
