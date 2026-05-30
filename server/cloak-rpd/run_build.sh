#!/usr/bin/env bash
# Build cloak-rpd natively at idle priority on the builder box.
set -uo pipefail
. /root/.cargo/env
cd /root/rp
nice -n 19 ionice -c3 cargo build --release --features experiment_api --bin cloak-rpd
echo "BUILD_EXIT=$?"
