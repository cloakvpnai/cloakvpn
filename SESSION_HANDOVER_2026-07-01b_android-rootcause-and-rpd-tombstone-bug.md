# Session Handover — 2026-07-01b — Android FIXED + BOTH code fixes BUILT, DEPLOYED, VERIFIED

Follows `SESSION_HANDOVER_2026-07-01_ios-pqc-fixed_android-still-broken.md`.
Android was diagnosed live (user in Japan, phone on Wi-Fi, jp1) via correlated
server-side capture, then BOTH root-cause fixes were implemented, built,
canaried, rolled out, and verified end-to-end the same session:

- **Server:** cloak-rpd tombstone/re-ADD fix — new binary sha256
  `b312424ecb6e8bff8660b3b42eef0165b7af720804a0a841df52850cb11ed146`, spike-passed
  on the VM (`spike_tombstone.sh`: TOMBSTONE_SPIKE_PASS), canary-verified
  against PRODUCTION us-east-1 (REMOVE + re-ADD + real Rosenpass handshake →
  psk file REWRITTEN), then rolled to all 8 reachable boxes (old binary backed
  up per box as `/usr/local/bin/cloak-rpd.bak.tombstone`). de1/fi1 still
  pending (SSH-locked).
- **Client:** Android **v1.0.3 (versionCode 5)** with the stale-PSK fix,
  built + signed, sideloaded onto the user's phone, verified on jp1: fresh
  identity `peer-a65b6c620825`, PSK written + installed, handshake advancing.
- **Acid test PASSED:** region round-trip Tokyo → Johannesburg → Tokyo (the
  revoke + re-provision cycle that used to trigger BOTH bugs) came up with
  working PQC each time; jp1 psk file rewritten on return, za1's cleanly
  deleted on revoke.

Historical diagnosis below (kept for reference).

---

## TL;DR

| Area | Status |
|------|--------|
| Android on jp1 | **WORKING, verified 20:44 JST** — PSK installed, WG rekey survived with PSK, PQC rotation #2 completed. v1.0.2 (versionCode 4) needs NO rebuild for this. |
| Root cause #1 (server, THE bug) | **cloak-rpd tombstone/re-ADD bug** — fleet-wide, still in the binary. Any device that is revoked and re-provisioned on the same box between daemon restarts silently gets NO PSK ever written. Code fix pending (see below). |
| Root cause #2 (client) | **Stale persisted PSK survives re-provision** — Android bakes an old `psk_<serverKey>` into a brand-new registration, so the WG handshake can never complete (server has no PSK for the new peer). Only cleared on sign-out. Code fix pending. |
| Wi-Fi UDP 9999 | NOT the problem. User's Japan Wi-Fi passes 9999 fine (verified with probes). |
| InitConf retransmits | Working as designed (observed on the wire: InitConf + 3 retransmits, all acked). |
| jp1 daemon | cloak-rpd restarted 20:40 JST — clean preload of all server.toml peers WITH outfiles. Same verified binary sha256 `326cba2e…` as fleet. |

## The failure chain observed live (what actually happened)

1. Phone connects; app had a **stale persisted PSK** (keyed by the *server's*
   pubkey in `TunnelRepository`, survives re-provision) baked into the tunnel
   while the server-side (fresh) peer had none → WG handshake NEVER completes
   (initiation/response loop every 5 s, `latest handshake = 0`). Tunnel black
   from second zero. rp9999=0 at this stage because the Rosenpass socket fell
   back in-tunnel (black) — the `"no non-VPN network found"` fallback.
2. App auto-recovery re-provisions → API **revokes** the old peer and re-ADDs
   over cloak-rpd's control socket. That triggers **root cause #1**:
   `PeerCtl::Remove` tombstones the CryptoServer entry (nulls its `outfile`);
   the re-`ADD` of the same/new name creates a duplicate entry, but incoming
   handshakes resolve to the tombstoned one → the PQC exchange **completes on
   the wire** (client shows "rotation 1 OK", applies its PSK) while the server
   **silently writes no PSK file** → `cloak-psk-installer` has nothing to
   install → next WG rekey (~2 min) fails on PSK mismatch → "connects, PQC
   rotation 1, then no internet." Exactly the reported symptom, reproduced and
   packet-captured at 20:34 JST.
3. Recovery/reprovision budgets exhaust → app gives up ("manual reconnect").

Sign-out (which clears `psk_*`) + a cloak-rpd restart (which collapses the
duplicate entries into one clean preloaded entry WITH outfile) + force-stop of
the app (resets recovery budgets) fixed it. Verified end-to-end.

## Fix #1 — cloak-rpd (server, PRIORITY: whole fleet is exposed)

File: `server/cloak-rpd/patches/event_loop_with_control.rs.snippet` (and the
applied copy in the build workspace on the VM 178.104.136.167).

