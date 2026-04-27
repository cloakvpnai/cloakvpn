#!/usr/bin/env bash
# Cloak VPN — Server bootstrap script
# Target: Ubuntu 24.04 LTS, fresh install, run as root.
#
# Installs:
#   - WireGuard
#   - Rosenpass (post-quantum key-exchange daemon that feeds WireGuard PSKs)
#   - UFW firewall with a deny-by-default policy
#   - systemd units for both daemons
#   - RAM-only /var/log mount (tmpfs) for no-logs posture
#
# After running, the script prints:
#   - Server WireGuard public key
#   - Server Rosenpass public key
#   - A ready-to-paste client config block

set -euo pipefail

log()  { printf "\033[1;34m[cloak]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[err]\033[0m %s\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (use sudo)."

# ---------- Configurable --------------------------------------------------
WG_IFACE="${WG_IFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
RP_PORT="${RP_PORT:-9999}"
WG_NET_V4="${WG_NET_V4:-10.99.0.0/24}"
WG_NET_V6="${WG_NET_V6:-fd42:99::/64}"
SERVER_V4="${SERVER_V4:-10.99.0.1}"
SERVER_V6="${SERVER_V6:-fd42:99::1}"
CLIENT_V4="${CLIENT_V4:-10.99.0.2}"
CLIENT_V6="${CLIENT_V6:-fd42:99::2}"
ETH_IFACE="${ETH_IFACE:-$(ip -o -4 route show default | awk '{print $5; exit}')}"
PUBLIC_IP="${PUBLIC_IP:-$(curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}')}"

ETC_WG=/etc/wireguard
ETC_RP=/etc/rosenpass
# --------------------------------------------------------------------------

log "Public IP detected: $PUBLIC_IP (outbound iface: $ETH_IFACE)"
log "WireGuard iface $WG_IFACE on :$WG_PORT ; Rosenpass on :$RP_PORT"

# ---------- Update & base packages ----------------------------------------
log "apt update and install base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl ca-certificates gnupg ufw \
  wireguard wireguard-tools \
  qrencode jq iproute2 \
  build-essential pkg-config \
  inotify-tools

# ---------- Install Rosenpass --------------------------------------------
# CRITICAL: the rosenpass binary on the server MUST match the rosenpass
# crate version compiled into the iOS FFI (clients/ios/RosenpassFFI/Cargo.toml).
# Different versions produce incompatible McEliece secret-key serialization
# formats (a 40-byte difference between recent revs vs. apt/crates.io
# releases) — the iOS handshake will fail with `invalid input: secret
# key wrong length`. We pin both sides to the same git commit.
#
# When you bump the iOS FFI's rosenpass `rev` in
# clients/ios/RosenpassFFI/Cargo.toml, also bump ROSENPASS_REV here AND
# re-run setup.sh (or just `cargo install --force ...`) on every server.
ROSENPASS_REV="b096cb1"  # must match clients/ios/RosenpassFFI/Cargo.toml

log "Installing Rosenpass (git rev $ROSENPASS_REV)"
# Build deps for rosenpass-from-source on Ubuntu 24.04:
#   - cmake            : oqs-sys (C liboqs build for Kyber + Classic McEliece)
#   - libclang-dev     : bindgen (for oqs-sys and libsodium-sys-stable)
#   - libsodium-dev    : libsodium-sys-stable (classical crypto primitives)
#   - pkg-config + build-essential already installed above.
# (We deliberately do NOT install apt's `cargo` package here — Ubuntu
# 24.04 ships rustc 1.75 which is too old for rosenpass HEAD requiring
# 1.77+. Use rustup to pull current stable instead, see below.)
apt-get install -y -qq cmake libclang-dev libsodium-dev curl

# Install rustup (current stable Rust) if cargo isn't already a recent
# version. rosenpass at b096cb1+ requires rustc 1.77+; apt's cargo on
# Ubuntu 24.04 LTS ships 1.75, which silently fails the install with
# "requires rustc 1.77.0 or newer" — and the failure was non-fatal in
# our previous setup, leading to a half-broken state where the daemon
# ran on a stale rosenpass. Force rustup to avoid the trap.
if ! command -v rustc >/dev/null || ! rustc --version | awk '{print $2}' | awk -F. '{exit !($1>1 || ($1==1 && $2>=77))}'; then
  log "Installing rustup (current stable Rust toolchain)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --no-modify-path
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi
log "Rust toolchain: $(rustc --version) at $(command -v rustc)"

# Pinning to a git rev (NOT crates.io / apt) is intentional — see comment
# above. --force lets us re-run setup.sh idempotently to bump the rev.
# --root installs into /usr/local (no $HOME fiddling).
cargo install --locked --force --root /usr/local \
  --git https://github.com/rosenpass/rosenpass.git \
  --rev "$ROSENPASS_REV" \
  rosenpass

command -v rosenpass >/dev/null || die "Rosenpass install failed — binary not on PATH."
log "Rosenpass binary: $(command -v rosenpass) ($(rosenpass --version 2>&1 | head -n1))"

# ---------- Kernel / sysctl ----------------------------------------------
log "Enabling IPv4/IPv6 forwarding"
cat >/etc/sysctl.d/99-cloak-vpn.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.conf.all.rp_filter=2
EOF
sysctl --system >/dev/null

# ---------- WireGuard keys ------------------------------------------------
install -m 700 -d "$ETC_WG"
if [[ ! -f $ETC_WG/server.key ]]; then
  log "Generating WireGuard server keypair"
  umask 077
  wg genkey | tee "$ETC_WG/server.key" | wg pubkey >"$ETC_WG/server.pub"
fi
WG_SERVER_PRIV=$(cat "$ETC_WG/server.key")
WG_SERVER_PUB=$(cat "$ETC_WG/server.pub")

if [[ ! -f $ETC_WG/client1.key ]]; then
  log "Generating WireGuard client1 keypair (test client)"
  wg genkey | tee "$ETC_WG/client1.key" | wg pubkey >"$ETC_WG/client1.pub"
fi
WG_CLIENT_PRIV=$(cat "$ETC_WG/client1.key")
WG_CLIENT_PUB=$(cat "$ETC_WG/client1.pub")

# ---------- Rosenpass keys ------------------------------------------------
install -m 700 -d "$ETC_RP"
if [[ ! -f $ETC_RP/server.rosenpass-secret ]]; then
  log "Generating Rosenpass server keypair"
  rosenpass gen-keys \
    --secret-key "$ETC_RP/server.rosenpass-secret" \
    --public-key "$ETC_RP/server.rosenpass-public"
fi
if [[ ! -f $ETC_RP/client1.rosenpass-secret ]]; then
  log "Generating Rosenpass client1 keypair"
  rosenpass gen-keys \
    --secret-key "$ETC_RP/client1.rosenpass-secret" \
    --public-key "$ETC_RP/client1.rosenpass-public"
fi

# ---------- WireGuard config ---------------------------------------------
log "Writing $ETC_WG/$WG_IFACE.conf"
cat >"$ETC_WG/$WG_IFACE.conf" <<EOF
# Cloak VPN — WireGuard server config
# Generated by setup.sh. Rosenpass rotates PresharedKey every ~120s.
[Interface]
Address = $SERVER_V4/24, $SERVER_V6/64
ListenPort = $WG_PORT
PrivateKey = $WG_SERVER_PRIV
PostUp   = iptables  -t nat -A POSTROUTING -s $WG_NET_V4 -o $ETH_IFACE -j MASQUERADE
PostUp   = ip6tables -t nat -A POSTROUTING -s $WG_NET_V6 -o $ETH_IFACE -j MASQUERADE
PostDown = iptables  -t nat -D POSTROUTING -s $WG_NET_V4 -o $ETH_IFACE -j MASQUERADE
PostDown = ip6tables -t nat -D POSTROUTING -s $WG_NET_V6 -o $ETH_IFACE -j MASQUERADE

[Peer]
# client1 (test client)
PublicKey = $WG_CLIENT_PUB
AllowedIPs = $CLIENT_V4/32, $CLIENT_V6/128
# PresharedKey managed by rosenpass (wg set --preshared-key /dev/stdin)
EOF
chmod 600 "$ETC_WG/$WG_IFACE.conf"

# ---------- Rosenpass config ---------------------------------------------
log "Writing $ETC_RP/server.toml"
cat >"$ETC_RP/server.toml" <<EOF
# Cloak VPN — Rosenpass server config
public_key = "$ETC_RP/server.rosenpass-public"
secret_key = "$ETC_RP/server.rosenpass-secret"
# A single IPv6 wildcard listener covers both v4 and v6 on Linux (IPV6_V6ONLY=0
# by default), so this is both "dual-stack" and avoids the self-collision bug
# where rosenpass binds 0.0.0.0:$RP_PORT then fails to bind [::]:$RP_PORT
# because the v6 wildcard implicitly conflicts with the v4 wildcard.
listen = ["[::]:$RP_PORT"]
verbosity = "Quiet"

[[peers]]
public_key = "$ETC_RP/client1.rosenpass-public"
# Tell rosenpass to rotate this WireGuard peer's PSK.
key_out = "/run/rosenpass/psk-client1"
EOF

# systemd tmpfiles directory for PSK output
install -d -m 700 /run/rosenpass
cat >/etc/tmpfiles.d/rosenpass.conf <<EOF
d /run/rosenpass 0700 root root - -
EOF

# ---------- systemd services ---------------------------------------------
log "Installing systemd units"
cat >/etc/systemd/system/cloak-rosenpass.service <<EOF
[Unit]
Description=Cloak VPN — Rosenpass post-quantum key-exchange daemon
After=network-online.target wg-quick@$WG_IFACE.service
Requires=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rosenpass exchange-config $ETC_RP/server.toml
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# If rosenpass is installed via apt, binary is at /usr/bin
if [[ -x /usr/bin/rosenpass ]]; then
  sed -i 's|/usr/local/bin/rosenpass|/usr/bin/rosenpass|' /etc/systemd/system/cloak-rosenpass.service
fi

# ---------- PSK installer (rosenpass → wg0 bridge) -----------------------
# The rosenpass daemon emits a fresh 32-byte PSK to /run/rosenpass/psk-<peer>
# every ~120s after a successful PQ key exchange — but rosenpass does NOT
# itself install that PSK into wg0. Without this watcher service the PQ
# handshake completes server-side but the new PSK never reaches the
# WireGuard interface, so after rotation #1 the server's wg PSK and the
# client's wg PSK diverge → all encrypted packets fail to decrypt → the
# tunnel silently goes black.
#
# The watcher is generic over peers: it derives the peer name from the
# psk-<name> filename and looks up the WG pubkey at /etc/wireguard/<name>.pub.
# Adding a new peer via add-peer.sh "just works" — no per-peer service.

log "Cleaning up any pre-generic per-peer psk-installer scripts (us-west-1 manual deployment)"
find /usr/local/bin -maxdepth 1 -name 'cloak-psk-installer-*.sh' -delete 2>/dev/null || true

log "Installing /usr/local/bin/cloak-psk-installer.sh"
cat >/usr/local/bin/cloak-psk-installer.sh <<'PSK_INSTALLER_EOF'
#!/usr/bin/env bash
# Cloak VPN — Post-quantum PSK installer.
# Watches /run/rosenpass/psk-<peer> via inotify, applies each new PSK to
# the matching wg peer via `wg set <iface> peer <pubkey> preshared-key
# <psk-file>`. Peer-name → WG pubkey lookup: /etc/wireguard/<peer>.pub.
# Generic over peers; install once per server. See repo's
# server/scripts/cloak-psk-installer.sh for the canonical (commented)
# version — this heredoc copy is kept in sync at deploy time.

set -euo pipefail

WG_IFACE="${WG_IFACE:-wg0}"
PSK_DIR="${PSK_DIR:-/run/rosenpass}"
PUBKEY_DIR="${PUBKEY_DIR:-/etc/wireguard}"

log() { printf "[psk-installer] %s\n" "$*"; }

apply_psk() {
  local psk_file="$1"
  local fname
  fname=$(basename "$psk_file")
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

log "scanning $PSK_DIR for existing PSK files"
shopt -s nullglob
for f in "$PSK_DIR"/psk-*; do
  apply_psk "$f" || true
done
shopt -u nullglob

log "watching $PSK_DIR for new PSK files"
exec inotifywait -m \
  -e close_write \
  -e moved_to \
  --format '%w%f' \
  "$PSK_DIR" \
  | while read -r path; do
      apply_psk "$path" || true
    done
PSK_INSTALLER_EOF
chmod 755 /usr/local/bin/cloak-psk-installer.sh

log "Installing /etc/systemd/system/cloak-psk-installer.service"
cat >/etc/systemd/system/cloak-psk-installer.service <<EOF
[Unit]
Description=Cloak VPN — PSK installer (rosenpass → wg$WG_IFACE bridge)
After=network-online.target wg-quick@$WG_IFACE.service cloak-rosenpass.service
Requires=wg-quick@$WG_IFACE.service
PartOf=cloak-rosenpass.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloak-psk-installer.sh
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ---------- UFW firewall --------------------------------------------------
log "Configuring UFW firewall (deny-by-default, forward wg0 → eth0)"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

# CRITICAL for a VPN gateway: flip default FORWARD policy to ACCEPT *before*
# enabling UFW. Without this, every packet from WG peers headed to the
# internet gets silently dropped at the FORWARD chain, even with NAT in place.
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

ufw allow OpenSSH
ufw allow $WG_PORT/udp  comment 'WireGuard'
ufw allow $RP_PORT/udp  comment 'Rosenpass PQ handshake'
# Explicitly allow WG peers to exit via the main interface.
ufw route allow in on "$WG_IFACE" out on "$ETH_IFACE"
ufw --force enable

# ---------- RAM-only /var/log --------------------------------------------
log "Switching /var/log to tmpfs (RAM-only, wiped on reboot)"
if ! grep -q '/var/log' /etc/fstab.cloak 2>/dev/null; then
  cp /etc/fstab /etc/fstab.cloak.bak 2>/dev/null || true
  if ! grep -qE '^[^#].*[[:space:]]/var/log[[:space:]]' /etc/fstab; then
    echo 'tmpfs /var/log tmpfs defaults,noatime,nodev,nosuid,size=256M 0 0' >>/etc/fstab
  fi
  touch /etc/fstab.cloak
  warn "Reboot required for /var/log tmpfs to take effect."
fi

# ---------- Start services ------------------------------------------------
log "Enabling and starting services"
systemctl daemon-reload

# If we're re-running setup.sh over a box that previously had the dual-listen
# bug, the rosenpass unit may be stuck in a deep crashloop with a huge
# restart counter. Clear that so `systemctl start` tries again cleanly.
systemctl reset-failed cloak-rosenpass.service 2>/dev/null || true

systemctl enable --now wg-quick@$WG_IFACE.service
systemctl enable --now cloak-rosenpass.service
# psk-installer is PartOf= cloak-rosenpass, so it'll come and go with the
# rosenpass daemon — but we still enable it explicitly so a manual
# `systemctl start cloak-psk-installer` works as expected.
systemctl enable --now cloak-psk-installer.service

sleep 2
systemctl --no-pager --full status wg-quick@$WG_IFACE.service     | head -n 12 || true
systemctl --no-pager --full status cloak-rosenpass.service        | head -n 12 || true
systemctl --no-pager --full status cloak-psk-installer.service    | head -n 12 || true

# ---------- Emit client config -------------------------------------------
RP_SERVER_PUB_FILE="$ETC_RP/server.rosenpass-public"
RP_SERVER_PUB_B64=$(base64 -w0 "$RP_SERVER_PUB_FILE")

cat <<EOF

=============================================================================
  Cloak VPN server is up.
=============================================================================

  Endpoint (WireGuard):  $PUBLIC_IP:$WG_PORT
  Endpoint (Rosenpass):  $PUBLIC_IP:$RP_PORT
  Server WG pubkey:      $WG_SERVER_PUB
  Server RP pubkey:      $ETC_RP/server.rosenpass-public  (base64 below)

----- CLIENT CONFIG (test client1) ------------------------------------------

[wireguard]
private_key = $WG_CLIENT_PRIV
address_v4  = $CLIENT_V4/32
address_v6  = $CLIENT_V6/128
dns         = 9.9.9.9, 2620:fe::fe

[wireguard.peer]
public_key = $WG_SERVER_PUB
endpoint   = $PUBLIC_IP:$WG_PORT
allowed_ips = 0.0.0.0/0, ::/0
persistent_keepalive = 25

[rosenpass]
server_public_key_b64 = $RP_SERVER_PUB_B64
server_endpoint       = $PUBLIC_IP:$RP_PORT
psk_rotation_seconds  = 120

### END_CLIENT_CONFIG ###
-----------------------------------------------------------------------------

  Next:
    1. Reboot once to activate RAM-only /var/log.
    2. On your phone, import the block above via the Cloak VPN app.
    3. Verify PSK rotation:  sudo wg show $WG_IFACE   (latest handshake should refresh every ~2min)

EOF
