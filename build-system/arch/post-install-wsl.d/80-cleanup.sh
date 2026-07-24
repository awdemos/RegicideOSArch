#!/bin/bash
# Ensure critical directories are owned by root regardless of previous chroot uid.
set -euo pipefail

# /opt is a symlink to /usr/opt in this layout; remove any stale one and reset ownership.
rm -rf /opt
mkdir -p /usr/opt
ln -sf /usr/opt /

chown --from=1001:1001 root:root /etc -R || true
chown --from=1001:1001 root:root / || true
chown --from=1001:1001 root:root /boot -R || true
chown --from=1001:1001 root:root /usr -R || true
chown --from=1001:1001 root:root /var -R || true
chown --from=1001:1001 root:root /home -R || true

chown --from=1000:1000 root:root /etc -R || true
chown --from=1000:1000 root:root / || true
chown --from=1000:1000 root:root /boot -R || true
chown --from=1000:1000 root:root /usr -R || true
chown --from=1000:1000 root:root /var -R || true
chown --from=1000:1000 root:root /home -R || true
