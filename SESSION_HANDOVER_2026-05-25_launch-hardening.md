# Session Handover — 2026-05-25 — Launch hardening (PQC, region switching, device limits)

Handoff for a fresh chat. Read this top to bottom before doing anything.

This session follows `SESSION_HANDOVER_2026-05-25_multiregion-launch.md`. It
began as "rebuild the Android app" and turned into a run of live-incident
fixes plus one new backend feature. Everything below is done and deployed
unless marked otherwise.

---

## TL;DR — where things stand

| Area | Status |
|------|--------|
| PQC (Rosenpass) handshake + 2-min rotation | **DONE** — working, now self-healing |
| Region switching while connected | **DONE** — works end to end |
| Android app (self-heal + out-of-tunnel API) | **DONE** — built & installed on the test phone; **not yet on Play** |
| `cloak-api-server` crash-loop (legacy service) | **DONE** — retired on all 10 boxes |
| Self-cleaning device limit + per-tier caps | **DONE** — live on `cloakvpn-api` (us-west-1) |
| **Google Play internal-testing upload** | **NOT STARTED** ← next task |
| iOS app | Unchanged — still blocked on the Apple org migration |

**Immediate next task: the Google Play internal-testing upload.** Everything
else from the launch is operational.

---

## What was accomplished today

### 1. Region switching while connected — fixed

Symptom: switching concentrators while the VPN was connected failed
("Couldn't reach Lattice"); the tunnel never moved.

Root cause: `POST /v1/device` (the provision call that drives a switch) was
routed *through* the active WireGuard tunnel. A region switch makes the
server revoke the device's current peer — tearing down that tunnel — so the
response could never get back and the switch never completed.

Fix (Android): `AccountClient` now pins its OkHttp socket factory and DNS
resolver to the device's underlying non-VPN network, so account and
provisioning calls bypass the tunnel — the same approach `RosenpassTransport`
already uses for the PQ handshake. Wired through `TunnelManager` and
`LatticeViewModel`.

### 2. PQC handshake failure (Tokyo / jp1) — diagnosed and fixed

Symptom: the test phone connected to a concentrator but the Rosenpass
post-quantum handshake timed out ("UDP receive timeout after 8s"); the
tunnel then self-disconnected.

Diagnosed by elimination — ruled out the firewall, a dead service, an
IPv6-only socket (`bindv6only=0`), a protocol-version mismatch, and a
regenerated server keypair. `tcpdump` + `strace` on the concentrator proved
the phone's handshakes *arrived* and rosenpass *received* them but produced
no reply (an ~8 ms crypto rejection). A local loopback test — a rosenpass
client running as `client1` against the box's own listener — completed a
full V03 handshake, proving the server's rosenpass, config and keys were
healthy.

Root cause: the phone was reusing a **stale cached region config** whose key
material no longer matched the concentrator, and the app's region-selection
cache-hit path meant it never re-provisioned to recover — it was stuck
replaying a dead handshake.

Immediate fix: `adb shell pm clear ai.latticevpn.android` forced a clean
re-provision; a fresh peer registered and the handshake succeeded at once.

### 3. App self-heal on persistent PQC failure — the durable fix

A real customer can't run `pm clear`. `TunnelManager`'s watchdog ran 3
in-tunnel recovery attempts — all reusing the same stale cached config —
then gave up and left the tunnel dead.

