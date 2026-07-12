#!/bin/bash
# COSMIC desktop configuration for VM use: auto-login, disable screen blanking,
# and keep the display output active over VNC.
set -euo pipefail

# 1. Auto-login regicide directly into COSMIC; do not show the greeter.
mkdir -p /etc/greetd
cat > /etc/greetd/cosmic-greeter.toml <<'EOF'
[terminal]
vt = "1"

[general]
service = "login"

[default_session]
command = "/usr/bin/cosmic-session"
user = "regicide"

[initial_session]
command = "/usr/bin/cosmic-session"
user = "regicide"
EOF

# Ensure cosmic-greeter is the display manager and no getty fights for tty1.
rm -f /etc/systemd/system/getty.target.wants/getty@tty1.service
systemctl enable cosmic-greeter || true

# 2. Disable COSMIC idle blanking / suspend-on-idle.
IDLE_DIR="/home/regicide/.config/cosmic/com.system76.CosmicIdle/v1"
mkdir -p "${IDLE_DIR}"
cat > "${IDLE_DIR}/cosmic-idle" <<'EOF'
(
    screen_off_time: None,
    suspend_on_battery_time: None,
    suspend_on_ac_time: None,
)
EOF
chown -R regicide:regicide "${IDLE_DIR}"

# 3. User-level idle inhibitor fallback in case the config isn't honored.
mkdir -p /etc/systemd/user
cat > /etc/systemd/user/keep-cosmic-awake.service <<'EOF'
[Unit]
Description=Keep COSMIC display awake
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/keep-cosmic-awake
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

cat > /usr/local/bin/keep-cosmic-awake <<'EOF'
#!/bin/bash
set -e
systemd-inhibit --what=idle --who="keep-cosmic-awake" --why="Keep VM display visible" sleep infinity &
INHIBIT_PID=$!
cleanup() { kill "$INHIBIT_PID" 2>/dev/null || true; }
trap cleanup EXIT
while true; do sleep 30; done
EOF
chmod +x /usr/local/bin/keep-cosmic-awake

mkdir -p /home/regicide/.config/systemd/user/default.target.wants
ln -sf /etc/systemd/user/keep-cosmic-awake.service \
    /home/regicide/.config/systemd/user/default.target.wants/keep-cosmic-awake.service
chown -R regicide:regicide /home/regicide/.config/systemd
