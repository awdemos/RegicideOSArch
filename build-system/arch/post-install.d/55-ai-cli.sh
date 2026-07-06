#!/bin/bash
# OpenCode AI CLI.
set -euo pipefail

pacman -S --noconfirm nodejs npm || true
npm install -g opencode-ai || true
