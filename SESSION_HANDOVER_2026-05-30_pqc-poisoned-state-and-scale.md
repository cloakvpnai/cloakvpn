# Session Handover — 2026-05-30 — PQC poisoned-state root cause, region-switch fixes, and the path to scale

Read top to bottom. This session fixed several real bugs, hit two self-inflicted
regressions (reverted), and ended with the iOS app **working** (PQC rotates,
region-switching works). It also surfaced the true root cause of a long-running
"PQC stuck Handshaking" class of failure and scoped the two remaining product
goals.

---

## TL;DR — current state

| Area | Status |
|------|--------|
| Region switch "Couldn't reach Lattice" | **FIXED (server + client) + VERIFIED.** Server-side: `POST /v1/device` provisions new region and responds BEFORE revoking the old peer + re-validate race guard (`3f87954`, `2982db0`). Client-side (the real fix): on a switch-while-connected, **disconnect first, provision off-tunnel, then connect** (`eff78e7`) — the in-tunnel provision request was dying under includeAllNetworks, esp. on slow (legacy-box) provisions. Switching now works and is faster. Fresh-connect path unchanged. |
| PQC livelock after region switch (client) | **FIXED.** NE convergence-grace: don't self-kill the tunnel while the first rosenpass exchange has never landed. Commit `3f87954`. On the phone. |
| **PQC "stuck Handshaking" / "idle" — TRUE ROOT CAUSE** | **FIXED for this device via clean reinstall.** It was **poisoned PQC state in the iOS App Group container** (rosenpass keypair / stored server pubkey the NE needs to start the exchange). It survived every `devicectl install` because those are *upgrades* that keep app data. Symptom: WireGuard fully up (thousands of pkts) but **0 packets to rosenpass :9999** — the NE never even attempts PQC. Cleared by delete + fresh install. |
| iOS "carve-out removal" + "PQC-idle display fix" | **REVERTED** (`157232c`). They were chased as the cause of the above and reverted twice; the real cause was the poisoned container. The display fix is host-only and cannot stop the NE from sending rosenpass — it was a red herring. App is back to the convergence-grace build (`3f87954` code state). |
| `cloak-rpd` zero-restart rosenpass daemon (scale) | **PROVEN in spike, canary ROLLED BACK.** Daemon does live peer-add with no restart (local two-endpoint spike passes). us-east-1 canary cut over cleanly but the real iOS client did not complete its exchange against it; rolled back to stock `cloak-rosenpass`. Parked. See `server/cloak-rpd/`. |

**The app is currently working on the test device. Do not blind-reinstall
experimental client code onto it without a validation plan — that caused two
regressions this session.**

---

## The decisive diagnostic (keep this technique)

When "PQC stuck Handshaking", `tcpdump` on the region box separates client vs
server vs state instantly:

```
ssh root@<box> 'timeout 18 tcpdump -ni any -nn udp port 9999 or udp port 51820 > /tmp/cap.txt; \
  echo wg=$(grep -c 51820 /tmp/cap.txt) rp=$(grep -c 9999 /tmp/cap.txt)'
```

- `wg>0, rp=0` → device isn't sending PQC at all → **client PQC state is broken**
  (the poisoned-container case). Fix = regenerate keys / re-provision (today: reinstall).
- `wg>0, rp>0` but no `output-key … exchanged` in `journalctl -u cloak-rosenpass`
  → server-side: rosenpass restarting (peer churn) or key/param mismatch.
- `wg=0` → device not reaching the box (routing / wrong endpoint).

## Mistakes made this session (so they're not repeated)

1. Chased my own recent iOS changes (display fix, carve-out removal) as the cause
   of "stuck Handshaking" and reverted good work **twice**. The real cause was the
   poisoned App Group container, which no upgrade-install could clear.
2. Did not run the `tcpdump` client-vs-server split early. Once run, it
   immediately showed `wg=4446, rp=0` and pointed straight at client PQC state.
