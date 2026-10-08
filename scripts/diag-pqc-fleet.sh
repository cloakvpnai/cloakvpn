#!/bin/bash
# Fleet PQC diagnosis — runs from the Mac, ssh's each region box.
# For each box: which rosenpass daemon is active, control socket presence,
# recent cloak-rpd restarts, and recent ADDs/exchanges in the journal.
BOXES="5.78.203.171 5.161.198.227 204.168.252.70 91.98.65.98"
for b in $BOXES; do
  echo "===== $b ====="
  ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new root@$b '
    hostname;
    echo "cloak-rpd: $(systemctl is-active cloak-rpd 2>/dev/null) | cloak-rosenpass: $(systemctl is-active cloak-rosenpass 2>/dev/null)";
    ls -la /run/rosenpass/control.sock 2>/dev/null || echo "NO control socket";
    systemctl show cloak-rpd -p NRestarts 2>/dev/null;
    echo "--- last 12 rpd journal lines:";
    journalctl -u cloak-rpd -n 12 --no-pager 2>/dev/null | tail -12;
  ' 2>&1
  echo
done
