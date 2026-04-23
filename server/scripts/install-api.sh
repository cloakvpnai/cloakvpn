#!/usr/bin/env bash
# install-api.sh — idempotent installer for cloakvpn-api on a concentrator.
#
# Called from deploy.sh (infra/) after setup.sh has WG + rosenpass running.
# Expects the binary to already be at /tmp/cloakvpn-api (scp'd in by
# deploy.sh — we don't build on the concentrator because CX23 is RAM-tight
# and the Mac cross-compile is faster anyway).
#
# What it does:
#   1. Installs /usr/local/bin/cloakvpn-api
#   2. Installs /etc/systemd/system/cloakvpn-api.service
#   3. Creates /etc/cloakvpn (for api.env) and /var/lib/cloakvpn (for the DB)
#   4. daemon-reload + enable (but does NOT start until /etc/cloakvpn/api.env
#      exists; the unit's ConditionPathExists gates that).
#
# Safe to re-run: every step is idempotent.

set -euo pipefail

log() { printf "\033[1;34m[install-api]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[err]\033[0m %s\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."

BIN_SRC="${1:-/tmp/cloakvpn-api}"
UNIT_SRC="${2:-/root/cloakvpn/server/systemd/cloakvpn-api.service}"

[[ -f "$BIN_SRC"  ]] || die "Binary not found at $BIN_SRC — did deploy.sh scp it?"
[[ -f "$UNIT_SRC" ]] || die "Unit file not found at $UNIT_SRC — is server/ rsynced?"

log "installing binary → /usr/local/bin/cloakvpn-api"
install -m 0755 -o root -g root "$BIN_SRC" /usr/local/bin/cloakvpn-api

log "installing systemd unit"
install -m 0644 -o root -g root "$UNIT_SRC" /etc/systemd/system/cloakvpn-api.service

log "creating runtime dirs"
# /etc/cloakvpn holds api.env (0600, operator populates manually after
# Stripe setup — see docs/STRIPE_SETUP.md).
install -d -m 0700 -o root -g root /etc/cloakvpn
# /var/lib/cloakvpn holds the sqlite DB (accounts, devices). 0700 because
# the DB contains Stripe customer IDs we don't want other local users reading.
install -d -m 0700 -o root -g root /var/lib/cloakvpn

log "systemctl daemon-reload + enable"
systemctl daemon-reload
systemctl enable cloakvpn-api.service

# If api.env already exists, try starting. If it doesn't, the
# ConditionPathExists in the unit will keep us inactive — surface that
# as a note instead of a failure.
if [[ -f /etc/cloakvpn/api.env ]]; then
  log "api.env found — starting (or restarting) cloakvpn-api"
  # reset-failed in case a previous run crash-looped on missing env vars.
  systemctl reset-failed cloakvpn-api.service 2>/dev/null || true
  systemctl restart cloakvpn-api.service
  sleep 1
  systemctl --no-pager --full status cloakvpn-api.service | head -n 12 || true
else
  cat <<'EOF'

┌─ cloakvpn-api installed but NOT started ─────────────────────────────
│
│  /etc/cloakvpn/api.env is missing. The unit is enabled but the
│  ConditionPathExists gate will keep it inactive until you create it.
│
│  Next step: follow docs/STRIPE_SETUP.md sections 1-5 to create the
│  Stripe products + webhook, then populate /etc/cloakvpn/api.env on
│  this box (0600 root:root). After that:
│
│    systemctl start cloakvpn-api.service
│    systemctl status cloakvpn-api.service
│
└──────────────────────────────────────────────────────────────────────

EOF
fi
