#!/bin/bash
# One-off fleet rollout of the regionsvc rosenpass-restart idempotency fix.
# Deploys /tmp/regionsvc-new to every box that already runs regionsvc, with
# sha-verify + backup + restart + active-check. Skips boxes that aren't
# regionsvc hosts or already carry the new binary. Safe to re-run.
set -u

NEW=/tmp/regionsvc-new
NEWSHA=$(sha256sum "$NEW" | awk '{print $1}')
echo "new binary sha256=$NEWSHA"

# All known box IPs (region concentrators + central API). Non-regionsvc
# boxes are auto-skipped by the is-active check below.
IPS="5.161.198.227 91.98.65.98 204.168.252.70 207.148.1.253 65.20.99.121 216.238.95.21 139.84.248.50 65.20.77.179 167.179.75.10 5.78.203.171"

SSHOPTS="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"

for ip in $IPS; do
  echo "===== $ip ====="
  active=$(ssh $SSHOPTS root@"$ip" 'systemctl is-active regionsvc 2>/dev/null' 2>/dev/null)
  if [ "$active" != "active" ]; then
    echo "  SKIP — regionsvc not active (got: '${active:-unreachable}')"
    continue
  fi
  cursha=$(ssh $SSHOPTS root@"$ip" 'sha256sum /usr/local/bin/regionsvc 2>/dev/null | cut -d" " -f1' 2>/dev/null)
  if [ "$cursha" = "$NEWSHA" ]; then
    echo "  ALREADY UP TO DATE (sha matches) — skipping"
    continue
  fi
  echo "  current sha=$cursha — deploying"
  if ! scp $SSHOPTS "$NEW" root@"$ip":/tmp/regionsvc-new >/dev/null 2>&1; then
    echo "  ERROR: scp failed"
    continue
  fi
  ssh $SSHOPTS root@"$ip" "set -e
    sha=\$(sha256sum /tmp/regionsvc-new | cut -d' ' -f1)
    if [ \"\$sha\" != \"$NEWSHA\" ]; then echo '  ERROR: sha mismatch on box, aborting'; exit 1; fi
    cp -a /usr/local/bin/regionsvc /usr/local/bin/regionsvc.bak-20260529
    systemctl stop regionsvc
    install -m 0755 /tmp/regionsvc-new /usr/local/bin/regionsvc
    systemctl start regionsvc
    sleep 1
    st=\$(systemctl is-active regionsvc)
    echo \"  installed, regionsvc=\$st\"
    if [ \"\$st\" != \"active\" ]; then echo '  WARNING: not active — check journal'; fi"
done
echo "===== ROLLOUT COMPLETE ====="
