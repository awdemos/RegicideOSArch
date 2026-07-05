#!/bin/bash
# RegicideOSArch post-install configuration
# Runs inside the arch-chroot after base packages and COSMIC are installed.

set -euo pipefail

mkdir -p /etc/mkinitcpio.conf.d
cat > /etc/mkinitcpio.conf.d/99-regicide.conf << 'EOF'
MODULES=(btrfs)
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
COMPRESSION="zstd"
EOF
rm -f /etc/mkinitcpio.conf.d/99-regicide-luks.conf

echo "root:regicide" | chpasswd

rm -rf /opt
mkdir -p /usr/opt
ln -sf /usr/opt /

# Create the primary regicide user on the live system.
useradd -m -u 1000 -G wheel,audio,video,input,storage,network,flatpak -s /bin/bash regicide || true
echo "regicide:regicide" | chpasswd
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99-wheel
chmod 0440 /etc/sudoers.d/99-wheel

mkdir -p /.recovery/etc /.recovery/home/recovery

cp /etc/passwd /.recovery/etc/passwd
cp /etc/shadow /.recovery/etc/shadow

# Recovery account for maintenance access.
echo "recovery:x:1001:1001::/home/recovery:/bin/bash" >> /.recovery/etc/passwd
echo 'recovery:$6$ovJXS/P4rKaURNaD$IUmaP2JW5uiJgrFVr31bEMb6kEF.ARL.x23m.qvyJ3.oRRbJ1qQ/pU5R2VocEzunYqSGF/YvLFGqF5gn0BQY90:19574::::::' >> /.recovery/etc/shadow

sed 's/wheel:x:10:root/wheel:x:10:root,regicide,recovery/' /etc/group > /.recovery/etc/group
echo "recovery:x:1001:" >> /.recovery/etc/group

chown 1000:1000 -R /home/regicide || true
chown 1001:1001 -R /.recovery/home/recovery

# COSMIC defaults: active window hint off, screen reader muted, UI event sounds off.
mkdir -p /home/regicide/.config/cosmic/com.system76.CosmicComp/v1
printf 'false' > /home/regicide/.config/cosmic/com.system76.CosmicComp/v1/active_hint
# Lock GNOME accessibility / sound defaults for the live session.
gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled false || true
gsettings set org.gnome.desktop.sound event-sounds false || true

cat > /etc/locale.gen << 'EOF'
en_US.UTF-8 UTF-8
EOF
locale-gen

systemctl enable NetworkManager || true
systemctl enable cups || true
systemctl enable systemd-timesyncd || true
systemctl enable cosmic-greeter || true
systemctl enable lvm2-monitor || true
systemctl enable qemu-guest-agent || true
systemctl enable spice-vdagentd || true
systemctl enable sshd || true
# Ensure SSH host keys exist before first boot.
ssh-keygen -A || true

systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service

# Install container tooling and fix rootless Podman permissions for distrobox.
pacman -S --noconfirm podman distrobox || true
chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap || true

# Install OpenCode AI CLI globally so the image ships with an AI assistant.
pacman -S --noconfirm nodejs npm || true
npm install -g opencode-ai || true

# Install NVIDIA open-source kernel driver and userspace stack.
pacman -S --noconfirm linux-headers nvidia-open-dkms nvidia-utils egl-wayland || true
# NVIDIA Container Toolkit lets rootless/runtimes use the GPU in containers.
pacman -S --noconfirm nvidia-container-toolkit || true

# Prevent systemd-firstboot from prompting interactively on first boot.
# An empty /etc/machine-id causes systemd to consider the system unconfigured.
systemd-machine-id-setup || true
systemctl mask systemd-firstboot.service || true

rm -f /boot/*.old

if command -v flatpak >/dev/null 2>&1; then
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
install -Dm644 /usr/share/applications/com.rioterm.Rio.desktop /var/lib/flatpak/exports/share/applications/com.rioterm.Rio.desktop

update-desktop-database /usr/share/applications || true
update-desktop-database /var/lib/flatpak/exports/share/applications || true

mkinitcpio -P

chown --from=1001:1001 root:root /etc -R || true
chown --from=1001:1001 root:root / || true
chown --from=1001:1001 root:root /boot -R || true
chown --from=1001:1001 root:root /overlay -R || true
chown --from=1001:1001 root:root /roots -R || true
chown --from=1001:1001 root:root /usr -R || true
chown --from=1001:1001 root:root /var -R || true
chown --from=1001:1001 root:root /home -R || true

chown --from=1000:1000 root:root /etc -R || true
chown --from=1000:1000 root:root / || true
chown --from=1000:1000 root:root /boot -R || true
chown --from=1000:1000 root:root /overlay -R || true
chown --from=1000:1000 root:root /roots -R || true
chown --from=1000:1000 root:root /usr -R || true
chown --from=1000:1000 root:root /var -R || true
chown --from=1000:1000 root:root /home -R || true
