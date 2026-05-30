#!/usr/bin/env bash
# Decouple cloak-psk-installer from cloak-rosenpass and (re)start it.
#
# cloak-psk-installer.service has `PartOf=cloak-rosenpass.service`, so moving
# cloak-rosenpass aside during the cloak-rpd migration STOPPED the installer.
# Without it, cloak-rpd's derived PSKs are written to /run/rosenpass/psk-* but
# never installed onto the wg0 peers — so WireGuard handshakes have no valid PSK
# and NO DATA FLOWS ("VPN on, no internet"). This makes the installer run
# independently (it just watches /run/rosenpass; it doesn't care who writes the
# PSKs) and forces an immediate install of the current PSKs.
set -uo pipefail
mkdir -p /etc/systemd/system/cloak-psk-installer.service.d
cat > /etc/systemd/system/cloak-psk-installer.service.d/override-cloak-rpd.conf <<'EOF'
[Unit]
# cloak-rpd replaces cloak-rosenpass as the PSK source; drop the lifecycle
# binding so the installer is not stopped when cloak-rosenpass is.
PartOf=
EOF
systemctl daemon-reload
systemctl enable cloak-psk-installer 2>/dev/null
systemctl restart cloak-psk-installer
sleep 1
# Nudge inotify so the installer applies the PSKs that already exist on disk
# (it is event-driven; existing files predate its watch).
touch /run/rosenpass/psk-* 2>/dev/null || true
sleep 2
echo "psk_installer=$(systemctl is-active cloak-psk-installer)"
