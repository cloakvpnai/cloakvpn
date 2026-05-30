#!/usr/bin/env bash
# Reproducible build of the patched rosenpass + cloak-rpd daemon for linux/amd64.
#
# Produces a single static-ish ELF that runs the rosenpass key-exchange with a
# line-based unix control socket for ZERO-DISRUPTION runtime peer add (no daemon
# restart on provision). See docs/ROSENPASS_NO_RESTART_PEER_MGMT.md.
#
# STATUS: WIP harness. The daemon source (src/main.rs) and the app_server
# control-loop patch (patches/) are first drafts and have NOT yet been
# compiled/verified end-to-end. Do NOT deploy to any production box until the
# local two-endpoint no-disruption spike passes.
#
# Usage:  ./build.sh            # builds in Docker (linux/amd64), output -> ./out/cloak-rpd
set -euo pipefail

RP_REV="b096cb1"                       # pinned rosenpass rev (matches RosenpassFFI)
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${HERE}/.work"
OUT="${HERE}/out"

mkdir -p "${WORK}" "${OUT}"

# 1. Fetch the pinned rosenpass workspace.
if [ ! -d "${WORK}/rosenpass/.git" ]; then
  git clone https://github.com/rosenpass/rosenpass.git "${WORK}/rosenpass"
fi
git -C "${WORK}/rosenpass" checkout -q "${RP_REV}"

# 2. Drop in the cloak-rpd binary source and apply the app_server control-loop
#    patch. (patches/app_server_control.rs is appended as a module + the bin is
#    registered in Cargo.toml. See patches/README for the exact hunks.)
cp "${HERE}/src/main.rs" "${WORK}/rosenpass/rosenpass/src/bin/cloak-rpd.rs"
# NOTE: the app_server `event_loop_with_control` patch must be applied here
#       (see patches/app_server_control.md). Left as an explicit manual step
#       until the method is finalized + compiles.

# 3. Build linux/amd64 in Docker (emulated on Apple Silicon).
docker run --rm --platform linux/amd64 \
  -v "${WORK}/rosenpass":/src \
  -v cloak_cargo_registry:/usr/local/cargo/registry \
  -w /src rust:bookworm bash -c '
    set -e
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends cmake clang libclang-dev pkg-config >/tmp/apt.log 2>&1
    cargo build --release --features experiment_api --bin cloak-rpd
  '

cp "${WORK}/rosenpass/target/release/cloak-rpd" "${OUT}/cloak-rpd"
echo "built: ${OUT}/cloak-rpd"
sha256sum "${OUT}/cloak-rpd" || shasum -a 256 "${OUT}/cloak-rpd"
