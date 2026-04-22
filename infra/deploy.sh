#!/usr/bin/env bash
# Cloak VPN — end-to-end deploy runner (region-aware).
#
# Usage:
#   ./deploy.sh              # deploys the default region (fi1)
#   ./deploy.sh de1          # deploys the de1 region
#   make -C infra deploy REGION=de1
#
# What it does (in order):
#   1. terraform init + apply on regions/<region>/ — creates/updates the box.
#   2. Waits for SSH to come up.
#   3. rsyncs server/ to /root/cloakvpn/ on the box.
#   4. Runs server/scripts/setup.sh remotely; tees output to out/<region>/setup.log.
#   5. Extracts the client INI into out/<region>/client.conf.ini.
#   6. Reboots (to activate tmpfs /var/log), re-checks services.
#
# Safe to re-run: terraform is idempotent, setup.sh is idempotent, rsync is
# --delete-free so manual edits on the box survive.

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# ---------- Region selection ---------------------------------------------
REGION="${1:-fi1}"
TF_DIR="$SCRIPT_DIR/terraform/regions/$REGION"
OUT_DIR="$SCRIPT_DIR/out/$REGION"
mkdir -p "$OUT_DIR"

color()  { printf "\033[1;34m[deploy:%s]\033[0m %s\n" "$REGION" "$*"; }
warn()   { printf "\033[1;33m[warn:%s]\033[0m %s\n" "$REGION" "$*" >&2; }
die()    { printf "\033[1;31m[err:%s]\033[0m %s\n" "$REGION" "$*" >&2; exit 1; }

# ---------- Preflight -----------------------------------------------------
command -v terraform >/dev/null || die "terraform not found. Install from https://developer.hashicorp.com/terraform/install"
command -v rsync     >/dev/null || die "rsync not found."
command -v ssh       >/dev/null || die "ssh not found."

[[ -d "$TF_DIR" ]] || die "Region '$REGION' not found at $TF_DIR. Available: $(ls -1 "$SCRIPT_DIR/terraform/regions" 2>/dev/null | tr '\n' ' ')"
[[ -f "$TF_DIR/terraform.tfvars" ]] || die "Missing $TF_DIR/terraform.tfvars (copy terraform.tfvars.example and edit)."

color "deploying region $REGION from $TF_DIR"

# ---------- Terraform -----------------------------------------------------
color "terraform init"
terraform -chdir="$TF_DIR" init -input=false -upgrade >/dev/null

color "terraform apply"
terraform -chdir="$TF_DIR" apply -input=false -auto-approve

IPV4=$(terraform -chdir="$TF_DIR" output -raw ipv4)
IPV6=$(terraform -chdir="$TF_DIR" output -raw ipv6 || true)
NAME=$(terraform -chdir="$TF_DIR" output -raw server_name)

SSH_KEY_PATH=$(awk -F'=' '/^ssh_public_key_path/{gsub(/[" ]/,"",$2); print $2}' "$TF_DIR/terraform.tfvars")
# Fallback to the module/variable default if tfvars doesn't override it.
: "${SSH_KEY_PATH:=~/.ssh/cloakvpn_ed25519.pub}"
# Expand ~ and drop the trailing `.pub` to get the private key path.
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
SSH_PRIV="${SSH_KEY_PATH%.pub}"
[[ -f "$SSH_PRIV" ]] || die "Private key $SSH_PRIV not found."

