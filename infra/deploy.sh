#!/usr/bin/env bash
# Cloak VPN — end-to-end deploy runner.
#
# Usage:
#   make -C infra deploy          # (preferred, from repo root)
#   cd infra && ./deploy.sh       # (direct)
#
# What it does (in order):
#   1. terraform apply — creates/updates the Hetzner server.
#   2. Waits for SSH to come up on the new box.
#   3. rsync's server/scripts/ to /root/cloakvpn/ on the box.
#   4. Runs server/scripts/setup.sh remotely under `script -q` so the client
#      config block is captured locally at infra/out/client.conf.ini.
#   5. Reboots (to activate the tmpfs /var/log mount) and re-checks services.
#
# Safe to re-run: terraform is idempotent, setup.sh is idempotent, rsync is
# --delete-free so manual edits on the box survive.
#
# Requires on your workstation:
#   - terraform (1.6+)
#   - rsync, ssh, awk, sed (any Unix)
#   - An SSH key at the path set in terraform.tfvars

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TF_DIR="$SCRIPT_DIR/terraform"
OUT_DIR="$SCRIPT_DIR/out"
mkdir -p "$OUT_DIR"

color()  { printf "\033[1;34m[deploy]\033[0m %s\n" "$*"; }
warn()   { printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }
die()    { printf "\033[1;31m[err]\033[0m %s\n" "$*" >&2; exit 1; }

# ---------- Preflight -----------------------------------------------------
command -v terraform >/dev/null || die "terraform not found. Install from https://developer.hashicorp.com/terraform/install"
command -v rsync     >/dev/null || die "rsync not found."
command -v ssh       >/dev/null || die "ssh not found."

[[ -f "$TF_DIR/terraform.tfvars" ]] || die "Missing $TF_DIR/terraform.tfvars (copy terraform.tfvars.example and edit)."

# ---------- Terraform -----------------------------------------------------
color "terraform init"
terraform -chdir="$TF_DIR" init -input=false -upgrade >/dev/null

color "terraform apply"
terraform -chdir="$TF_DIR" apply -input=false -auto-approve

IPV4=$(terraform -chdir="$TF_DIR" output -raw ipv4)
IPV6=$(terraform -chdir="$TF_DIR" output -raw ipv6 || true)
NAME=$(terraform -chdir="$TF_DIR" output -raw server_name)

SSH_KEY_PATH=$(awk -F'=' '/^ssh_public_key_path/{gsub(/[" ]/,"",$2); print $2}' "$TF_DIR/terraform.tfvars")
# Expand ~ and drop the trailing `.pub` to get the private key path.
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
SSH_PRIV="${SSH_KEY_PATH%.pub}"
[[ -f "$SSH_PRIV" ]] || die "Private key $SSH_PRIV not found."

SSH_OPTS=(-i "$SSH_PRIV" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$OUT_DIR/known_hosts" -o ConnectTimeout=10)

# rsync's -e flag takes a single string that it splits on whitespace (NOT
# shell-parsed), so neither naive joining nor `printf %q` escaping survives
# when any path contains spaces (e.g. repo under "Cloak VPN App"). The robust
# fix: write a tiny SSH wrapper script to a space-free path in /tmp and point
# rsync -e at that single file. The wrapper embeds all paths safely via normal
# double-quote semantics.
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

# Extract the client config block from setup.log into its own file.
awk '/^----- CLIENT CONFIG/,/^-----------------------------------------------------------------------------$/' \
  "$OUT_DIR/setup.log" > "$OUT_DIR/client.conf.ini" || true

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
  ✓ Cloak concentrator deployed.

  Name:   $NAME
  IPv4:   $IPV4
  IPv6:   $IPV6
  SSH:    ssh -i $SSH_PRIV root@$IPV4

  Client config for test peer written to:
    $OUT_DIR/client.conf.ini

  DNS (do this in Cloudflare):
    fi1.cloakvpn.ai   A     $IPV4
    fi1.cloakvpn.ai   AAAA  $IPV6

  Smoke test from your laptop:
    1. Paste $OUT_DIR/client.conf.ini into the Cloak VPN app.
    2. Connect. Visit https://www.cloudflare.com/cdn-cgi/trace and verify 'ip='
       matches $IPV4.
    3. On the server: \`sudo wg show wg0\` — the 'latest handshake' line should
       refresh every ~2min, and the 'transfer' should increment as you browse.
EOF
