# Cloak VPN — Continuous Monitoring & Observability Plan

**Purpose:** stand up continuous monitoring + a dashboard for the Cloak VPN fleet,
with alerting and Claude-assisted review, before scaling to thousands of users.
This doc is **self-contained** — it carries the context a fresh chat session needs,
so you can hand it to a new session without dragging along the build history.

---

## 0. Context a fresh session needs (read first)

**Product:** Cloak VPN = WireGuard data plane + Rosenpass post-quantum key exchange
(PQC) that derives a rotating WireGuard preshared key (PSK). iOS + Android clients.

**Fleet:** 10 Linux boxes (Debian trixie, mostly ~3.8 GB RAM / 2 vCPU), one per region.
SSH as `root@<ip>` (keys in `~/.ssh/config`).

| region | ip | notes |
|---|---|---|
| us-west-1 | 5.78.203.171 | ALSO runs the central `cloakvpn-api` (`127.0.0.1:8080`) + is the cloak-rpd build host (`/root/rp`) |
| us-east-1 | 5.161.198.227 | |
| de1 | 91.98.65.98 | |
| fi1 | 204.168.252.70 | |
| us-central-1 | 207.148.1.253 | |
| es1 | 65.20.99.121 | |
| mx1 | 216.238.95.21 | |
| za1 | 139.84.248.50 | |
| in1 | 65.20.77.179 | |
| jp1 | 167.179.75.10 | |

**Per-box services (systemd):**
- `cloak-rpd` — the Rosenpass daemon (custom, replaces upstream `cloak-rosenpass`).
  Listens UDP `:9999`. Adds/removes peers at runtime over a unix control socket
  `/run/rosenpass/control.sock` **without restarting** (this is the scale fix).
  Writes each peer's derived PSK to `/run/rosenpass/psk-<peerName>`.
- `cloak-psk-installer` — watches `/run/rosenpass/psk-*` and installs each PSK onto
  the matching `wg0` peer (`/etc/wireguard/<peerName>.pub`). **If this dies, the
  tunnel comes up but carries NO traffic** (the exact outage seen 2026-05-30).
- `regionsvc` — per-region provisioning HTTP service (`127.0.0.1:8090`); the central
  API calls it to add/revoke peers. Now socket-aware (ADDs to cloak-rpd, no restart).
- `wg-quick@wg0` — WireGuard interface.
- (`cloak-rosenpass` is retired: its unit is moved to
  `/etc/systemd/system/cloak-rosenpass.service.disabled-by-cloak-rpd`.)
- us-west-1 only: `cloakvpn-api` (central account/provisioning API; has `/healthz`-style
  behavior — `GET /v1/account` returns 401 without auth, useful as a liveness probe).

**Incidents this drove (these define the must-have alerts):**
1. `cloak-rosenpass` restart-on-every-peer-change dropped all peers' PQC for ~2-5s →
   fixed by `cloak-rpd` (no restart). Alert: **any cloak-rpd restart**.
2. `cloak-psk-installer` was `PartOf=cloak-rosenpass`; the migration stopped it → PQC
   PSKs never reached wg0 → "VPN on, no internet." Alert: **psk-installer down** and
   **stale PSKs while peers are connected**.
