#!/bin/bash
# Flatpak remote, app installs, and Rio launcher fix.
set -euo pipefail

rm -f /boot/*.old

if ! command -v flatpak >/dev/null 2>&1; then
    echo "WARNING: flatpak not installed; skipping Flatpak apps"
    exit 0
fi

flatpak remote-add --system flathub https://flathub.org/repo/flathub.flatpakrepo || true
# COSMIC applets such as Minimon are published in the cosmic Flatpak repo.
flatpak remote-add --system --if-not-exists cosmic https://apt.pop-os.org/cosmic/cosmic.flatpakrepo || true

# Rio is the only Flatpak app required for a usable desktop out of the box.
# The rest are heavy and are installed on first boot unless deferral is disabled.
ESSENTIAL_FLATPAKS=(
    com.rioterm.Rio
    io.github.ungoogled_software.ungoogled_chromium
)
DEFERRED_FLATPAKS=(
    com.protonvpn.www
    io.github.dvlv.boxbuddyrs
    org.gnome.SoundRecorder
    org.virt_manager.virt-manager
)

mkdir -p /var/log/regicide
FLATPAK_LOG="/var/log/regicide/flatpak-essential.log"
: > "${FLATPAK_LOG}"
for app in "${ESSENTIAL_FLATPAKS[@]}"; do
    echo "Installing essential Flatpak: ${app}" | tee -a "${FLATPAK_LOG}"
    if ! flatpak install --system --noninteractive --assumeyes flathub "${app}" >>"${FLATPAK_LOG}" 2>&1; then
        echo "ERROR: essential Flatpak install failed: ${app}" | tee -a "${FLATPAK_LOG}"
        exit 1
    fi
done

# Minimon COSMIC applet is distributed from the cosmic Flatpak repo, not Flathub.
echo "Installing essential Flatpak: io.github.cosmic_utils.minimon-applet (from cosmic repo)" | tee -a "${FLATPAK_LOG}"
if ! flatpak install --system --noninteractive --assumeyes cosmic io.github.cosmic_utils.minimon-applet >>"${FLATPAK_LOG}" 2>&1; then
    echo "ERROR: essential Flatpak install failed: io.github.cosmic_utils.minimon-applet" | tee -a "${FLATPAK_LOG}"
    exit 1
fi

if [[ "${REGICIDE_DEFER_FLATPAKS:-1}" == "1" ]]; then
    echo "Deferring heavy Flatpak apps to first-boot service"
    mkdir -p /usr/lib/regicide /var/lib/regicide
    cat > /usr/lib/regicide/install-deferred-flatpaks.sh <<'EOF_DEFER'
#!/bin/bash
set -euo pipefail
flatpak remote-add --system flathub https://flathub.org/repo/flathub.flatpakrepo || true
# COSMIC applets such as Minimon are published in the cosmic Flatpak repo.
flatpak remote-add --system --if-not-exists cosmic https://apt.pop-os.org/cosmic/cosmic.flatpakrepo || true
for app in \
    com.protonvpn.www \
    io.github.dvlv.boxbuddyrs \
    org.gnome.SoundRecorder \
    org.virt_manager.virt-manager; do
    flatpak install --system --noninteractive --assumeyes flathub "$app" || true
done
EOF_DEFER
    chmod +x /usr/lib/regicide/install-deferred-flatpaks.sh

    cat > /etc/systemd/system/regicide-deferred-flatpaks.service <<'EOF_SERVICE'
[Unit]
Description=Install deferred Flatpak applications on first boot
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/regicide/deferred-flatpaks.done

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/regicide/install-deferred-flatpaks.sh
ExecStartPost=/usr/bin/touch /var/lib/regicide/deferred-flatpaks.done

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl enable regicide-deferred-flatpaks.service || true
else
    for app in "${DEFERRED_FLATPAKS[@]}"; do
        flatpak install --system --noninteractive --assumeyes flathub "$app" || true
    done
fi

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