3. Lesson: **measure before reverting.** A host-app status/display change cannot
   stop the network-extension from emitting rosenpass packets — that was provably
   not the cause.

---

## Goal 1 (must-do for customers): self-heal poisoned PQC state — NO reinstall

Customers cannot be told to delete+reinstall. The app must detect and recover
from the exact failure seen today.

**Detector (host app, RosenpassBridge/TunnelManager):** after a successful
`.connected`, if the NE reports **0 rotations** past a grace window (e.g. 90s)
AND WireGuard is up, treat PQC as wedged-from-bad-state.

**Integrity precheck (cheaper, targets today's exact poison):** before/at
connect, verify the App Group has (a) a loadable local rosenpass keypair and
(b) a non-empty stored server pubkey. If either is missing/corrupt → regenerate
the keypair and force a fresh provision (which re-saves the server pubkey).

**Recovery action (rate-limited, once per connection, max N per window):**
clear the per-region config cache for the current region, regenerate the local
rosenpass keypair if integrity failed, and re-run the provision for the current
region (fresh peer → fresh exchange). Never fires on the happy path (≥1 rotation).

**Validation gate before shipping to a real device:** reproduce the poisoned
state (e.g. corrupt/remove the App Group rosenpass key files on a test device),
confirm the app auto-recovers to Rotating WITHOUT a reinstall, and confirm the
happy path is untouched (no spurious re-provisions when PQC is healthy).

## Goal 2 (scale to thousands): finish `cloak-rpd`

The throughput bottleneck is rosenpass restart-on-peer-change: every new-device
provision and every region switch restarts a box's `cloak-rosenpass`, dropping
ALL peers' in-flight exchanges for ~2-5s. At thousands of devices with churn this
continuously interrupts PQC. `cloak-rpd` (this session) adds peers at runtime
over a control socket with no restart — **proven** by the local two-endpoint
spike. See `docs/ROSENPASS_NO_RESTART_PEER_MGMT.md` and `server/cloak-rpd/`.

**The canary gap to close first:** us-east-1 cutover worked (daemon up, 12 peers
preloaded, regionsvc socket-aware, zero restarts) but the **real iOS client did
not complete its exchange** against cloak-rpd, while the rosenpass-CLI spike did.
Likely causes to check, in order:
1. Was the device's peer actually ADDed to cloak-rpd? (regionsvc only sends ADD
   when the peer set changes; same-region reconnect skips it and relies on
   preload — verify the user's peer was preloaded/added.)
2. OSK domain separator: cloak-rpd uses `OskDomainSeparator::default()`; confirm
   that matches what the iOS FFI and the production server.toml peers use.
3. Protocol version: cloak-rpd uses V03; confirm the device is V03 (it is).

**Plan:** reproduce the iOS client against cloak-rpd in a controlled setup (not a
live box) → close the param gap → re-canary us-east-1 with a soak → fleet rollout
(one regionsvc binary already auto-detects the socket and falls back to restart on
non-migrated boxes). Build natively on amd64 (Debian trixie) for fast cycles; the
emulated Docker path on Apple Silicon is ~20min/cycle (too slow for iteration).

## Reference / deployed state
- Central API: `https://api.latticevpn.ai` → `5.78.203.171` (cloak-us-west-1).
  Running patched cloakvpn-api (sha `a9d3c5a5…`; backups `.bak-20260529`,
  `.bak-20260530a`).
- us-east-1 `5.161.198.227`: rolled back to stock `cloak-rosenpass` (canary
  artifacts staged in `/root/cloak-rpd-canary/`, `cloak-rpd` disabled).
- iOS: build 104, code at `3f87954` (convergence grace), CLEAN-installed.
- Build box for cloak-rpd: `5.78.203.171` (`/root/rp`, rustup + the daemon).
- Commits this session: `3f87954`, `cdad4df`(reverted), `dfb5385`(reverted),
  `2982db0`, `b524592`, `01583a5`, `2c101c5`, `823e934`, `c3297cb`, `157232c`.
