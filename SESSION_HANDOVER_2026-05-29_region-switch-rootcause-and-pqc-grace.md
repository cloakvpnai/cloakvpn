# Session Handover — 2026-05-29 (late) — region-switch root cause + PQC convergence grace

Follows `SESSION_HANDOVER_2026-05-29_ios-appstore-submit-and-pqc-reprovision-loop.md`.
This session closed out the two region-switch bugs that prior handover left
open/misdiagnosed. Both fixed, built, and (server) deployed. Read top to bottom.

---

## TL;DR

| Area | Status |
|------|--------|
| "Couldn't reach Lattice" on region switch | **FIXED (server-side) + DEPLOYED.** Root cause was NOT iOS routing — see below. `cloakvpn-api` on `5.78.203.171` updated. Verified live (Mexico→ZA and ZA↔US-East now succeed). |
| PQC "Handshaking" stuck after switch | **FIXED (client) + BUILT into build 104, installed on device.** NE convergence-grace; see below. |
| Prior handover's iOS "out-of-tunnel control-plane routing" fix | **Was a no-op.** `excludedRoutes` are not honored for host-app sockets under `includeAllNetworks=true`. Dead code now removed from `clients/ios/CloakTunnel/PacketTunnelProvider.swift`. |

---

## 1. "Couldn't reach Lattice" — real root cause was SERVER-SIDE ordering

**Symptom:** switching regions while connected failed with "Couldn't reach
Lattice" — reliably for distant regions (za1 Johannesburg), intermittently
for nearby ones.

**Why the prior "fix" didn't work:** the prior session added an `excludedRoutes`
carve-out for `api.latticevpn.ai` in the NE, intending the host app's provision
request to ride the physical interface. But under `includeAllNetworks = true`
(which we use for the kill-switch), iOS does **not** honor `excludedRoutes` for
host-app sockets — the same NECP restriction that forced rosenpass UDP to be
relayed through the NE. So the provision request kept riding the tunnel.

**Actual root cause** (`server/api/internal/http/http.go`, `create()` region-switch
branch): the handler revoked the OLD region's peer **before** provisioning the
new region and writing the response. Because the request rides the old tunnel,
revoking the old peer killed the in-flight HTTP response → client saw a
transport error (`AccountError.network` → "Couldn't reach Lattice"). Distant
regions are slow to provision, so the old-peer revoke always beat the response;
nearby regions sometimes won the race. (`AccountError.network` is transport-only;
a server 5xx would have shown "Lattice server error" instead — that distinction
was the key tell.)

**Fix:** provision the new region + `writeProvision` FIRST, then revoke the old
peer **deferred (8s) and best-effort** in a goroutine so it can never kill the
in-flight response. A briefly-lingering old peer is harmless (one device → one
active region; revoke is already idempotent). Fixes ALL platforms (iOS, Android,
web) with no app release.

**Deploy:** built `CGO_ENABLED=0 GOOS=linux GOARCH=amd64` (pure-Go, modernc
sqlite). Installed at `/usr/local/bin/cloakvpn-api` on `5.78.203.171` (the only
box running cloakvpn-api). Binary sha256: `3a0ca7a58cacd6708ef33cde81018861cb39f2251d9f5a2e36805094a48050ef`.
Backup of previous binary: `/usr/local/bin/cloakvpn-api.bak-20260529`
(sha `94bfb931…`). Rollback = `cp` the .bak back + `systemctl restart cloakvpn-api`.
Verified: service active (PID rolled), public + local `/v1/account` return 401,
slow ZA provisions (~5s) now succeed with no error.

## 2. PQC "Handshaking" stuck after switch — client convergence grace

**Root cause:** the NE health monitor (`PacketTunnelProvider`) self-killed the
tunnel on a byte-counter stall even when **no rosenpass PSK had ever been
applied** (`lastPSKAppliedAt == nil`). On a switch the server-side responder is
briefly unready, so the first exchange takes longer than the 60s warmup; the
stall heuristic fired and killed the NE, which destroyed the in-flight rosenpass
exchange → host auto-reconnect → repeat → "Handshaking" forever. (Note: the
prior handover's hypothesis that recovery *regenerates keys* was wrong —
`ensureLocalKeypair`/`ensureLocalWGKeypair` are idempotent and never cleared on
recovery; keys are stable.)

**Fix:** 180s `initialConvergenceGraceSec`. While `lastPSKAppliedAt == nil` and
within the window, stall-based wedge recovery is deferred so `RosenpassDriver`'s
own exponential backoff can land the handshake once the responder is ready.
PSK-age recovery (established tunnel gone stale) and the 3-kills/300s self-kill
cap are unchanged. Mirrors Android, whose recovery is driven by consecutive
*handshake* failures, not WG byte stalls. Built into build 104, installed on the
iPhone.

## 3. Cleanup

Removed the now-dead control-plane `excludedRoutes` carve-out from
`PacketTunnelProvider.swift` (properties `controlPlaneIPs`/`controlPlaneHost`/
`controlPlaneFallbackIPv4`, the startTunnel resolution, the `makeNetworkSettings`
param + loop, and the orphaned `resolveIPs`). The rosenpass-server carve-out is
LEFT INTACT — it governs the NE's *own* UDP socket (avoids looping rosenpass
traffic back into the tunnel) and is still needed.

---

## Open items (carried)
- **Confirm on-device** PQC reaches Rotating and STAYS across a few switches
  (server fix + convergence grace together). Region switch itself already
  verified working this session.
- **iOS build 104 is local-only** — still 1.0 (build 103) "Waiting for Review."
  Ship 104+ as 1.0.1 AFTER 1.0 is approved. If 104 is rebuilt/reinstalled for
  the carve-out cleanup, it remains build 104 (no version bump).
- Play reviewer credentials / Android 1.0.1 16 KB page fix — from prior handover.

## Reference
- Central API: `https://api.latticevpn.ai` → `5.78.203.171` (cloak-us-west-1;
  runs cloakvpn-api + regionsvc). Listens `127.0.0.1:8080` behind TLS.
- Regions (id → endpoint): us-west-1 `5.78.203.171`, us-east-1 `5.161.198.227`,
  us-central-1 `207.148.1.253`, de1 `91.98.65.98`, fi1 `204.168.252.70`,
  es1 `65.20.99.121`, mx1 `216.238.95.21`, za1 `139.84.248.50`,
  in1 `65.20.77.179`, jp1 `167.179.75.10`.
- iOS: team `5HYY2YP2G9`, bundle `ai.cloakvpn.CloakVPN`, App ID `6764261045`.
- Commit: `3f87954` (both fixes). Carve-out cleanup + this doc to follow.