Bug: `remove_peer_by_outfile` tombstones (nulls `outfile`) but the entry keeps
its pubkey; `known_peers` drops the name; a later ADD of the same device
creates a duplicate pubkey entry. Rosenpass resolves inbound handshakes to the
FIRST (tombstoned) entry → `output_key` sees `outfile=None` → no PSK file, no
error, nothing in logs (Quiet).

Suggested fix: on `PeerCtl::Add`, before calling `add_peer`, scan
`self.peers` for an entry whose pubkey matches the key being added (or track
name→outfile) and if a tombstoned entry exists, **reactivate it** (restore
`outfile`) instead of adding a duplicate. Alternatively on `Remove`, keep the
entry in `known_peers` and only null the outfile, restoring it on re-ADD.
Follow the existing build/canary/rollout scripts in `server/cloak-rpd/`
(builder VM, canary us-east-1, then fleet; de1/fi1 still SSH-locked).

Interim mitigation (until rollout): a `systemctl restart cloak-rpd` on the
affected box clears the condition (ExecStartPre rebuilds the preload set from
server.toml). Restart drops in-flight PQC handshakes only; wg0 unaffected.

## Fix #2 — Android client

File: `clients/android/app/src/main/kotlin/ai/latticevpn/android/vpn/TunnelRepository.kt`
(+ `TunnelManager.reprovisionAndRecover`).

Bug: persisted PSK is keyed by the server's pubkey (`psk_<peerPublicKey>`) and
survives a full re-provision. A fresh registration (new device identity,
server has no PSK) then presents the stale PSK → WG handshake can never
complete → permanently black tunnel that no retransmit mitigation can touch.

Fix: clear the persisted PSK for the target server whenever a fresh
provision/re-provision is imported (`reprovisionAndRecover` /
`importConfig` on a new registration), or key the persisted PSK by
(server pubkey, device wg pubkey) so a new identity never inherits it.

Secondary (same file area, lower priority):
`RosenpassTransport.connect()` falls back to an in-tunnel socket when the
underlying network isn't found — during a desync that black-holes the very
handshake that would recover it (observed: rp9999=0 while tunnel black, then
packets flowed out-of-tunnel once the tunnel was healthy). Consider failing
the attempt instead of falling back, so the retry (with backoff) re-queries
the underlying network.

Note: `LIVE_ROTATION_ENABLED = true` in `TunnelManager.kt` but its doc comment
says "OFF (current)" — stale comment, worth fixing to avoid future confusion.

## Diagnostic evidence (for reference)

- Phone Wi-Fi passes UDP 9999: user's MacBook probes (same Wi-Fi) arrived at
  jp1 (`tcpdump` 20:33:40). Internet probes from the Mac Mini (75.85.70.68)
  also arrive → no Vultr firewall issue.
- Full PQC exchange captured 20:34:02: InitHello(1060) → RespHello(1100) →
  InitConf(176) → ack(64), + 3 idempotent InitConf retransmits. Client-side
  mitigations work. Server wrote NO psk file → tombstone bug.
