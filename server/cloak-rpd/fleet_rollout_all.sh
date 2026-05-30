#!/usr/bin/env bash
# Stage + migrate cloak-rpd across the remaining region boxes, sequentially.
# RUN FROM THE MAC, detached (the per-box scp of the ~9MB regionsvc is slow over
# distant links and would trip an interactive timeout). Logs one VERIFY line per
# box. us-west-1 (the API/build box) is intentionally EXCLUDED — migrate it last
# by hand.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B="$(cd "$(dirname "$0")" && pwd)"
BOXES="207.148.1.253 65.20.99.121 216.238.95.21 139.84.248.50 65.20.77.179 167.179.75.10"

for IP in $BOXES; do
  echo "######## $IP : stage ########"
  ssh -o BatchMode=yes -o ConnectTimeout=12 "root@$IP" 'mkdir -p /root/cloak-rpd-canary' || { echo "$IP UNREACHABLE"; continue; }
  scp -o BatchMode=yes -o ConnectTimeout=12 /tmp/cloak-rpd.new2 "root@$IP:/root/cloak-rpd-canary/cloak-rpd"
  scp -o BatchMode=yes -o ConnectTimeout=12 /tmp/regionsvc.new2 "root@$IP:/root/cloak-rpd-canary/regionsvc.new"
  scp -o BatchMode=yes -o ConnectTimeout=12 "$B/cloak-rpd.service" "$B/rpd-build-peers.sh" "$B/canary_migrate.sh" "$B/canary_rollback.sh" "root@$IP:/root/cloak-rpd-canary/"

  # Integrity guard: only migrate if both binaries transferred fully.
  echo "######## $IP : migrate ########"
  ssh -o BatchMode=yes -o ConnectTimeout=12 "root@$IP" '
    rpd_sz=$(stat -c%s /root/cloak-rpd-canary/cloak-rpd 2>/dev/null);
    rsv_sz=$(stat -c%s /root/cloak-rpd-canary/regionsvc.new 2>/dev/null);
    if [ "$rpd_sz" != 1686952 ] || [ "$rsv_sz" != 8983773 ]; then
      echo "VERIFY '"$IP"': STAGING_INCOMPLETE rpd=$rpd_sz regionsvc=$rsv_sz"; exit 0;
    fi
    bash /root/cloak-rpd-canary/canary_migrate.sh >/root/cloak-build-migrate.log 2>&1;
    sleep 3;
    echo "VERIFY '"$IP"': rosenpass=$(systemctl is-active cloak-rosenpass) rpd=$(systemctl is-active cloak-rpd) restarts=$(systemctl show cloak-rpd -p NRestarts --value) regionsvc=$(systemctl is-active regionsvc) port9999=$(ss -lunp 2>/dev/null|grep -c :9999)"
  '
done
echo FLEET_ROLLOUT_DONE