3. `cloak-rpd` shipped `disabled` (wouldn't survive reboot). Alert: **service not
   enabled / not active**.
4. iOS clients could enter a poisoned-PQC state needing reinstall (a client self-heal
   is committed but unshipped). Server signal: a peer with WG handshakes but **0
   rosenpass exchanges**.

**Capacity facts measured:** cloak-rpd uses ~**0.5 MB RAM per peer** (Classic McEliece
public key ≈ 524 KB dominates). On a 3.8 GB box that's a soft ceiling around
**~3,000–4,000 peers/box** before memory pressure. CPU (2 vCPU, McEliece is heavy) is
the other likely bottleneck under churn — unproven, needs load test.

---

## 1. What to monitor (the four areas you named + the glue)

1. **Rosenpass / cloak-rpd crypto health** — process up + enabled, restart count
   (target: 0), control socket present, peer count, RSS (capacity), control-socket
   ADD error rate.
2. **PQC rotation health** — freshness of `/run/rosenpass/psk-*` (max age per box),
   rotation rate (installer "PSK rotated" events/min), `cloak-psk-installer` up +
   install errors ("no WG pubkey … skipping" = orphaned peers), per-peer "last
   successful exchange" age.
3. **VM / server health** — CPU, load avg, RAM (and RAM-headroom vs the 0.5 MB/peer
   model), disk %, network throughput, reachability, time sync.
4. **User connections to the VMs** — wg0 peer count, *active* peers (handshake < ~3 min),
   per-region rx/tx throughput, handshake success rate, % of peers with a PSK set.
5. **Glue/control plane** — `cloakvpn-api` liveness + provision latency/error rate,
   `regionsvc` health on each box, end-to-end "can a client actually connect" probe.

---

## 2. Recommended stack (opinionated)

**Backbone: Prometheus + Grafana + Alertmanager.** Industry standard, pull-based,
great for a fixed fleet, huge exporter ecosystem, and a Cowork/Claude artifact can
read it over HTTP. Run it on a **separate small monitoring VM** (not a region box) so
monitoring survives a region outage.

Per-box agents:
- **node_exporter** — all VM health (CPU/RAM/disk/load/net/time). (built-in textfile
  collector is how we add custom metrics — see below.)
- **prometheus-wireguard-exporter** (or a textfile script parsing `wg show wg0 dump`)
  — per-peer handshake age, rx/tx, endpoint, peer count, PSK-present count.
- **A small custom textfile collector** (`/var/lib/node_exporter/textfile/cloak.prom`,
  refreshed by a 30 s systemd timer) for the cloak-rpd/PQC specifics node_exporter and
  wg_exporter don't cover (restart count, control-socket presence, psk file ages,
  installer up, rotation rate). Sketch in the Appendix.
- **blackbox_exporter** (on the monitoring VM) — probe each region's WG UDP port and
  `cloakvpn-api`/`regionsvc` health endpoints; synthetic reachability.

Alerting: **Alertmanager** → email + (recommended) Slack/Discord webhook, and
**PagerDuty/Opsgenie** if you want real on-call escalation.

**Managed alternative (recommended to start fast):** **Grafana Cloud free tier** —
hosted Prometheus + Grafana + Alertmanager; you just run the agents on the boxes and
remote-write to it. Removes the "who monitors the monitor" problem and the monitoring-VM
upkeep. (Verify current free-tier limits before relying on them.)

---

## 3. Metrics catalog (what + how)

| Metric | Source | Alert threshold |
|---|---|---|
| `cloak-rpd` active & enabled | node_exporter `node_systemd_unit_state` | not active OR not enabled |
| **cloak-rpd restarts** | systemd `NRestarts` via textfile | `increase > 0` over 10m → page |
| control socket present | textfile (`test -S /run/rosenpass/control.sock`) | missing while cloak-rpd up |
| cloak-rpd RSS / peer count | textfile (`ps`, `wg show`/server.toml) | RSS > 70% RAM, or peers > 3000 |
| **cloak-psk-installer active** | node_exporter systemd state | not active → page (causes no-traffic) |
| max PSK file age | textfile (`find /run/rosenpass -name 'psk-*' -printf '%T@'`) | > 300 s while active peers > 0 |
| PSK rotation rate | Loki/log count of "PSK rotated" OR textfile counter | drops to ~0 while peers connected |
| installer "no WG pubkey skipping" | log count | rising → orphaned peers (cleanup) |
| wg0 peer count / active peers | wg_exporter | (capacity + usage trend) |
| wg handshake age per peer | wg_exporter | (compute % active) |
| wg rx/tx per peer/region | wg_exporter | (throughput dashboards) |
| VM cpu/load/mem/disk/net | node_exporter | disk>85%, mem>85%, load>cores×2 |
| box reachable | blackbox/up | `up==0` 2m → page |
| `cloakvpn-api` live | blackbox HTTP (expect 401 on `/v1/account`) | down 2m → page |
| provision latency/errors | cloakvpn-api logs → Loki, or add Prom metrics to the API | p95 > 6 s, or 5xx rate |

---

