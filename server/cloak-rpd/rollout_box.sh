#!/usr/bin/env bash
# Stage + migrate ONE fleet box to cloak-rpd. RUN FROM THE MAC (orchestrator).
#   ./rollout_box.sh <box-ip>
# Requires the session-built binaries at /tmp/cloak-rpd.new2 and /tmp/regionsvc.new2.
# Idempotent-ish: safe to re-run; canary_migrate backs up the existing regionsvc.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
IP="${1:?usage: rollout_box.sh <ip>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 root@$IP"
SCP="scp -o BatchMode=yes -o ConnectTimeout=10"

echo "==== $IP : stage ===="
$SSH 'mkdir -p /root/cloak-rpd-canary'
$SCP /tmp/cloak-rpd.new2 "root@$IP:/root/cloak-rpd-canary/cloak-rpd"
$SCP /tmp/regionsvc.new2 "root@$IP:/root/cloak-rpd-canary/regionsvc.new"
$SCP "$HERE/cloak-rpd.service" "$HERE/rpd-build-peers.sh" "$HERE/canary_migrate.sh" "$HERE/canary_rollback.sh" "root@$IP:/root/cloak-rpd-canary/"

echo "==== $IP : migrate ===="
$SSH 'chmod +x /root/cloak-rpd-canary/*.sh /root/cloak-rpd-canary/cloak-rpd /root/cloak-rpd-canary/regionsvc.new; bash /root/cloak-rpd-canary/canary_migrate.sh'