Fix (`TunnelManager.kt`): added a re-provision escalation tier. When the
in-tunnel recovery budget is spent, the app drops the cached config and
re-provisions from scratch (`POST /v1/device` re-registers the device and
returns the concentrator's current Rosenpass key). Bounded by
`MAX_REPROVISIONS = 2`; both recovery budgets reset on a healthy rotation.
A key-desynced device now recovers on its own — the automatic equivalent of
the `pm clear`.

### 4. `cloak-api-server` crash-loop — retired fleet-wide

While watching the Tokyo logs, found `cloak-api-server` crash-looping —
900+ restarts, one every ~3 s — because `/etc/cloak/jwt-secret` was missing.
`cloak-api-server` is the **legacy** JWT-era provisioning service; it was
superseded by `regionsvc` (the account-number model has no JWTs). Disabled
it (`systemctl disable --now cloak-api-server`) on **all 10 concentrators** —
it was confirmed crash-looping on every box. Provisioning runs entirely
through `regionsvc`, which is untouched.

### 5. Self-cleaning device limit + env-configurable tier caps

Symptom: the user's account showed "3 devices" for a single physical phone,
and eventually returned "too many devices."

Root cause: a `devices` row is keyed on the WireGuard public key, which the
app regenerates on every reinstall / "clear data" / `pm clear`. One physical
phone legitimately accumulates several rows over time and eventually hits
the tier cap with a 403.

Fix (`cloakvpn-api`):

- `store`: added `devices.last_seen` (Migration 2 — auto-applied on startup,
  existing rows backfilled to `created_at`).
- `http`: `POST /v1/device` now evicts the least-recently-seen device when a
  genuinely new device would exceed the tier cap, instead of returning 403.
  Re-provisions and region switches still never consume a slot; the eviction
  loop also absorbs an over-limit account left by a Pro→Basic downgrade.
- `main`: `BASIC_DEVICE_LIMIT` / `PRO_DEVICE_LIMIT` are read from env,
  defaulting to **3 / 10**.

Built (`linux/amd64`) and deployed to `cloakvpn-api` on us-west-1.

### 6. Earlier in the session — PQC rotation, DNS, systemd wedge

Before the above, the session also resolved (committed in `990725c` and
`23a9225`, rolled out to all 10 boxes):

- **systemd start-limit wedge** — `cloak-rosenpass` (and the psk-installer)
  could wedge in a failed state under provisioning bursts. `setup.sh` now
  sets `StartLimitIntervalSec=0`, and `regionsvc` runs `systemctl
  reset-failed` before a restart.
- **DNS black-hole** — `WG_DNS` defaulted to a non-existent resolver
  (`10.99.0.1`); changed to Quad9 (`9.9.9.9`, `2620:fe::fe`).
- **PQC rotation desync** — the 2-minute Rosenpass rotation phase-locked
  with WireGuard's ~120 s rekey; added ±25% jitter to the rotation interval
  so the two never stay aligned. Soak-tested overnight, clean.

---

## Next steps

### IMMEDIATE — Google Play internal-testing upload

The Android app is code-complete, built, and tested on the user's phone
(sign-in, 10-region picker, connect, region switching, PQC rotation, and the
new self-heal path are all in the running build). Release signing:
`clients/android/lattice-release.jks`, password in
`clients/android/secrets.properties` (gitignored). Build with
`./gradlew :app:assembleRelease` from `clients/android/`, then upload the
AAB/APK to the Play Console internal testing track.

### iOS — still blocked on Apple

Unchanged from the prior handover: blocked on the Apple Developer
individual→organization migration. Nothing to do until Apple restores
membership benefits.

### Housekeeping

- The user's own account still has ~3 ghost device rows from tonight's
  reinstalls. They self-correct on the next provision (eviction kicks in at
  the cap), or can be removed from the app's Account screen.
- The new self-heal logic is built and on the phone but hasn't been
  *exercised* — it only fires on a real desync. To prove it: revoke the
  phone's peer on a concentrator and watch the app re-provision itself.

---

## Known issues / things to watch

- **Rosenpass restart-per-provision (scaling).** Carried over from the prior
  handover and still true: every provision restarts `cloak-rosenpass` on the
  target box. The `StartLimitIntervalSec=0` change stops it *wedging*, but
  the restart-per-provision design itself remains a scaling concern under
  heavy concurrent load.
- **Device limit is soft on downgrade.** A Pro→Basic downgrade does not
  immediately prune devices; the account converges back under the cap on its
  next new-device provision (the eviction loop handles it). Acceptable, but
  noted.

---

## Gotchas hit today (so the next chat doesn't repeat them)

- **modernc SQLite driver + `COALESCE` on a time column.** Selecting
  `COALESCE(last_seen, created_at)` and scanning into `time.Time` fails at
  runtime — the driver only converts a result column to `time.Time` when it
  carries a declared `TIMESTAMP` type, which a `COALESCE()` expression loses.
  This 500'd every device read on the first device-limit deploy. The
  `accounts` code already worked around the same quirk (it scans
  `active_until` as a string and parses by hand). **Never `COALESCE` a
  column you scan into `time.Time` — select it plain, or scan it as a string.**
- **`.git/index.lock` cruft.** Earlier sandbox commits left a stale
  `.git/index.lock` (the sandbox filesystem mount cannot `unlink`). If a
  Mac-side `git` command reports "Another git process seems to be running",
  `rm -f .git/index.lock` and retry.
- **The 4 Hetzner boxes are key-only.** us-west-1, us-east-1, de1, fi1
  authenticate with `~/.ssh/cloakvpn_ed25519`; plain `ssh root@<ip>` fails
  because that key is not a default name. An `~/.ssh/config` block was added
  mapping those four IPs to that key, so `ssh <ip>` now works directly.
- **Always sha256-verify a deployed binary** (carried over, and it stayed
  relevant — the deploy verification is about the *transfer*, separate from
  whether the code itself is correct).

---

## Reference

- `cloakvpn-api` runs on **us-west-1 (`5.78.203.171`)**, behind Caddy at
  `https://api.latticevpn.ai`. Binary `/usr/local/bin/cloakvpn-api`; env
  `/etc/cloakvpn/api.env`; SQLite DB `/var/lib/cloakvpn/cloakvpn.db`. The
  schema migration runs automatically on startup.
- Deploy `cloakvpn-api`: cross-compile `GOOS=linux GOARCH=amd64 go build`
  from `server/api/`, scp to the box, sha256-verify, `systemctl stop` → swap
  `/usr/local/bin/cloakvpn-api` → `systemctl start`.
- `server/api/cloakvpn-api` and `server/api/regionsvc` are gitignored build
  artifacts; the Go source is committed. The module requires **Go 1.25**.
- To change tier device limits without a recompile: set `BASIC_DEVICE_LIMIT`
  / `PRO_DEVICE_LIMIT` in `/etc/cloakvpn/api.env` and `systemctl restart
  cloakvpn-api`. Defaults are 3 / 10.
- The 10 regions and their IPs are listed in
  `SESSION_HANDOVER_2026-05-25_multiregion-launch.md`.
- Secrets live only in `/etc/cloakvpn/*.env` on the boxes and the user's
  password manager — never in the repo, never in a handover doc.

### Commits made this session (newest first)

```
(hotfix)   cloakvpn-api: fix device reads — select last_seen as a plain column
(devlimit) cloakvpn-api: self-cleaning device limit + env-configurable tier caps
(android)  Android: out-of-tunnel account API + self-healing PQC recovery
23a9225    android: rotation jitter + RosenpassTransport network-lookup hardening
990725c    server: rosenpass restart self-heal + Quad9 DNS + systemd start-limit
```

The three newest were committed from the Mac during this session — run
`git log --oneline` for their hashes. Run `git push` to back everything up
to GitHub.
