#!/bin/bash
# Users, sudoers, and recovery account setup.
set -euo pipefail

# Create the primary regicide user on the live system.
useradd -m -u 1000 -G wheel,audio,video,input,storage,network,flatpak -s /bin/bash regicide || true
echo "regicide:regicide" | chpasswd

# Leave root password unset; privileged access is via regicide + sudo.
passwd -d root || true

mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/99-wheel << 'EOF'
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF
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
