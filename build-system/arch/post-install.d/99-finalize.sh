#!/bin/bash
# Finalize initramfs generation after all package installs and config.
set -euo pipefail

mkinitcpio -P
