#!/bin/bash
# Flatpak remote, app installs, and Rio launcher fix.
set -euo pipefail

rm -f /boot/*.old

if ! command -v flatpak >/dev/null 2>&1; then
    echo "WARNING: flatpak not installed; skipping Flatpak apps"
    exit 0
fi

flatpak remote-add --system flathub https://flathub.org/repo/flathub.flatpakrepo || true

HOST_FLATPAKS=(
    com.protonvpn.www
    com.rioterm.Rio
    dev.zed.Zed
    io.github.dvlv.boxbuddyrs
    io.github.ungoogled_software.ungoogled_chromium
    org.gnome.SoundRecorder
    org.virt_manager.virt-manager
)
for app in "${HOST_FLATPAKS[@]}"; do
    flatpak install --system --noninteractive --assumeyes flathub "$app" || true
done

# Rio (com.rioterm.Rio) fails to start under COSMIC when launched from the
# app grid because it cannot determine a controlling TTY. Flatpak also strips
# WAYLAND_DISPLAY from the launcher environment, so we export it explicitly
# and use the `script` utility inside the sandbox to allocate a PTY.
mkdir -p /var/lib/flatpak/overrides
cat > /var/lib/flatpak/overrides/com.rioterm.Rio <<'EOF_OVERRIDE'
[Environment]
WAYLAND_DISPLAY=wayland-1
XDG_RUNTIME_DIR=/run/user/1000
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
EOF_OVERRIDE

cat > /usr/share/applications/com.rioterm.Rio.desktop <<'EOF_DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Rio
GenericName=Terminal
Comment=A hardware-accelerated GPU terminal emulator powered by WebGPU
Exec=env WAYLAND_DISPLAY=wayland-1 flatpak run --command=script com.rioterm.Rio -q -c rio /dev/null
Icon=com.rioterm.Rio
Terminal=false
Categories=System;TerminalEmulator;
StartupWMClass=Rio
Actions=New;
X-Flatpak=com.rioterm.Rio

[Desktop Action New]
Name=New Terminal
Exec=env WAYLAND_DISPLAY=wayland-1 flatpak run --command=script com.rioterm.Rio -q -c rio /dev/null
EOF_DESKTOP

# Override the Flatpak-exported desktop entry so the app grid uses the same launch command.
install -Dm644 /usr/share/applications/com.rioterm.Rio.desktop /var/lib/flatpak/exports/share/applications/com.rioterm.Rio.desktop || true

update-desktop-database /usr/share/applications || true
update-desktop-database /var/lib/flatpak/exports/share/applications || true
