#!/bin/bash
# Check what monitoring is actually deployed on the fleet (probe 2 boxes).
for b in 5.78.203.171 207.148.1.253; do
  echo "===== $b ====="
  ssh -o BatchMode=yes -o ConnectTimeout=6 root@$b '
    hostname;
    systemctl list-units --type=service --state=running --no-legend --no-pager | grep -iE "grafana|prometheus|node_exp|alloy|netdata|uptime|exporter|monitor" || echo "no monitoring services running";
    ss -tlnp 2>/dev/null | grep -E "3000|9090|9100|19999" || echo "no monitoring ports listening";
  ' 2>&1
done
