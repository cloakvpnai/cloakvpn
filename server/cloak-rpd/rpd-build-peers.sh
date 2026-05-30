#!/usr/bin/env bash
# Populate /run/rosenpass/rpd-peers with symlinks to the peer rosenpass public
# keys referenced by server.toml, so cloak-rpd can preload the existing peer set
# at startup. Excludes the server's OWN key (server.toml lists it as the
# top-level keypair public_key, which must NOT be added as a peer).
set -u
TOML=/etc/rosenpass/server.toml
DIR=/run/rosenpass/rpd-peers
mkdir -p "$DIR"
rm -f "$DIR"/*.rosenpass-public 2>/dev/null
[ -f "$TOML" ] || { echo "rpd-build-peers: no $TOML"; exit 0; }

grep -oE 'public_key = "[^"]+"' "$TOML" | sed -E 's/public_key = "//; s/"$//' | while read -r pk; do
  base="$(basename "$pk")"
  case "$base" in
    server.rosenpass-public) continue ;;   # the server's own identity, not a peer
  esac
  [ -f "$pk" ] && ln -sf "$pk" "$DIR/$base"
done
echo "rpd-build-peers: staged $(ls "$DIR" 2>/dev/null | wc -l) peers"
