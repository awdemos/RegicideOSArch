#!/bin/bash
# Container tooling and rootless Podman permissions.
set -euo pipefail

chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap || true