## 4. Alerting — the "today would have caught it" set (do these first)
- `cloak-psk-installer` down on any box → **critical** (this caused the no-internet outage).
- Any `cloak-rpd` restart → **critical** (zero-restart is the scale guarantee).
- `cloak-rpd` or `cloak-psk-installer` not `enabled` → warning (won't survive reboot).
- Max PSK file age > 300 s on a box with ≥1 active wg peer → critical (PQC stalled).
- Box unreachable / `cloakvpn-api` down → critical.
- Memory > 85% or projected peers × 0.5 MB approaching RAM → warning (capacity).
- Disk > 85% → warning.

## 5. Dashboards (Grafana)
- **Fleet overview:** 10-box grid — cloak-rpd up/restarts, psk-installer up, active
  peers, CPU/mem/disk, max PSK age. Red/green at a glance.
- **PQC health:** rotation rate per region, max PSK age, exchange errors, installer
  skip-count (orphans).
- **Capacity/headroom:** peers/box vs the ~3–4k ceiling, RSS vs RAM, CPU under churn.
- **Connections:** active peers per region, rx/tx throughput, handshake success %.
- **Control plane:** provision rate/latency/errors, regionsvc health.

## 6. Claude-assisted monitoring (Cowork)
Two complementary patterns:
- **Scheduled task (works today, no infra):** a Cowork scheduled task (e.g., every
  15 min, or each morning) that SSHes the fleet, runs the health collection (Appendix
  A), and posts a plain-English summary flagging anything off (restarts, installer
  down, stale PSKs, capacity). This is the fastest path to "Claude watches it for me"
  and needs zero Prometheus. Start here.
- **Live artifact dashboard:** a Cowork `create_artifact` HTML page that fetches metrics
  and renders a live fleet view, using `window.cowork.askClaude(...)` to summarize
  anomalies in words. **Caveat:** an artifact runs in the browser and can only reach
  HTTP endpoints/connectors — it cannot SSH boxes. So it needs a data source it *can*
  reach: either Grafana Cloud's HTTP API (with a read token), a tiny read-only
  metrics-gateway endpoint, or have the scheduled task write a JSON summary to a place
  the artifact can fetch. Decide the data path before building the artifact.

Recommended: scheduled-task summaries now → Grafana (self-host or Cloud) for real
dashboards/alerts → optional Claude artifact reading Grafana's API for a chat-native view.

## 7. Other tools worth considering (with honest tradeoffs)
- **Netdata** — dead-simple per-box, real-time, auto-discovers a lot; great for
  immediate visibility/triage. Weaker at long-term fleet aggregation than Prometheus.
  (Good Phase-0 companion.)
- **Grafana Cloud** — managed Prom+Grafana+Alertmanager+Loki; least ops overhead.
- **Loki + (Promtail/Alloy/Vector)** — ship the `cloak-rpd`/`cloak-psk-installer`/
  `regionsvc`/`cloakvpn-api` logs centrally so you can alert on log patterns ("PSK
  rotated" rate, "skipping", provision 5xx) and grep across the fleet in one place.
- **Uptime Kuma** — simple self-hosted uptime + public status page; nice for
  customer-facing status and basic endpoint checks.
- **Healthchecks.io / Better Stack heartbeats** — dead-man's-switch: have each box
  ping a heartbeat each minute; if a box goes silent you get paged (catches "box fell
  off the net" that pull-based scraping also catches, but cheap/independent).
- **PagerDuty / Opsgenie** — real on-call escalation if/when you have users to wake up for.
- **smokeping / blackbox** — latency/loss to each region endpoint over time.
Minimal recommended path: **Grafana Cloud + node_exporter + wg_exporter + the custom
textfile collector + Loki**, with a **Cowork scheduled-task summary** layered on top.

## 8. Load testing (answers "stable under load?" before real users)
Monitoring tells you the *current* state; a load test proves the *ceiling*.
- Simulate peers: script N `rosenpass exchange-config` initiator clients (the same
  binary already on the build box) against one region's `cloak-rpd`, each with its own
  keypair, provisioned via the control socket, rotating on the normal cadence.
- Ramp 500 → 1k → 2k → 4k peers on one box; watch (via the same dashboards) cloak-rpd
  RSS + CPU, PSK rotation latency, psk-installer keep-up (`wg set` rate), handshake
  success, and box load. Find the knee.
- Validate the ~0.5 MB/peer memory model and the ~3–4k/box estimate; decide RAM/CPU
  sizing and per-region sharding before launch.

## 9. Phased implementation plan (for the next session)
- **Phase 0 (hours):** Cowork scheduled task running Appendix A across the fleet,
  posting a health summary + flagging the Section-4 conditions. Immediate "Claude is
  watching it."
- **Phase 1 (1–2 days):** Grafana Cloud (or a monitoring VM) + node_exporter on all
  10 boxes + wg_exporter + the custom textfile collector. Fleet overview + PQC + VM
  dashboards. Wire the Section-4 alerts to email/Slack.
- **Phase 2:** Loki log shipping; provision-latency metrics in `cloakvpn-api`;
  blackbox reachability + synthetic connect probe; status page (Uptime Kuma).
- **Phase 3:** load test (Section 8); capacity-plan + right-size busy regions; SLOs
  (PQC rotation success %, connect success %) + error-budget alerts; optional Claude
  live-artifact dashboard reading Grafana's API.

---

## Appendix A — fleet health one-shot (Phase-0 collector / scheduled-task body)
Run from a host with SSH to the fleet. Emits one line per box; a Cowork scheduled task
can run this and have Claude summarize/flag.
```bash
#!/usr/bin/env bash
BOXES="5.78.203.171 5.161.198.227 91.98.65.98 204.168.252.70 207.148.1.253 \
       65.20.99.121 216.238.95.21 139.84.248.50 65.20.77.179 167.179.75.10"
for ip in $BOXES; do
  ssh -o BatchMode=yes -o ConnectTimeout=8 root@$ip '
    now=$(date +%s)
    rpd=$(systemctl is-active cloak-rpd); rpd_en=$(systemctl is-enabled cloak-rpd 2>/dev/null)
    restarts=$(systemctl show cloak-rpd -p NRestarts --value)
    inst=$(systemctl is-active cloak-psk-installer); inst_en=$(systemctl is-enabled cloak-psk-installer 2>/dev/null)
    sock=$([ -S /run/rosenpass/control.sock ] && echo yes || echo NO)
    rss=$(ps -o rss= -C cloak-rpd 2>/dev/null | tr -d " ")
    newest=$(find /run/rosenpass -name "psk-*" -printf "%T@\n" 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
    pskage=$([ -n "$newest" ] && echo $((now-newest)) || echo NA)
    active=$(wg show wg0 latest-handshakes 2>/dev/null | awk -v n=$now "{if(\$2>0 && n-\$2<180) c++} END{print c+0}")
    mem=$(free -m | awk "/Mem:/{printf \"%d/%dMB\", \$3,\$2}")
    disk=$(df -h / | awk "NR==2{print \$5}")
    echo "rpd=$rpd/$rpd_en restarts=$restarts inst=$inst/$inst_en sock=$sock rss_kb=${rss:-0} psk_age=${pskage}s active_peers=$active mem=$mem disk=$disk"
  ' 2>&1 | sed "s|^|$ip |"
done
```
Flag if: `rpd != active/enabled`, `restarts` rising, `inst != active/enabled`, `sock=NO`,
`psk_age > 300` with `active_peers > 0`, `mem` near full, `disk` > 85%.

## Appendix B — custom textfile collector (Prometheus, per box)
`/usr/local/bin/cloak-textfile.sh`, run by a 30 s systemd timer, writing
`/var/lib/node_exporter/textfile_collector/cloak.prom`:
```bash
#!/usr/bin/env bash
OUT=/var/lib/node_exporter/textfile_collector/cloak.prom; T=${OUT}.$$
now=$(date +%s)
restarts=$(systemctl show cloak-rpd -p NRestarts --value 2>/dev/null || echo 0)
rpd_up=$([ "$(systemctl is-active cloak-rpd)" = active ] && echo 1 || echo 0)
inst_up=$([ "$(systemctl is-active cloak-psk-installer)" = active ] && echo 1 || echo 0)
sock=$([ -S /run/rosenpass/control.sock ] && echo 1 || echo 0)
rss=$(ps -o rss= -C cloak-rpd 2>/dev/null | tr -d " "); rss=${rss:-0}
newest=$(find /run/rosenpass -name "psk-*" -printf "%T@\n" 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
pskage=$([ -n "$newest" ] && echo $((now-newest)) || echo -1)
peers=$(grep -c public_key /etc/rosenpass/server.toml 2>/dev/null || echo 0)
{
  echo "cloak_rpd_up $rpd_up"
  echo "cloak_rpd_restarts_total $restarts"
  echo "cloak_psk_installer_up $inst_up"
  echo "cloak_rpd_control_socket $sock"
  echo "cloak_rpd_rss_kb $rss"
  echo "cloak_psk_max_age_seconds $pskage"
  echo "cloak_peers_total $peers"
} > "$T" && mv "$T" "$OUT"
```
Then alert in Prometheus, e.g.:
`cloak_psk_installer_up == 0`, `increase(cloak_rpd_restarts_total[10m]) > 0`,
`cloak_psk_max_age_seconds > 300 and cloak_peers_total > 0`, `cloak_rpd_up == 0`.

---

*Source context: this fleet currently runs cloak-rpd on all 10 boxes (zero-restart peer
mgmt) as of 2026-05-30. See `docs/ROSENPASS_NO_RESTART_PEER_MGMT.md` and
`SESSION_HANDOVER_2026-05-30_pqc-poisoned-state-and-scale.md` for how it got here.*
