# Session Handover — 2026-05-29 (evening) — iOS App Store submit + PQC re-provision-loop

Follows `SESSION_HANDOVER_2026-05-29_android-launch-and-ios-unblocked.md`.
Read top to bottom. This session: got iOS Build 103 into App Store review,
fixed iOS region-switching, deployed a fleet-wide regionsvc fix, and
diagnosed (but did NOT fully fix) a PQC handshake livelock on region
switch. There is one **must-do** follow-up: the iOS recovery re-provision
loop (see "Next task").

---

## TL;DR — where things stand

| Area | Status |
|------|--------|
| iOS Build 102 rejection | **ROOT-CAUSED** — Guideline 5.4 (VPN must ship from an org account); rejection predated the KryptoKnightz LLC migration, so it was already resolved |
| iOS Build 103 (1.0) | **SUBMITTED — "Waiting for Review"** under KryptoKnightz LLC, with reviewer notes + account number |
| iOS region-switch-while-connected ("Couldn't reach Lattice") | **FIXED** — out-of-tunnel control-plane routing; shipped in local build 104 |
| regionsvc rosenpass restart-per-provision | **MITIGATED + deployed fleet-wide** — idempotency guard (restart only when peer set changes). Necessary but NOT sufficient |
| **PQC "Handshaking" stuck on region switch** | **DIAGNOSED, NOT FIXED** ← next task. Client recovery loop re-provisions every ~15s; each re-provision restarts rosenpass and kills the in-flight exchange |
| App icon | Left as-is (text-free shield); good for App Store. Do not change mid-review |

---

## What was accomplished

### 1. iOS Build 102 rejection — root-caused, already resolved
Rejection was **Guideline 5.4 (VPN apps must be submitted from an org
account)**, dated 2026-05-14 — *before* the KryptoKnightz LLC migration.
The org migration (Team ID `5HYY2YP2G9`) already resolves it. No code or
privacy-form change required. Project's `DEVELOPMENT_TEAM` is already the
org team on both targets (main + CloakTunnel), automatic signing.

### 2. iOS Build 103 built, tested on-device, submitted
- Bumped `CURRENT_PROJECT_VERSION` 102 → 103 (later 104, see below).
- Built + archived via `xcodebuild` (Xcode 26.5) driven over osascript on
  the Mac. Uploaded via Organizer (the API key `4SAQ4QAPXC` couldn't
  cloud-sign — "Cloud signing permission error" — so the GUI/account-holder
  path created the distribution cert).
- Installed on the iPhone (devicectl) and verified the account-number flow
  works with the real account number.
- Submitted: **1.0 is "Waiting for Review."** Reviewer notes + account
  number live in App Review Information. See `docs/APP_REVIEW_NOTES.md`.

### 3. iOS region-switch fix (out-of-tunnel control plane)
Symptom: connected to region A, switching to B failed with "Region select
failed — Couldn't reach Lattice." Cause: with `includeAllNetworks = true`,
the provision request rode the active tunnel; the server revokes that
peer mid-switch, killing the in-flight request. Android already pinned
control-plane calls to the physical interface; iOS did not.

Fix (in `clients/ios/CloakTunnel/PacketTunnelProvider.swift`): resolve
`api.latticevpn.ai` at startTunnel (out-of-tunnel) and add its IP(s) to
`excludedRoutes`, mirroring the existing rosenpass-server carve-out.
Constants `controlPlaneHost` / `controlPlaneFallbackIPv4 = 5.78.203.171`.
Verified: switching now reaches the destination region (no more "Couldn't
reach Lattice"). Shipped in local **build 104** (installed on the phone;
NOT yet uploaded — 103 is the in-review build).

### 4. regionsvc rosenpass restart-per-provision — idempotency guard
`server/api/internal/wg/wg.go`: `appendRosenpassPeer` and
`removeRosenpassPeer` now return `(changed bool, error)`, and
`Provision` / `ProvisionWithKeys` / `Revoke` only call `restartRosenpass()`
when the peer set actually changed (key file or server.toml block). This
stops a no-op re-provision from bouncing the (fleet-wide) rosenpass daemon.