SSH_OPTS=(-i "$SSH_PRIV" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$OUT_DIR/known_hosts" -o ConnectTimeout=10)

# rsync's -e flag splits on whitespace (not shell-parsed), so paths with
# spaces break both string-join and `printf %q` escaping. Robust fix:
# write a tiny SSH wrapper to a space-free /tmp path and point -e at it.
SSH_WRAPPER=$(mktemp -t cloak-ssh.XXXXXX)
trap 'rm -f "$SSH_WRAPPER"' EXIT
cat > "$SSH_WRAPPER" <<WRAPPER
#!/usr/bin/env bash
exec ssh -i "$SSH_PRIV" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$OUT_DIR/known_hosts" -o ConnectTimeout=10 "\$@"
WRAPPER
chmod +x "$SSH_WRAPPER"

color "waiting for SSH on $IPV4 (name=$NAME)…"
for i in {1..60}; do
  if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@$IPV4" true 2>/dev/null; then
    color "SSH is up (took ${i}x5s)"
    break
  fi
  sleep 5
  [[ $i -eq 60 ]] && die "SSH never came up after 5 minutes."
done

# ---------- Wait for cloud-init ------------------------------------------
# cloud-init runs `package_update: true` + `package_upgrade: true` on first
# boot, which holds /var/lib/dpkg/lock-frontend for 1-3 minutes. If setup.sh
# starts before that releases, apt-get inside setup.sh fails with
# "Could not get lock /var/lib/dpkg/lock-frontend". Block until cloud-init
# reports `status: done`; a kernel upgrade can also trigger a reboot, so
# re-wait for SSH afterward if we lose the connection mid-wait.
color "waiting for cloud-init to finish on the box (apt-lock contention otherwise)…"
if ! ssh "${SSH_OPTS[@]}" "root@$IPV4" "cloud-init status --wait" 2>/dev/null; then
  # SSH dropped — probably a cloud-init-triggered reboot. Poll until back.
  color "lost SSH during cloud-init wait (likely kernel-upgrade reboot) — re-polling…"
  for i in {1..60}; do
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@$IPV4" "cloud-init status" 2>/dev/null | grep -q "status: done"; then
      color "cloud-init done (after reboot, took ${i}x5s)"
      break
    fi
    sleep 5
    [[ $i -eq 60 ]] && die "cloud-init never reported done after 5 minutes."
  done
fi

# ---------- Push repo ----------------------------------------------------
color "ensuring /root/cloakvpn/ exists on the box"
ssh "${SSH_OPTS[@]}" "root@$IPV4" "mkdir -p /root/cloakvpn/server"

color "rsync server/ → root@$IPV4:/root/cloakvpn/"
rsync -azP --delete \
  -e "$SSH_WRAPPER" \
  --exclude '.git' --exclude 'infra/out' \
  "$REPO_ROOT/server/" "root@$IPV4:/root/cloakvpn/server/"

# ---------- Run setup.sh -------------------------------------------------
color "running setup.sh on the box (output tee'd to $OUT_DIR/setup.log)"
ssh "${SSH_OPTS[@]}" "root@$IPV4" "chmod +x /root/cloakvpn/server/scripts/*.sh && /root/cloakvpn/server/scripts/setup.sh" \
  | tee "$OUT_DIR/setup.log"

# Extract the client INI block using a unique end-marker emitted by setup.sh.
# (Previously used a 77-dash line, which can appear in unrelated output like
# cargo's build logs, causing the extraction to over-match to EOF.)
awk '/^----- CLIENT CONFIG/{flag=1} flag{print} /^### END_CLIENT_CONFIG ###$/{exit}' \
  "$OUT_DIR/setup.log" > "$OUT_DIR/client.conf.ini" || true

# Also write a standard WireGuard .conf for pasting into the official WG app
# (classical tunnel only — no Rosenpass until the Cloak app is built).
CLIENT_PRIV=$(awk -F' = ' '/^private_key/{print $2; exit}' "$OUT_DIR/client.conf.ini")
SERVER_PUB=$(awk -F' = ' '/^public_key/{print $2; exit}'  "$OUT_DIR/client.conf.ini")
if [[ -n "${CLIENT_PRIV:-}" && -n "${SERVER_PUB:-}" ]]; then
  cat > "$OUT_DIR/cloak-$NAME-smoketest.conf" <<WG
# Cloak VPN — $NAME smoke-test config (classical WireGuard only).
# Paste into the official WireGuard macOS/iOS app to prove end-to-end routing.
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.99.0.2/32, fd42:99::2/128
DNS = 9.9.9.9, 2620:fe::fe

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $IPV4:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
WG
fi

# ---------- Reboot for tmpfs activation ----------------------------------
color "rebooting (tmpfs /var/log needs it) — will wait for it to come back"
ssh "${SSH_OPTS[@]}" "root@$IPV4" "systemctl reboot" || true
sleep 15
for i in {1..60}; do
  if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "root@$IPV4" true 2>/dev/null; then
    color "box is back (took ${i}x5s)"
    break
  fi
  sleep 5
done

color "post-reboot service check:"
ssh "${SSH_OPTS[@]}" "root@$IPV4" "systemctl is-active wg-quick@wg0.service cloak-rosenpass.service; wg show wg0 | head -n 15" || true

# ---------- Done ---------------------------------------------------------
cat <<EOF

=============================================================================
  ✓ Cloak concentrator deployed — region $REGION ($NAME).

  IPv4:   $IPV4
  IPv6:   $IPV6
  SSH:    ssh -i $SSH_PRIV root@$IPV4

  Client configs (test peer):
    $OUT_DIR/client.conf.ini           (Cloak app format, includes Rosenpass)
    $OUT_DIR/cloak-$NAME-smoketest.conf (standard WireGuard format)

  DNS to add in Cloudflare:
    $REGION.cloakvpn.ai   A     $IPV4
    $REGION.cloakvpn.ai   AAAA  $IPV6
    (Proxy status: DNS only / grey cloud — WireGuard is UDP, unproxyable.)

  Smoke test:
    1. Import $OUT_DIR/cloak-$NAME-smoketest.conf into the WireGuard app.
    2. Activate. Visit https://www.cloudflare.com/cdn-cgi/trace ; 'ip=' should
       match $IPV4 (or the IPv6) and 'loc=' should match the server's country.
    3. On the server: \`sudo wg show wg0\` — 'latest handshake' should refresh
       every ~2min, 'transfer' should increment as you browse.
EOF
