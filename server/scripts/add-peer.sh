#!/usr/bin/env bash
# Cloak VPN — Add a new peer (client)
# Usage: sudo ./add-peer.sh <peer-name>
# Produces: WireGuard keypair, Rosenpass keypair, updates server configs,
#           hot-reloads both daemons, prints the client config block.

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

NAME="${1:-}"
[[ -n "$NAME" ]] || { echo "Usage: $0 <peer-name>"; exit 1; }
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
wg genkey | tee "$ETC_WG/$NAME.key" | wg pubkey > "$ETC_WG/$NAME.pub"
PEER_PRIV=$(cat "$ETC_WG/$NAME.key")
PEER_PUB=$(cat "$ETC_WG/$NAME.pub")

rosenpass gen-keys \
  --secret-key "$ETC_RP/$NAME.rosenpass-secret" \
  --public-key "$ETC_RP/$NAME.rosenpass-public"

# Append WireGuard peer
cat >>"$ETC_WG/$WG_IFACE.conf" <<EOF

[Peer]
# $NAME
PublicKey = $PEER_PUB
AllowedIPs = $PEER_V4/32, $PEER_V6/128
EOF

# Append Rosenpass peer
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

# Copy peer's Rosenpass secret+public to an export blob for the client
EXPORT_DIR=$(mktemp -d)
cp "$ETC_RP/$NAME.rosenpass-secret" "$EXPORT_DIR/"
cp "$ETC_RP/$NAME.rosenpass-public" "$EXPORT_DIR/"
SERVER_RP_PUB_B64=$(base64 -w0 "$ETC_RP/server.rosenpass-public")
CLIENT_RP_SECRET_B64=$(base64 -w0 "$ETC_RP/$NAME.rosenpass-secret")
CLIENT_RP_PUB_B64=$(base64 -w0 "$ETC_RP/$NAME.rosenpass-public")
SERVER_WG_PUB=$(cat "$ETC_WG/server.pub")

cat <<EOF

----- CLIENT CONFIG ($NAME) -------------------------------------------------

[wireguard]
private_key = $PEER_PRIV
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
client_secret_key_b64 = $CLIENT_RP_SECRET_B64
client_public_key_b64 = $CLIENT_RP_PUB_B64
psk_rotation_seconds  = 120

-----------------------------------------------------------------------------

Peer "$NAME" added. Assigned $PEER_V4, $PEER_V6.
EOF

# Clean export dir
rm -rf "$EXPORT_DIR"
