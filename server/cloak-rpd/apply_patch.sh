#!/usr/bin/env bash
# Apply the cloak-rpd patch into a checked-out rosenpass workspace (b096cb1).
#   ./apply_patch.sh /path/to/rosenpass-workspace
# Idempotent-ish: re-running re-copies the bin and re-inserts only if absent.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WS="${1:-$HOME/cloak-rpd-build/rosenpass}"      # repo root of the rosenpass workspace
CRATE="${WS}/rosenpass"                          # the `rosenpass` crate dir
APP="${CRATE}/src/app_server.rs"
CARGO="${CRATE}/Cargo.toml"
BIN_DST="${CRATE}/src/bin/cloak-rpd.rs"

[ -f "${APP}" ] || { echo "app_server.rs not found at ${APP}"; exit 1; }

# 1. daemon source -> bin
mkdir -p "${CRATE}/src/bin"
cp "${HERE}/src/main.rs" "${BIN_DST}"
echo "copied daemon -> ${BIN_DST}"

# 2. register the [[bin]] (append once)
if ! grep -q 'name = "cloak-rpd"' "${CARGO}"; then
  cat >> "${CARGO}" <<'TOML'

[[bin]]
name = "cloak-rpd"
path = "src/bin/cloak-rpd.rs"
required-features = ["experiment_api"]
TOML
  echo "registered [[bin]] cloak-rpd in ${CARGO}"
else
  echo "[[bin]] cloak-rpd already registered"
fi

# 3. insert event_loop_with_control before handle_msg_under_load (once)
if ! grep -q 'fn event_loop_with_control' "${APP}"; then
  ANCHOR='    /// Helper for \[Self::event_loop_without_error_handling\] to handle network messages'
  python3 - "${APP}" "${HERE}/patches/event_loop_with_control.rs.snippet" <<'PY'
import sys
app_path, snippet_path = sys.argv[1], sys.argv[2]
app = open(app_path).read()
snippet = open(snippet_path).read()
anchor = "    /// Helper for [Self::event_loop_without_error_handling] to handle network messages"
idx = app.find(anchor)
if idx == -1:
    sys.exit("anchor not found in app_server.rs")
# strip the leading comment-block header lines of the snippet (everything up to
# the first method doc line) so we insert clean Rust.
marker = "    /// Like [Self::event_loop_without_error_handling]"
mi = snippet.find(marker)
method = snippet[mi:] if mi != -1 else snippet
out = app[:idx] + method + "\n" + app[idx:]
open(app_path, "w").write(out)
print("inserted event_loop_with_control before handle_msg_under_load")
PY
else
  echo "event_loop_with_control already present"
fi

echo "patch applied to ${WS}"
