#!/bin/bash
# Locale configuration.
set -euo pipefail

cat > /etc/locale.gen << 'EOF'
en_US.UTF-8 UTF-8
EOF
locale-gen
