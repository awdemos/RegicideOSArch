#!/bin/bash
# Install fastfetch and the RegicideOS crown logo as the default user's logo.
set -euo pipefail

pacman -S --needed --noconfirm fastfetch

install -Dm644 /dev/stdin /usr/share/fastfetch/logos/regicideos.txt <<'LOGOEOF'
             .:.
          .:  |  :.
     .:    \  |  /    :.
    o========\|/========o
    |   _    |    _    |
    |  (_)   |   (_)   |
    |________|_________|
  /                        \
 |  .--------------------.  |
 | /                      \ |
 ||   R E G I C I D E O S  ||
 | \                      / |
 |  '--------------------'  |
  \                        /
   '----------------------'
LOGOEOF

# Make the crown the default logo for the default user.
REGICIDE_HOME="/home/regicide"
if [[ -d "${REGICIDE_HOME}" ]]; then
    mkdir -p "${REGICIDE_HOME}/.config/fastfetch"
    cat > "${REGICIDE_HOME}/.config/fastfetch/config.jsonc" <<'CFGEOF'
{
  "logo": {
    "source": "/usr/share/fastfetch/logos/regicideos.txt"
  }
}
CFGEOF
    chown -R 1000:1000 "${REGICIDE_HOME}/.config" || true
fi

echo "fastfetch installed with RegicideOS crown logo"
