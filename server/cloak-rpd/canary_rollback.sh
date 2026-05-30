#!/usr/bin/env bash
# Instant rollback of the us-east-1 canary: back to cloak-rosenpass.
# The socket-aware regionsvc auto-falls-back to restarting cloak-rosenpass once
# the control socket is gone, so restoring the old regionsvc binary is optional
# (done here for full parity).
set -uo pipefail
TS=20260530
systemctl stop cloak-rpd 2>/dev/null
systemctl disable cloak-rpd 2>/dev/null
rm -f /run/rosenpass/control.sock
if [ -f "/usr/local/bin/regionsvc.bak-$TS" ]; then
  cp -p "/usr/local/bin/regionsvc.bak-$TS" /usr/local/bin/regionsvc
fi
if [ -f /etc/systemd/system/cloak-rosenpass.service.disabled-by-cloak-rpd ]; then
  mv -f /etc/systemd/system/cloak-rosenpass.service.disabled-by-cloak-rpd /etc/systemd/system/cloak-rosenpass.service
  systemctl daemon-reload
fi
systemctl unmask cloak-rosenpass 2>/dev/null
systemctl reset-failed cloak-rosenpass 2>/dev/null
systemctl start cloak-rosenpass
systemctl restart regionsvc
sleep 2
echo "cloak-rosenpass: $(systemctl is-active cloak-rosenpass)"
echo "cloak-rpd      : $(systemctl is-active cloak-rpd)  (expect inactive)"
echo "regionsvc      : $(systemctl is-active regionsvc)"
echo "ROLLBACK_DONE"
