#!/bin/bash
# Install the regicide-update suite into the rootfs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SRC_DIR:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"

pacman -S --needed --noconfirm --disable-download-timeout python-pip || true

# NOTE: do not pre-create bin/ — pip --target skips installing console
# scripts into a directory that already exists.
install -d /usr/lib/regicide-update

# Copy source tree and install the package into /usr/lib/regicide-update.
install -d /tmp/regicide_update_src
cp -r "${REPO_ROOT}/src" /tmp/regicide_update_src/
cp "${REPO_ROOT}/pyproject.toml" /tmp/regicide_update_src/
(
    cd /tmp/regicide_update_src
    python3 -m pip install . --target /usr/lib/regicide-update --no-deps --quiet
)

for cmd in regicide-update regicide-rollback regicide-image regicide-boot-revert; do
    if [[ ! -e "/usr/bin/${cmd}" ]]; then
        ln -sf "/usr/lib/regicide-update/bin/${cmd}" "/usr/bin/${cmd}"
    fi
done

PY_VERSION="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PY_SITE="/usr/lib/python${PY_VERSION}/site-packages"
if [[ ! -e "${PY_SITE}/regicide_update" ]]; then
    install -d "${PY_SITE}" 2>/dev/null || true
    ln -sf /usr/lib/regicide-update/regicide_update "${PY_SITE}/regicide_update" 2>/dev/null || true
fi

# Install the boot-time revert service.
install -Dm644 "${REPO_ROOT}/data/regicide-rollback-apply.service" \
    /etc/systemd/system/regicide-rollback-apply.service

# Seed overlay helper used by regicide-image after a tarball install.
install -Dm755 "${REPO_ROOT}/build-system/arch/seed-overlays.sh" \
    /usr/lib/regicide-update/seed-overlays.sh || true