**Deployed to ALL 10 boxes** via `scripts/deploy_regionsvc_fix_20260529.sh`
(sha-verify + backup + restart + active-check). Backup on each box:
`/usr/local/bin/regionsvc.bak-20260529`. Binary sha256 (linux/amd64):
`8893ea8483ab370d956404643f54237f12ecd18f47e20869f4af4ca42029ad1c`.
Rollback = restore the .bak and `systemctl restart regionsvc`.

NOTE: 3 boxes (de1 `91.98.65.98`, fi1 `204.168.252.70`, `207.148.1.253`)
already carried this exact sha before the rollout — the fleet was in a
mixed state; us-east-1 and others were on the older `84fcd665…` build.
Now uniform.

---

## NEXT TASK (the real remaining bug): iOS PQC re-provision loop

**Symptom:** after a region switch, PQC stays on "Handshaking" forever
(plain single-region connects are usually fine because the first exchange
beats the recovery timer).

**Root cause (confirmed from central API logs on `5.78.203.171` /
cloak-us-west-1, service `cloakvpn-api`):** the phone fires repeated
`POST /v1/device` provisions (~every 15–20s during the stuck state), each
taking 2–4s because each restarts rosenpass. The iOS "wedge recovery" /
RosenpassBridge health logic (3s poll in `RosenpassBridge.swift`; Layer 3
auto-reconnect in `TunnelManager.swift` ~line 1057+) re-provisions when it
judges PQC unhealthy. On a switch there's a window where PQC isn't
established yet → recovery re-provisions → rosenpass restarts → the
in-flight exchange dies → still unhealthy → loops.

The server idempotency guard (#4) was meant to break this, but the
recovery path still trips a restart each time — almost certainly because
recovery **regenerates the rosenpass/WG keypair** (so the server sees a
genuinely new peer → legitimate restart). Confirm this first.

**Fix direction (client-side, `clients/ios`):**
1. Recovery must NOT regenerate the persisted rosenpass/WG keypair on a
   normal re-provision — reuse the keys so the server idempotency guard
   actually skips the restart. (Check `ensureLocalKeypair` /
   `ensureLocalWGKeypair` aren't being cleared on recovery.)
2. Add backoff + a "PQC is still converging" grace period so recovery
   doesn't re-provision within N seconds of a provision (let the first
   exchange complete — server restart + exchange is ~3–5s).
3. Consider the Android "de-phase PSK rotation" approach (already done on
   Android per prior handover) as the reference.
Then rebuild, install on device, and verify: connect → switch → switch
again, PQC reaches Rotating on each and STAYS. Watch
`journalctl -u cloakvpn-api` on `5.78.203.171` — provisions should stop
repeating once stable.

---

## Other open items (carried)
- **Upload build 104+ once the PQC loop is fixed** — ship as 1.0.1 AFTER
  1.0 is approved (don't reset the review queue).
- **Play reviewer credentials** — confirm account number
  `KPNX3-…` is in Play Console → App content → App access.
- **Android v1.0.1 16 KB page fix** (versionCode=3) — from prior handover.
- **Commit hygiene:** the regionsvc fix is now committed AND deployed; keep
  them in sync. If you roll back a box, note the divergence.

## Reference
- iOS: team `5HYY2YP2G9`, bundle `ai.cloakvpn.CloakVPN`, App ID `6764261045`.
  In-review build = 103; local dev build = 104.
- Central API: `https://api.latticevpn.ai` → `5.78.203.171` (cloak-us-west-1,
  single stable Hetzner origin; runs cloakvpn-api + regionsvc).
- Region boxes (all run regionsvc, fixed binary deployed):
  `5.161.198.227` us-east-1, `91.98.65.98` de1, `204.168.252.70` fi1,
  `207.148.1.253`, `65.20.99.121`, `216.238.95.21`, `139.84.248.50`,
  `65.20.77.179`, `167.179.75.10`, `5.78.203.171` us-west-1.
- SSH: `~/.ssh/config` has all boxes as `root@<ip>`.
- Test account number lives in the user's password manager (not here).
