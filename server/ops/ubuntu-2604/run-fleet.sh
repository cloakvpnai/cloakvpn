#!/bin/bash
# Upgrades servers one after another and stops at the first that fails.
#   run-fleet.sh <helper ip> name:ip:publichost [name:ip:publichost ...]
HERE="$(cd "$(dirname "$0")" && pwd)"; HELPER=$1; shift
for e in "$@"; do
  IFS=: read -r n ip host <<< "$e"
  bash "$HERE/upgrade-one.sh" "$n" "$ip" "$host" "$HELPER"; rc=$?
  if [ $rc -ne 0 ]; then echo "$(date +%T) FLEET STOPPED at $n (exit $rc). Remaining servers were not touched."; exit $rc; fi
done
echo "$(date +%T) FLEET DONE: $*"
