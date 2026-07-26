#!/bin/bash
# Install the regicide-workforce AI platform (BI layer + workforce layer)
# into the rootfs. Mirrors 25-regicide-update.sh: pip install into a
# dedicated prefix, console scripts symlinked into /usr/bin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SRC_DIR:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"

pacman -S --needed --noconfirm --disable-download-timeout python-pip || true

# NOTE: do not pre-create bin/ — pip --target skips installing console
# scripts into a directory that already exists.
install -d /usr/lib/regicide-workforce

# Copy source tree and install the package into /usr/lib/regicide-workforce.
install -d /tmp/regicide_workforce_src
cp -r "${REPO_ROOT}/ai-workforce/src" /tmp/regicide_workforce_src/
cp "${REPO_ROOT}/ai-workforce/pyproject.toml" /tmp/regicide_workforce_src/
(
    cd /tmp/regicide_workforce_src
    python3 -m pip install . --target /usr/lib/regicide-workforce --no-deps --quiet
)

for cmd in regicide-bi regicide-workforce; do
    if [[ ! -e "/usr/bin/${cmd}" ]]; then
        ln -sf "/usr/lib/regicide-workforce/bin/${cmd}" "/usr/bin/${cmd}"
    fi
done

PY_VERSION="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PY_SITE="/usr/lib/python${PY_VERSION}/site-packages"
if [[ ! -e "${PY_SITE}/regicide_workforce" ]]; then
    install -d "${PY_SITE}" 2>/dev/null || true
    ln -sf /usr/lib/regicide-workforce/regicide_workforce "${PY_SITE}/regicide_workforce" 2>/dev/null || true
fi

# Example workflows for first-time users.
install -d /usr/share/regicide-workforce/examples
install -m644 "${REPO_ROOT}"/ai-workforce/examples/*.json \
    /usr/share/regicide-workforce/examples/ 2>/dev/null || true
