#!/usr/bin/env bash
# Cloak VPN — Post-quantum PSK installer
#
# What this does:
#   The rosenpass daemon completes a PQ key exchange (Classic McEliece +
#   ML-KEM-768) every ~120s for each registered peer and atomically writes
#   the derived 32-byte PSK to /run/rosenpass/psk-<peer-name>. But rosenpass
#   does NOT itself install the PSK into the WireGuard interface — that's
#   our job. This service watches the directory via inotify and, on every
#   PSK write, runs:
#
#     wg set <iface> peer <peer-pubkey> preshared-key <psk-file>
#
#   Without this bridge, the PQ handshake completes server-side but the
#   new PSK never makes it into wg0. The client (iOS app) re-keys
#   internally with the PSK it derived; the server's wg0 still uses the
#   old PSK. After rotation #1 the two sides diverge and ALL subsequent
#   encrypted packets fail to decrypt — the tunnel silently goes black.
#
# Filename convention (set by add-peer.sh / setup.sh as `key_out = ...`):
#   /run/rosenpass/psk-<peer-name>
#
# Peer-name → WG pubkey lookup:
#   /etc/wireguard/<peer-name>.pub
#   (Created by setup.sh for client1 and by add-peer.sh for every new peer.)
#
# Generic over peers — adding a new peer via add-peer.sh "just works":
# the new /run/rosenpass/psk-<name> appears, this watcher derives the
# peer name from the filename, finds the matching .pub file, applies.
# No per-peer scripts or service instances needed.
#
# Failure modes handled:
#   - PSK file appears for a peer with no .pub registered → logged + skipped
#     (e.g. a stale rosenpass peer entry whose corresponding wg peer was
#     manually removed)
#   - inotifywait dies → systemd Restart=on-failure will re-launch us
#   - Existing PSK files at startup → applied immediately on service start
#     (recovers cleanly after a service restart that missed earlier writes)

set -euo pipefail

WG_IFACE="${WG_IFACE:-wg0}"
PSK_DIR="${PSK_DIR:-/run/rosenpass}"
PUBKEY_DIR="${PUBKEY_DIR:-/etc/wireguard}"

log() { printf "[psk-installer] %s\n" "$*"; }

# Apply a single PSK file to the corresponding wg peer.
# Idempotent — applying the same PSK twice is a no-op for WireGuard.
apply_psk() {
  local psk_file="$1"
  local fname
  fname=$(basename "$psk_file")

  # Only handle files matching psk-<peer-name>. Anything else (e.g. rosenpass
  # internal state files, editor swap files) gets ignored.
  if [[ ! "$fname" =~ ^psk-(.+)$ ]]; then
    return 0
  fi
  local peer_name="${BASH_REMATCH[1]}"
  local pubkey_file="$PUBKEY_DIR/$peer_name.pub"

  if [[ ! -f "$pubkey_file" ]]; then
    log "no WG pubkey at $pubkey_file for peer '$peer_name' — skipping"
    return 0
  fi
  local pubkey
  pubkey=$(<"$pubkey_file")

  if wg set "$WG_IFACE" peer "$pubkey" preshared-key "$psk_file"; then
    log "PSK rotated for $peer_name"
  else
    log "ERROR: wg set failed for peer '$peer_name' (pubkey=$pubkey)"
    return 1
  fi
}

# Apply any PSK files that already exist when we start. Covers the case
# where rosenpass wrote PSKs while we were down (e.g. after a brief crash
# loop or the service restart following an apt upgrade).
log "scanning $PSK_DIR for existing PSK files"
shopt -s nullglob
for f in "$PSK_DIR"/psk-*; do
  apply_psk "$f" || true
done
shopt -u nullglob

# Watch for future PSK writes. rosenpass writes via tmpfile + rename
# (atomic), which fires MOVED_TO. We also watch CLOSE_WRITE for safety in
# case of any rosenpass version that uses direct write+close instead.
log "watching $PSK_DIR for new PSK files"
exec inotifywait -m \
  -e close_write \
  -e moved_to \
  --format '%w%f' \
  "$PSK_DIR" \
  | while read -r path; do
      apply_psk "$path" || true
    done
