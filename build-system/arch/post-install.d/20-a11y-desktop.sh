#!/bin/bash
# Accessibility and desktop defaults.
set -euo pipefail

# Active window hint off, screen reader muted, UI event sounds off.
mkdir -p /home/regicide/.config/cosmic/com.system76.CosmicComp/v1
printf 'false' > /home/regicide/.config/cosmic/com.system76.CosmicComp/v1/active_hint
chown -R regicide:regicide /home/regicide/.config

# Add the Minimon GPU/system monitor applet to the top-panel right wing
# by default. The applet is identified by its desktop file id.
mkdir -p /home/regicide/.config/cosmic/com.system76.CosmicPanel.Panel/v1
cat > /home/regicide/.config/cosmic/com.system76.CosmicPanel.Panel/v1/plugins_wings <<'PANELEOF'
Some(([
    "com.system76.CosmicPanelWorkspacesButton",
    "com.system76.CosmicPanelAppButton"
], [
    "com.system76.CosmicAppletInputSources",
    "com.system76.CosmicAppletA11y",
    "com.system76.CosmicAppletStatusArea",
    "io.github.cosmic_utils.minimon-applet",
    "com.system76.CosmicAppletTiling",
    "com.system76.CosmicAppletAudio",
    "com.system76.CosmicAppletBluetooth",
    "com.system76.CosmicAppletNetwork",
    "com.system76.CosmicAppletBattery",
    "com.system76.CosmicAppletNotifications",
    "com.system76.CosmicAppletPower"
]))
PANELEOF
chown -R regicide:regicide /home/regicide/.config

# Lock GNOME accessibility / sound defaults for the live session.
gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled false || true
gsettings set org.gnome.desktop.sound event-sounds false || true
