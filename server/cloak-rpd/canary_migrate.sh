#!/usr/bin/env bash
# us-east-1 canary cutover: cloak-rosenpass -> cloak-rpd (+ socket-aware regionsvc).
# Run ON the canary box. Expects staged files in /root/cloak-rpd-canary/:
#   cloak-rpd, regionsvc.new, cloak-rpd.service, rpd-build-peers.sh
# Instant rollback: bash /root/cloak-rpd-canary/canary_rollback.sh
set -uo pipefail
S=/root/cloak-rpd-canary
TS=20260530

echo "== preflight =="
[ -x "$S/cloak-rpd" ] || { echo "missing $S/cloak-rpd"; exit 1; }
[ -f /etc/rosenpass/server.rosenpass-secret ] || { echo "missing server secret"; exit 1; }
[ -f /etc/rosenpass/server.rosenpass-public ] || { echo "missing server public"; exit 1; }

echo "== install binaries + helpers =="
install -m 0755 "$S/cloak-rpd" /usr/local/bin/cloak-rpd
install -m 0755 "$S/rpd-build-peers.sh" /usr/local/bin/rpd-build-peers.sh
cp "$S/cloak-rpd.service" /etc/systemd/system/cloak-rpd.service
# backup current regionsvc, stage the new (socket-aware) one
cp -p /usr/local/bin/regionsvc "/usr/local/bin/regionsvc.bak-$TS"
install -m 0755 "$S/regionsvc.new" /usr/local/bin/regionsvc.stage
systemctl daemon-reload
systemctl enable cloak-rpd 2>/dev/null   # survive reboots

echo "== build preload peer set =="
/usr/local/bin/rpd-build-peers.sh

echo "== CUTOVER =="
# MASK cloak-rosenpass so nothing — including the not-yet-swapped old regionsvc
# calling `systemctl restart cloak-rosenpass` mid-cutover — can start it while
# cloak-rpd owns :9999. (disable alone doesn't block an explicit restart; mask
# does.) reset-failed clears any prior crash-loop state.
systemctl stop cloak-rosenpass
# cloak-rosenpass.service lives in /etc/systemd/system, so `systemctl mask`
# (which symlinks the unit name to /dev/null) FAILS with "file already exists".
# Move the unit aside + daemon-reload instead, so its Restart=on-failure can't
# crash-loop trying to re-bind the now-cloak-rpd-owned :9999.
if [ -f /etc/systemd/system/cloak-rosenpass.service ]; then
  mv -f /etc/systemd/system/cloak-rosenpass.service /etc/systemd/system/cloak-rosenpass.service.disabled-by-cloak-rpd
  systemctl daemon-reload
fi
systemctl reset-failed cloak-rosenpass 2>/dev/null
sleep 1
systemctl start cloak-rpd
sleep 2

# SAFETY: never leave the box with no rosenpass daemon. If cloak-rpd didn't come
# up, auto-rollback to cloak-rosenpass and abort this box.
if [ "$(systemctl is-active cloak-rpd)" != active ]; then
  echo "!! cloak-rpd failed to start — AUTO-ROLLBACK to cloak-rosenpass"
  journalctl -u cloak-rpd -n 8 --no-pager | tail -8
  if [ -f /etc/systemd/system/cloak-rosenpass.service.disabled-by-cloak-rpd ]; then
    mv -f /etc/systemd/system/cloak-rosenpass.service.disabled-by-cloak-rpd /etc/systemd/system/cloak-rosenpass.service
    systemctl daemon-reload
  fi
  systemctl start cloak-rosenpass
  echo "rollback cloak-rosenpass=$(systemctl is-active cloak-rosenpass)"
  exit 1
fi

mv -f /usr/local/bin/regionsvc.stage /usr/local/bin/regionsvc
systemctl restart regionsvc
sleep 2

# CRITICAL: cloak-psk-installer is PartOf=cloak-rosenpass.service, so moving
# cloak-rosenpass aside STOPS the installer — and without it cloak-rpd's PSKs
# never reach wg0, leaving the tunnel up but carrying no traffic. Decouple it
# and (re)start so it bridges cloak-rpd's PSKs onto WireGuard.
mkdir -p /etc/systemd/system/cloak-psk-installer.service.d
printf '[Unit]\nPartOf=\n' > /etc/systemd/system/cloak-psk-installer.service.d/override-cloak-rpd.conf
systemctl daemon-reload
systemctl enable cloak-psk-installer 2>/dev/null
systemctl restart cloak-psk-installer
sleep 1
touch /run/rosenpass/psk-* 2>/dev/null || true
sleep 1

echo "== verify =="
echo "cloak-rpd      : $(systemctl is-active cloak-rpd)"
echo "cloak-rosenpass: $(systemctl is-active cloak-rosenpass)  (expect inactive)"
echo "regionsvc      : $(systemctl is-active regionsvc)"
echo "control socket : $(ls -la /run/rosenpass/control.sock 2>&1)"
echo "udp :9999      : $(ss -lunp 2>/dev/null | grep ':9999' | head -1)"
echo "rpd log        :"; journalctl -u cloak-rpd -n 5 --no-pager | tail -5
echo "CANARY_DONE"