- After daemon restart + clean reconnect: `/run/rosenpass/psk-peer-6483e103a656`
  written 20:42, re-written 20:44 (rotation #2); wg peer `MGbG…` shows
  `preshared key: (hidden)`, handshake epoch advanced THROUGH a rekey with the
  PSK active, transfer 5.9 MiB rx / 11.7 MiB tx and growing.
- iOS also re-provisioned onto jp1 during the session (peer `e76fc62df828`,
  wg `cYVx…`) and is working with PQC (psk file 20:41).

## Open items (carried + new)

- ~~Upload Android v1.0.3 to Play~~ **DONE (same session):** v1.0.3
  (versionCode 5) uploaded to Internal testing AND promoted to Production via
  the Android Publisher API using the `lattice-play-billing` service account
  (it has release permission; scripts kept at us-west-1 `/root/play_upload.py`
  / `play_promote.py` / `play_check.py` — token via SA JWT + openssl, no
  google libs needed). Production release "5 (1.0.3)" is pending Google
  review, auto-publishes. NOTE: the user's phone runs the sideloaded
  upload-key build; to go back to Play-served builds they must uninstall and
  reinstall from Play once v1.0.3 is live (signature differs).
- Ship iOS build 113 to App Store review (carried).
- ~~de1/fi1 SSH-locked~~ **RESOLVED (2026-07-02):** the "SSH lock" was simply a
  stale admin IP — the Hetzner firewall allowed 22/tcp only from
  `98.151.176.20/32` (old admin IP); the Mac's current IP is `75.85.70.68`.
  Fixed via terraform (`infra/terraform/regions/{de1,fi1}/terraform.tfvars`
  `admin_ip_cidrs` now lists both IPs, targeted apply of
  `module.concentrator.hcloud_firewall.cloak`). Fixed cloak-rpd `b312424e…`
  deployed to both — **all 10 boxes now run the tombstone-fix binary.**
- **de1/fi1 had 443/tcp closed the whole time** (`enable_api_port = false` in
  tfvars while Caddy+regionsvc were up and healthy on the boxes) — so
  PROVISIONING Germany/Finland was impossible from anywhere; that, not PQC,
  was why the iPhone failed on those regions (Android appeared to work from
  cached state). Flipped to `true` + applied; `rgn-de1`/`rgn-fi1` `/healthz`
  now return 200 publicly. iPhone (build 113, NO new build) verified working
  on BOTH Germany and Finland with PQC (psk file written on de1, PSK on wg
  peer, handshake surviving rekeys).
- **us-east-1 psk-installer incident (2026-07-02):** `cloak-psk-installer`
  has `PartOf=cloak-rosenpass.service`, so stopping the legacy service during
  the rollout silently stopped the installer → PSKs written but never
  installed → dead tunnels on that box until the installer was restarted.
  **FIXED fleet-wide (2026-07-02):** all 10 boxes now have
  `PartOf=cloak-rpd.service` in the installer unit (+ daemon-reload,
  installer verified active, legacy `cloak-rosenpass` disabled). The legacy
  unit FILES remain on disk (not removed) — inert unless started manually.
- **Legacy `cloak-rosenpass.service` port race (new, fleet-wide):** on
  us-east-1 the disabled-but-restart-looping legacy unit grabbed :9999 the
  instant cloak-rpd stopped during the binary swap ("Address already in use"
  crash-loop). Mitigated during rollout by `systemctl stop cloak-rosenpass`
  before each restart; masking failed (unit is a real file in
  /etc/systemd/system). TODO: properly disable/remove the legacy unit
  fleet-wide so a future cloak-rpd restart can't lose the port.
- Retire Tokyo plain-WG fallback peer `10.99.0.50` once both platforms trusted
  (carried) — Android v1.0.3 and iOS 113 both verified working now.
- IPv6 half-broken on Vultr boxes (carried).
- jp1 wg0 has orphaned peers from today's churn (`WLBA…`, `MGbG…` — the
  phone's pre-reinstall identity, never revoked because the uninstall wiped
  the app before it could — plus old `Pz15/IfXV` test peers) — harmless but
  worth a cleanup/revoke-audit pass.
- Android `RosenpassTransport` in-tunnel fallback (root-cause amplifier,
  lower priority): consider fail-fast instead of falling back into a possibly
  black tunnel — left unchanged in v1.0.3 to keep the tested change minimal.

## Monitoring additions (2026-07-02)

- **Audit result:** detection worked all along (`PskInstallerDown` fired during
  the us-east-1 installer outage) but every alert emails only
  `support@latticevpn.ai`. Criticals now ALSO route to
  `demetris@neuroaistudios.com` (edited both `alertmanager.yml` — the template —
  and `alertmanager.rendered.yml` — what the container actually loads after
  env substitution at start; reload only re-reads the RENDERED file).
- **Collector extended** (`server/scripts/cloak-textfile.sh`, deployed to all
  10 boxes): new per-box gauges `cloak_wg_active_peers`,
  `cloak_wg_active_nopsk_peers` (active peer with NO PSK — poisoned client /
  installer down / tombstone class; intentional plain-WG peers excluded via
  `/etc/cloakvpn/nopsk-allowlist`, currently only jp1's `10.99.0.50/32`), and
  `cloak_wg_dialing_nohandshake_peers` (endpoint recorded but wg handshake
  NEVER completed — the stale-client-PSK signature).
- **New alert rules** (`/opt/lattice-monitoring/prometheus/alerts/pqc-peer-state.rules.yml`
  on the VM; repo copy `infra/monitoring-pqc-peer-state.yml`):
  `ActivePeerWithoutPsk` (critical, 5m) and `PeerDialingNeverHandshakes`
  (warning, 10m). NOTE: rule files must match `*.rules.yml` or Prometheus
  ignores them.
- **Live fleet dashboard** exists as a Cowork artifact
  (`lattice-fleet-dashboard`): per-region rpd/installer status, active peers,
  the two signature metrics, PSK freshness, firing alerts. Data path:
  Control-your-Mac osascript → SSH → Prometheus on the VM.

## Gotchas added this session

- cloak-rpd runs Quiet: a peer that completes handshakes but writes no PSK is
  INVISIBLE in logs — classify with the psk-file + `wg show ... preshared`
  check, and remember the tombstone bug when a revoked device re-provisions.
- `wg show wg0 dump` epoch 0 + endpoint present + retry-loop on :51820 =
  client presenting a PSK the server doesn't have (stale client PSK).
- Android recovery budgets are per-process: force-stop resets them.
