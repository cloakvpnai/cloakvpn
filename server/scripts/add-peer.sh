#!/usr/bin/env bash
# Cloak VPN — Add a new peer (client)
#
# Usage:
#   sudo ./add-peer.sh <peer-name>                                       (legacy: server generates everything)
#   sudo ./add-peer.sh <peer-name> <rp-pubkey-file>                      (modern: client rosenpass pubkey only)
#   sudo ./add-peer.sh <peer-name> <rp-pubkey-file> <wg-pubkey-b64>      (full privacy: both pubkeys client-side)
#
# When invoked with both an rp-pubkey path AND a wg-pubkey base64 string,
# the server registers the peer using the client's locally-generated
# keypairs and never sees, generates, or stores any private keys. The
# output config block omits the private_key field — the iPhone already
# has its own. This is the privacy-correct mode used by cloak-api-server
# (HTTP onboarding API) and the iOS app's "Add Region" flow.
#
# When invoked with rosenpass pubkey only, the WG keypair is still
# server-generated for backward compatibility with older clients.
#
# When invoked WITHOUT either pubkey, falls back to fully-legacy mode:
# server generates both keypairs. Useful for non-PQ clients or CLI/test
# installs that don't run the iOS app.

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

NAME="${1:-}"
CLIENT_PUBKEY_PATH="${2:-}"
CLIENT_WG_PUBKEY_B64="${3:-}"
[[ -n "$NAME" ]] || { echo "Usage: $0 <peer-name> [rp-pubkey-file] [wg-pubkey-b64]"; exit 1; }
[[ "$NAME" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "peer-name must be [A-Za-z0-9._-]"; exit 1; }

WG_IFACE="${WG_IFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
RP_PORT="${RP_PORT:-9999}"
ETC_WG=/etc/wireguard
ETC_RP=/etc/rosenpass
PUBLIC_IP="${PUBLIC_IP:-$(curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}')}"

# Pick next available /32 in 10.99.0.0/24 (skip .1 server, .2 reserved test client)
last_oct=$(awk -F'[./ ]+' '/AllowedIPs/ {for (i=1;i<=NF;i++) if ($i ~ /^10\.99\.0\./) print $i}' "$ETC_WG/$WG_IFACE.conf" | awk -F. '{print $4}' | sort -n | tail -1)
next=$(( ${last_oct:-2} + 1 ))
(( next < 254 )) || { echo "Subnet full"; exit 1; }
PEER_V4="10.99.0.$next"
PEER_V6="fd42:99::$(printf '%x' $next)"

umask 077

# ---------- WireGuard keypair --------------------------------------------
# Three modes:
#   (a) caller provides WG pubkey → register-only, server holds no
#       private key. Privacy-correct. Used by cloak-api-server.
#   (b) caller doesn't provide WG pubkey → generate server-side as
#       before. Smaller privacy hole than rosenpass-on-server (WG uses
#       ephemeral DH per session) but still imperfect. Legacy/CLI path.
LEGACY_WG_KEYGEN_MODE=0
if [[ -n "$CLIENT_WG_PUBKEY_B64" ]]; then
  echo "[add-peer] Using client-provided WG pubkey (server holds no WG private key)"
  # WG public keys are 32 bytes Curve25519, base64-encoded → exactly
  # 44 chars including padding. Validate before persisting.
  if [[ ! "$CLIENT_WG_PUBKEY_B64" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "ERROR: WG pubkey must be 44-char base64 (got '${CLIENT_WG_PUBKEY_B64:0:60}'... length=${#CLIENT_WG_PUBKEY_B64})"
    exit 1
  fi
  PEER_PUB="$CLIENT_WG_PUBKEY_B64"
  echo "$PEER_PUB" > "$ETC_WG/$NAME.pub"
  chmod 600 "$ETC_WG/$NAME.pub"
  PEER_PRIV=""  # never set; flagged in config-output below
else
  LEGACY_WG_KEYGEN_MODE=1
  echo "[add-peer] WARNING: no WG pubkey provided; generating WG keypair server-side (LEGACY)"
  wg genkey | tee "$ETC_WG/$NAME.key" | wg pubkey > "$ETC_WG/$NAME.pub"
  PEER_PRIV=$(cat "$ETC_WG/$NAME.key")
  PEER_PUB=$(cat "$ETC_WG/$NAME.pub")
fi

# ---------- Rosenpass keypair OR provided client pubkey ------------------
LEGACY_KEYGEN_MODE=0
if [[ -n "$CLIENT_PUBKEY_PATH" ]]; then
  [[ -f "$CLIENT_PUBKEY_PATH" ]] || { echo "Pubkey file not found: $CLIENT_PUBKEY_PATH"; exit 1; }
  echo "[add-peer] Using client-provided rosenpass pubkey from $CLIENT_PUBKEY_PATH"
  # File contents are expected to be the base64 string of the client's
  # rosenpass public key (no padding/whitespace requirements; -d
  # tolerates trailing newlines). Decode and write the binary file
  # rosenpass expects on disk.
  base64 -d "$CLIENT_PUBKEY_PATH" > "$ETC_RP/$NAME.rosenpass-public"
  # Sanity-check size — Classic McEliece-460896 public key is exactly
  # 524160 bytes. Catches obvious corruption (truncation, wrong file
  # type) before rosenpass starts up and fails opaquely.
  expected_size=524160
  actual_size=$(stat -c%s "$ETC_RP/$NAME.rosenpass-public")
  if [[ "$actual_size" -ne "$expected_size" ]]; then
    echo "ERROR: pubkey size $actual_size != expected $expected_size (Classic McEliece-460896)"
    rm -f "$ETC_RP/$NAME.rosenpass-public"
    exit 1
  fi
  chmod 600 "$ETC_RP/$NAME.rosenpass-public"
  # Deliberately NOT generating .rosenpass-secret server-side. The
  # client holds it; we never see it. That's the privacy property we
  # bought with this whole refactor.
else
  LEGACY_KEYGEN_MODE=1
  echo "[add-peer] WARNING: no pubkey provided; falling back to server-side keygen (LEGACY — broken privacy posture)"
  rosenpass gen-keys \
    --secret-key "$ETC_RP/$NAME.rosenpass-secret" \
    --public-key "$ETC_RP/$NAME.rosenpass-public"
fi

# ---------- WireGuard peer registration ----------------------------------
cat >>"$ETC_WG/$WG_IFACE.conf" <<EOF

[Peer]
# $NAME
PublicKey = $PEER_PUB
AllowedIPs = $PEER_V4/32, $PEER_V6/128
EOF

# ---------- Rosenpass peer registration ----------------------------------
#
# protocol_version = "V03" is REQUIRED — the iOS FFI (and any rosenpass-rs
# client built off git rev b096cb1+) defaults to V03 (SHAKE256-based).
# Without this line the server peer entry defaults to V02 (Blake2b) and
# every InitHello fails with "No valid hash function found for InitHello"
# at the rosenpass::protocol::CryptoServer::handle_msg dispatch. Cost us
# multiple hours on the 2026-04-25 smoke-test debugging run; do not remove.
cat >>"$ETC_RP/server.toml" <<EOF

[[peers]]
public_key = "$ETC_RP/$NAME.rosenpass-public"
key_out = "/run/rosenpass/psk-$NAME"
protocol_version = "V03"
EOF

# Hot-reload WireGuard (doesn't drop existing tunnels)
wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE")

# Restart rosenpass to pick up new peer (brief handshake interruption)
systemctl restart cloak-rosenpass.service

# ---------- Output the client config block -------------------------------
SERVER_RP_PUB_B64=$(base64 -w0 "$ETC_RP/server.rosenpass-public")
SERVER_WG_PUB=$(cat "$ETC_WG/server.pub")

# In recommended (client-pubkey) mode, the config does NOT carry any
# client rosenpass keys — the iOS app already has its locally-generated
# keypair persisted in the App Group container. Only the server's pubkey
# travels in the wire-format config. Drops config size from ~1.4 MB to
# ~700 KB and closes the privacy hole simultaneously.
#
# In legacy mode (no pubkey provided), we still emit the full set so any
# CLI / non-iOS client can use the config as a self-contained bundle.
if [[ "$LEGACY_KEYGEN_MODE" -eq 1 ]]; then
  CLIENT_RP_SECRET_B64=$(base64 -w0 "$ETC_RP/$NAME.rosenpass-secret")
  CLIENT_RP_PUB_B64=$(base64 -w0 "$ETC_RP/$NAME.rosenpass-public")
fi

cat <<EOF

----- CLIENT CONFIG ($NAME) -------------------------------------------------

[wireguard]
EOF

# Only emit private_key when the server actually has one (legacy WG
# keygen mode). In the privacy-correct flow the iPhone keeps its own
# WG private key; the importer reads its locally-stored key instead.
if [[ "$LEGACY_WG_KEYGEN_MODE" -eq 1 ]]; then
  echo "private_key = $PEER_PRIV"
fi

cat <<EOF
address_v4  = $PEER_V4/32
address_v6  = $PEER_V6/128
dns         = 9.9.9.9, 2620:fe::fe

[wireguard.peer]
public_key = $SERVER_WG_PUB
endpoint   = $PUBLIC_IP:$WG_PORT
allowed_ips = 0.0.0.0/0, ::/0
persistent_keepalive = 25

[rosenpass]
server_public_key_b64 = $SERVER_RP_PUB_B64
server_endpoint       = $PUBLIC_IP:$RP_PORT
psk_rotation_seconds  = 120
EOF

# Legacy-mode-only fields. Modern clients (iOS app) hold their own
# keypair locally and ignore these even if present.
if [[ "$LEGACY_KEYGEN_MODE" -eq 1 ]]; then
  cat <<EOF
client_secret_key_b64 = $CLIENT_RP_SECRET_B64
client_public_key_b64 = $CLIENT_RP_PUB_B64
EOF
fi

cat <<EOF

-----------------------------------------------------------------------------

Peer "$NAME" added. Assigned $PEER_V4, $PEER_V6.
EOF
