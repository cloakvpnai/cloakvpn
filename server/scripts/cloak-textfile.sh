#!/usr/bin/env bash
# Lattice/Cloak VPN — node_exporter textfile collector for cloak-rpd / PQC.
# Installed on EACH fleet box, run every 30s by a systemd timer, writing
# /var/lib/node_exporter/textfile_collector/cloak.prom which node_exporter
# then exposes. These cloak_* metrics drive the fleet PQC alert rules.
#
# 2026-07-02: added per-peer PQC-state accounting (the two live signatures of
# the tombstone / stale-PSK incidents of 2026-07-01):
#   cloak_wg_active_peers            — peers with a wg handshake < 180s old
#   cloak_wg_active_nopsk_peers      — ACTIVE peers with NO preshared key set
#                                      (PQC never completed or never installed:
#                                      poisoned client / installer down / ADD
#                                      never drained). Excludes peers whose
#                                      allowed-ips appear in
#                                      /etc/cloakvpn/nopsk-allowlist (one CIDR
#                                      per line — e.g. the intentional Tokyo
#                                      plain-WG fallback peer).
#   cloak_wg_dialing_nohandshake_peers — peers with an endpoint set (a client
#                                      dialed us) whose wg handshake has NEVER
#                                      completed (epoch 0). The client-holds-a-
#                                      stale-PSK signature: initiations arrive,
#                                      responses are rejected, tunnel black.
set -u
OUT=/var/lib/node_exporter/textfile_collector/cloak.prom
T="${OUT}.$$"
now=$(date +%s)
active_int() { [ "$(systemctl is-active "$1" 2>/dev/null)" = active ] && echo 1 || echo 0; }
enabled_int() { [ "$(systemctl is-enabled "$1" 2>/dev/null)" = enabled ] && echo 1 || echo 0; }
rpd_up=$(active_int cloak-rpd)
rpd_en=$(enabled_int cloak-rpd)
inst_up=$(active_int cloak-psk-installer)
inst_en=$(enabled_int cloak-psk-installer)
restarts=$(systemctl show cloak-rpd -p NRestarts --value 2>/dev/null || echo 0)
sock=$([ -S /run/rosenpass/control.sock ] && echo 1 || echo 0)
rss=$(ps -o rss= -C cloak-rpd 2>/dev/null | awk '{s+=$1} END{print s+0}')
# PSK ages: oldest (worst peer — what the rotation alert should track) and
# newest (informational). Using "oldest" makes cloak_psk_max_age_seconds match
# its name and stops one actively-rotating peer from masking stale ones.
oldest=$(find /run/rosenpass -name 'psk-*' -printf '%T@\n' 2>/dev/null | sort -n | head -1 | cut -d. -f1)
newest=$(find /run/rosenpass -name 'psk-*' -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
if [ -n "$oldest" ]; then psk_age=$((now-oldest)); else psk_age=-1; fi
if [ -n "$newest" ]; then psk_newest_age=$((now-newest)); else psk_newest_age=-1; fi
# PSK accounting. Split into two cases so the alert only fires on real problems:
#   ORPHAN (actionable): a peer that is STILL configured in server.toml (rosenpass
#     is exchanging keys for it) but has no /etc/wireguard/<name>.pub, so
#     cloak-psk-installer can never apply it. >0 means the control-plane added a
#     peer without writing its WG pubkey file — that peer's PQC will not work.
#   RESIDUE (harmless): a psk-<name> left in tmpfs for a peer that is no longer in
#     server.toml and has no .pub (e.g. a client that connected then disconnected).
#     rosenpass doesn't reap its own output files; cloak-psk-reap.timer cleans these.
TOML=/etc/rosenpass/server.toml
orphans=0; residue=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  name=$(basename "$f"); name=${name#psk-}
  [ -f "/etc/wireguard/${name}.pub" ] && continue            # applied, fine
  if grep -qF "\"/run/rosenpass/psk-${name}\"" "$TOML" 2>/dev/null; then
    orphans=$((orphans+1))                                    # configured but no pub -> ACTIONABLE
  else
    residue=$((residue+1))                                    # unconfigured leftover -> harmless
  fi
done < <(find /run/rosenpass -name 'psk-*' 2>/dev/null)
peers=$(wg show wg0 peers 2>/dev/null | wc -l | tr -d ' ')
# Per-peer PQC state from one `wg show wg0 dump` pass (fields per peer line:
# pubkey, psk|(none), endpoint|(none), allowed-ips, handshake-epoch, rx, tx, ka).
ALLOW=/etc/cloakvpn/nopsk-allowlist
active=0; active_nopsk=0; dialing_nohs=0
while IFS=$'\t' read -r pub psk endp aips hs _rest; do
  [ -z "${pub:-}" ] && continue
  hs=${hs:-0}
  if [ "$hs" -gt 0 ] && [ $((now-hs)) -lt 180 ]; then
    active=$((active+1))
    if [ "$psk" = "(none)" ]; then
      if ! grep -qxF "$aips" "$ALLOW" 2>/dev/null; then
        active_nopsk=$((active_nopsk+1))
      fi
    fi
  fi
  if [ "$hs" -eq 0 ] && [ "$endp" != "(none)" ] && [ -n "${endp:-}" ]; then
    dialing_nohs=$((dialing_nohs+1))
  fi
done < <(wg show wg0 dump 2>/dev/null | tail -n +2)
{
  echo "# HELP cloak_rpd_up cloak-rpd systemd active (1) or not (0)"
  echo "# TYPE cloak_rpd_up gauge"
  echo "cloak_rpd_up ${rpd_up:-0}"
  echo "# HELP cloak_rpd_enabled cloak-rpd systemd enabled (1) or not (0)"
  echo "# TYPE cloak_rpd_enabled gauge"
  echo "cloak_rpd_enabled ${rpd_en:-0}"
  echo "# HELP cloak_rpd_restarts_total cloak-rpd systemd NRestarts"
  echo "# TYPE cloak_rpd_restarts_total counter"
  echo "cloak_rpd_restarts_total ${restarts:-0}"
  echo "# HELP cloak_psk_installer_up cloak-psk-installer active (1) or not (0)"
  echo "# TYPE cloak_psk_installer_up gauge"
  echo "cloak_psk_installer_up ${inst_up:-0}"
  echo "# HELP cloak_psk_installer_enabled cloak-psk-installer enabled (1) or not (0)"
  echo "# TYPE cloak_psk_installer_enabled gauge"
  echo "cloak_psk_installer_enabled ${inst_en:-0}"
  echo "# HELP cloak_rpd_control_socket control socket present (1) or not (0)"
  echo "# TYPE cloak_rpd_control_socket gauge"
  echo "cloak_rpd_control_socket ${sock:-0}"
  echo "# HELP cloak_rpd_rss_kb cloak-rpd resident memory in KB"
  echo "# TYPE cloak_rpd_rss_kb gauge"
  echo "cloak_rpd_rss_kb ${rss:-0}"
  echo "# HELP cloak_psk_max_age_seconds age of the OLDEST psk-* file = worst peer (-1 if none)"
  echo "# TYPE cloak_psk_max_age_seconds gauge"
  echo "cloak_psk_max_age_seconds ${psk_age:--1}"
  echo "# HELP cloak_psk_newest_age_seconds age of the newest psk-* file (-1 if none)"
  echo "# TYPE cloak_psk_newest_age_seconds gauge"
  echo "cloak_psk_newest_age_seconds ${psk_newest_age:--1}"
  echo "# HELP cloak_psk_orphaned_total CONFIGURED peers (in server.toml) missing /etc/wireguard/<name>.pub (installer can't apply — actionable)"
  echo "# TYPE cloak_psk_orphaned_total gauge"
  echo "cloak_psk_orphaned_total ${orphans:-0}"
  echo "# HELP cloak_psk_residue_total stale tmpfs psk-* for peers no longer in server.toml (harmless; reaped by cloak-psk-reap.timer)"
  echo "# TYPE cloak_psk_residue_total gauge"
  echo "cloak_psk_residue_total ${residue:-0}"
  echo "# HELP cloak_peers_total wg0 peer count"
  echo "# TYPE cloak_peers_total gauge"
  echo "cloak_peers_total ${peers:-0}"
  echo "# HELP cloak_wg_active_peers wg peers with a handshake newer than 180s"
  echo "# TYPE cloak_wg_active_peers gauge"
  echo "cloak_wg_active_peers ${active:-0}"
  echo "# HELP cloak_wg_active_nopsk_peers ACTIVE wg peers with no preshared key set (PQC missing; excludes /etc/cloakvpn/nopsk-allowlist)"
  echo "# TYPE cloak_wg_active_nopsk_peers gauge"
  echo "cloak_wg_active_nopsk_peers ${active_nopsk:-0}"
  echo "# HELP cloak_wg_dialing_nohandshake_peers peers with an endpoint recorded but a wg handshake that has NEVER completed (stale-client-PSK signature)"
  echo "# TYPE cloak_wg_dialing_nohandshake_peers gauge"
  echo "cloak_wg_dialing_nohandshake_peers ${dialing_nohs:-0}"
} > "$T" && mv "$T" "$OUT"
