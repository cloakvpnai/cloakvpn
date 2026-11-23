#!/bin/sh
# Encrypts the roadmap tracker with the passphrase held in this Mac's login
# keychain and writes website-v2/public/roadmap/index.html.
#   Set the passphrase once:
#     security add-generic-password -U -a lattice -s lattice-roadmap-passphrase -w
#   Then: scripts/publish-roadmap.sh /path/to/tracker.html
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROADMAP_PASSPHRASE="$(security find-generic-password -a lattice -s lattice-roadmap-passphrase -w)" \
  node "$HERE/build-roadmap.mjs" "$1"
