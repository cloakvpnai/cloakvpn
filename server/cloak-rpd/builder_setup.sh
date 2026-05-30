#!/usr/bin/env bash
# One-time builder setup on a native amd64 host (idle-priority so it never
# starves co-located services like cloakvpn-api/regionsvc). Installs clang +
# rustup, clones rosenpass@b096cb1. Logs to /root/cloak-build/*.log.
# Cleanup later: rm -rf /root/.rustup /root/.cargo /root/cloak-build /root/rp
#                apt-get remove --purge clang libclang-dev   (optional)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
mkdir -p /root/cloak-build
LOG=/root/cloak-build/setup.log
: > "$LOG"

run() { nice -n 19 ionice -c3 "$@"; }

echo "[setup] apt deps" | tee -a "$LOG"
run apt-get update -qq >>"$LOG" 2>&1 || true
run apt-get install -y -qq --no-install-recommends clang libclang-dev pkg-config >>"$LOG" 2>&1

if [ ! -x /root/.cargo/bin/rustup ]; then
  echo "[setup] rustup" | tee -a "$LOG"
  curl -sSf https://sh.rustup.rs -o /root/cloak-build/rustup-init.sh
  run sh /root/cloak-build/rustup-init.sh -y --default-toolchain none >>"$LOG" 2>&1
fi
# shellcheck disable=SC1091
. /root/.cargo/env

if [ ! -d /root/rp/.git ]; then
  echo "[setup] clone rosenpass" | tee -a "$LOG"
  run git clone --quiet https://github.com/rosenpass/rosenpass.git /root/rp >>"$LOG" 2>&1
fi
run git -C /root/rp checkout -q b096cb1
echo "SETUP_DONE" | tee -a "$LOG"
