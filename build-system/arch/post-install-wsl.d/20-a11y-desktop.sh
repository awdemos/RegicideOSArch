#!/bin/bash
# Accessibility and desktop defaults.
set -euo pipefail

# Active window hint off, screen reader muted, UI event sounds off.
mkdir -p /home/regicide/.config/cosmic/com.system76.CosmicComp/v1
printf 'false' > /home/regicide/.config/cosmic/com.system76.CosmicComp/v1/active_hint
chown -R regicide:regicide /home/regicide/.config

# Lock GNOME accessibility / sound defaults for the live session.
gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled false || true
gsettings set org.gnome.desktop.sound event-sounds false || true
