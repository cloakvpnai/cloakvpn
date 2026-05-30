#!/usr/bin/env bash
# Push the cloak-psk-installer decoupling fix to the whole fleet. RUN FROM MAC.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B="$(cd "$(dirname "$0")" && pwd)"
BOXES="5.78.203.171 5.161.198.227 91.98.65.98 204.168.252.70 207.148.1.253 65.20.99.121 216.238.95.21 139.84.248.50 65.20.77.179 167.179.75.10"
for IP in $BOXES; do
  ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$IP" 'mkdir -p /root/cloak-rpd-canary' 2>/dev/null || { echo "$IP UNREACHABLE"; continue; }
  scp -o BatchMode=yes -o ConnectTimeout=10 "$B/fix_psk_installer.sh" "root@$IP:/root/cloak-rpd-canary/" >/dev/null 2>&1
  R=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$IP" 'bash /root/cloak-rpd-canary/fix_psk_installer.sh 2>/dev/null | tail -1')
  echo "$IP : $R"
done
echo FLEET_PSK_FIX_DONE
