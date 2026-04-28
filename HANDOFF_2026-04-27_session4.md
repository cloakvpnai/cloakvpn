# Cloak VPN — Session Handoff #4

**Date:** 2026-04-27 (~16:00 UTC → 17:30 UTC, ~ early-evening HST)
**Session length:** ~5 hours total elapsed (much was the user validating the previous session's idempotency commit before this session picked up)
**Status:** ✅ Two real fixes shipped (idempotency commit pushed, TCP MSS clamping). 🚨 One serious pre-TestFlight blocker discovered: iOS NE process wedges after server-side restart, recoverable today only by deleting + re-importing the VPN profile in iOS Settings. Architectural fix scoped, not yet implemented.

> **One-line summary for the next session:** The post-quantum tunnel works fast again on us-west-1, but we surfaced a customer-facing reliability bug that gates TestFlight: when the iOS NetworkExtension wedges (e.g. after a server restart or network change), iOS's toggle-VPN switch does not recover it. Implementing in-NE health monitoring + `cancelTunnelWithError` self-restart is now P0 before any TestFlight invitation.

---

## TL;DR

- **Session 3's stated #1 priority — make `setup.sh` idempotent for servers with appended peers — is DONE.** Commit `a24034a` (preceded this session) preserves existing `wg0.conf` and `server.toml` on re-runs. The user pushed it during their validation re-run.
- **Discovered + fixed: TCP MSS clamping was missing on us-west-1.** `ufw --force reset` in `setup.sh` flushes every iptables table including mangle FORWARD, where MSS clamp lives. Without it, TCP through `wg0` (MTU 1420) suffers fragmentation/PMTUD blackhole — tunnel "works" but page loads crawl. Fix shipped in commit `5944c90`: heredoc gets MSS PostUp/PostDown for new deploys, `ensure_mss_clamp_in_wg_conf()` back-fills existing configs, post-UFW iptables block re-applies rules without dropping the tunnel.
- **us-west-1's `/etc/wireguard/wg0.conf` was back-filled in place** with timestamped backup. Live iptables rules verified active (4 IPv4+IPv6 TCPMSS rules in mangle FORWARD). Tunnel was kept running throughout — no PSK rotation gap.
- **Discovered: iOS NE process wedges after server-side WG restart.** App shows "connected", PQC rotation counter shows 1, but `tcpdump` confirmed iPhone was sending zero packets to the server. Toggling the VPN switch in the app does not recover (iOS reuses the same NE process). Profile delete + re-import in iOS Settings does recover (forces fresh NE process). This is unacceptable as a customer recovery path.
- **The architecture for fixing the wedge is defined; implementation is the next session's first big piece of iOS work.**

---

## What shipped this session

Two commits on `wg-upstream-fork`, both pushed to origin.

### 1. `a24034a` — `ops: setup.sh idempotency — preserve existing wg0.conf and server.toml on re-run`

**This was committed in session 3's tail end but had not yet been pushed; the user pushed it during their re-run on us-west-1.** Validates safely as a re-run script. Adds `--force-reset-configs` opt-in for the rare destructive case. Skips `cat >wg0.conf` and `cat >server.toml` heredocs when those files already exist non-empty.

The validation re-run is what surfaced the MSS-clamp regression below — the idempotency commit itself works correctly.

### 2. `5944c90` — `fix(server): TCP MSS clamping on wg0 (tunnel works but pages slow)`

Three changes in `server/scripts/setup.sh`:

1. **`wg0.conf` heredoc gains MSS clamp PostUp/PostDown** for fresh deployments. 4 PostUp lines (IPv4 in/out + IPv6 in/out) and 4 corresponding PostDown lines, all in the `[Interface]` section.

2. **`ensure_mss_clamp_in_wg_conf()` function** — back-fills the same MSS lines into existing configs that pre-date the fix. The idempotency path preserves `wg0.conf` verbatim, so without this injection step, already-deployed regions never pick up the fix on a re-run. Uses `awk` to insert MSS lines just before the first `[Peer]` block, preserves all existing peers, keeps a timestamped backup. Idempotent (no-op if the lines are already present).

3. **Direct `iptables -A FORWARD ... TCPMSS` re-apply after `ufw --force enable`.** UFW reset flushes every iptables table, so even with PostUp lines in `wg0.conf`, the rules stay flushed until `wg-quick` is restarted — which we deliberately don't do on a re-run because that would drop the live tunnel for ~120s while rosenpass re-establishes a PSK. The direct apply uses `-C` for idempotency so re-runs don't stack duplicates.

### 3. us-west-1 manual back-fill (production deploy)

Ran `ensure_mss_clamp_in_wg_conf` against `/etc/wireguard/wg0.conf` on us-west-1 directly (without re-running setup.sh). Original config saved at `/etc/wireguard/wg0.conf.bak.20260427T170926Z`. `wg-quick strip wg0` validated the new config parses cleanly. Tunnel was NOT restarted — the ephemeral iptables rules from the recovery moments earlier kept user-facing TCP fast. PostUp lines will fire on next reboot or `systemctl restart wg-quick@wg0.service`.

---

## The MSS clamp story (full detective trail)

**Symptom (user-reported, 16:50 UTC):** Just re-ran `setup.sh` on us-west-1 to validate idempotency. Tunnel reconnected, PSK rotates every ~2 min, `wg show` looks healthy — but Safari pages load slowly compared to yesterday.

**Diagnostic snapshot (server-side):** Everything that wasn't MSS clamping looked fine:
- `wg0.conf` peer count: 2 (preserved correctly by idempotency commit) ✓
- `server.toml [[peers]]` count: 1 (preserved) ✓
- All 3 services active (wg-quick@wg0, cloak-rosenpass, cloak-psk-installer) ✓
- iPhone peer connected, last handshake 13s ago, 152 MiB sent ✓
- PSK rotation cycle alive (logs show `output-key ... exchanged` every ~120s, psk-installer applying) ✓
- Server's own internet fast (`curl https://www.google.com` from box: 86ms total) ✓
- `iptables -t nat POSTROUTING`: MASQUERADE rule present ✓
- conntrack: 49/65536 (way under limit) ✓
- `iptables -t mangle FORWARD`: **EMPTY** ❌ ← smoking gun

**Root cause:** `ufw --force reset` at line 388 of `setup.sh` flushes all iptables tables (filter, nat, mangle, raw), including any MSS clamp rules. The original `setup.sh` did not re-add MSS clamping after the UFW reset. So every re-run of `setup.sh` against an already-deployed server silently strips MSS clamping.

**Why pages slow but not broken:** Without MSS clamping, the iPhone negotiates TCP MSS based on its local MTU (1500 from wifi/cellular). Server-bound TCP segments are too large for the wg0 MTU (1420). Result: fragmentation OR — more commonly — a PMTUD blackhole when intermediate middleboxes drop ICMP "fragmentation needed" replies. TCP retransmits + slow recovery = sluggish page loads. Tunnel still appears healthy at the WG layer because keepalives and small packets get through fine.

**Why was it fast yesterday?** Either the rules were added manually (or by a previous setup.sh revision that included them) at some earlier point, then wiped on today's re-run. Or yesterday's network path happened to not trigger the PMTUD blackhole. The fix is correct regardless of how the rules originally got there.

**The repair sequence:**
1. **Stage 1 (ephemeral, 17:08 UTC):** Applied 4 iptables commands directly: `iptables -t mangle -A FORWARD {-i,-o} wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu` + IPv6 equivalents. User confirmed: pages snapped back to fast.
2. **Stage 2 (permanent, 17:09 UTC):** Edited `setup.sh` with the three changes above; tested the awk back-fill against a synthetic copy of us-west-1's actual `wg0.conf`; ran the back-fill against the live `wg0.conf` (with timestamped backup); verified `wg-quick strip wg0` parses; committed as `5944c90` and pushed.

**Verification post-fix:**
- mangle FORWARD: 2 IPv4 TCPMSS rules + 2 IPv6 TCPMSS rules (counters confirmed both `-i wg0` and `-o wg0` matching real traffic)
- `/etc/wireguard/wg0.conf`: 8 MSS clamp lines persisted (4 PostUp + 4 PostDown)
- Backup retained at `/etc/wireguard/wg0.conf.bak.20260427T170926Z`

---

## The trap that ate the second half of the session — iOS NE wedge

**Symptom (user-reported, ~17:18 UTC):** "I went and tested the connection now its VERY slow and I haven't reached test-ipv6.com in over 2 minutes."

**This was NOT caused by the MSS-clamp work.** The MSS rules were verified working (737 IPv4 packets matched, no errors). But after the user's earlier "tested briefly, confirmed fast, then walked away to type the message" gap of a few minutes, the iPhone went idle, missed several rosenpass rotations, and woke up unable to re-establish the tunnel.

**The subtle, dangerous diagnostic state:**
- `wg show wg0`: peer endpoint visible, `latest handshake: 8 minutes, 4 seconds ago`, transfer counters frozen at the values from before the user's idle period (24.11 MiB / 281.49 MiB)
- iPhone endpoint port had cycled from `:57869` → `:50514` → `:59230` → `:63347` (so iPhone was reconnecting at the WG socket layer)
- Server's rosenpass log showed exchanges still happening: `output-key peer ... exchanged` at 17:11:51, 17:14:49, 17:17:16
- The user's iPhone Cloak app showed `PQC: 1 rotation`
- `tcpdump -i eth0 'udp port 51820'` for 5s: **0 packets**
- `tcpdump -i eth0 'udp port 9999'` for 5s: **0 packets**

**That last bullet is the kill shot.** The iPhone wasn't actually transmitting anything. The "endpoint" line in `wg show` was just stale — the last seen IP:port, not currently active. The iPhone-side NE was wedged into a state where it believed itself connected but had stopped actually sending packets.

**What we tried, in order:**

1. **Option A — Toggle VPN off/on in the Cloak app** (least invasive). User: "didn't work." Endpoint port changed once more (`:50514` → `:59230` per logs), confirming the toggle DID trigger reconnect at the WG socket layer — but no actual handshake completed.
2. **Option B — `systemctl restart wg-quick@wg0.service`** (server-side fresh state). All services came back, MSS PostUp re-fired (rule counts back to 2 IPv4 + 2 IPv6), MASQUERADE re-applied, iPhone endpoint immediately appeared at `:63347`. But again: zero packets received in tcpdump's 5-second window. PSK on server still from the LAST exchange before restart (17:20:11), no fresh rosenpass exchange since.
3. **Option C — Delete VPN profile in iOS Settings, re-import** (user-initiated). **This worked.** Tunnel came back, traffic flowed.

**Why toggle doesn't work, and why profile delete does:**

iOS reuses the same NetworkExtension process across `start/stopVPNTunnel()` cycles within the same configuration. When the user toggles, iOS calls `stopTunnel()` then `startTunnel()` callbacks on the SAME NE process — one whose internal state may already be corrupted (stale wireguard-go peer state, dead UDP sockets, stuck rosenpass FFI session, etc.).

`systemctl restart wg-quick` on the server side doesn't help because the iOS NE doesn't notice the server-side teardown. It keeps trying to communicate to the server with whatever stale ephemeral keys it has, and the server (with fresh state) ignores those packets.

Removing the VPN profile from iOS Settings causes iOS to tear down the NETunnelProviderManager entirely, **which kills the NE process**. Re-importing creates a fresh NE process with no stale state. New process = fresh `PacketTunnelProvider` instance = fresh wireguard-go = fresh rosenpass FFI = clean reconvergence.

**This is unshippable as a customer recovery path.** No real user will tolerate "if the tunnel gets weird, go to Settings, delete the VPN, come back to the app, re-import the config."

---

## The architecture for fixing the NE wedge (P0 before TestFlight)

Captured in detail in task #10. Four layers, three required, one optional.

### Layer 1 — Health monitor inside the NE

A `Timer.scheduledTimer` (or `DispatchSourceTimer`) inside `PacketTunnelProvider` that runs every 15-30s and checks:
- `connection.fetchLastDisconnectError` — any reported error?
- WG transfer-byte counter delta since last check (queryable via `wgPeek` / `wgGetConfig` from WireGuardKitGo). If both directions stagnant for >30s, suspect.
- Last successful WG handshake timestamp (also queryable). If >120s, suspect.
- Rosenpass exchange last-success timestamp (RosenpassBridge can expose this). If >180s and PQC rotations have failed, definitively wedged.

A wedge is declared when 2 of those signals trip simultaneously for >30s. Single-signal trips are downgraded to "suspicious; recheck in 15s" to avoid false positives on legitimately slow networks.

### Layer 2 — Self-killing the NE on wedge

When health monitor declares a wedge, the NE calls `self.cancelTunnelWithError(...)`. This is the documented iOS API for the NE to signal that it cannot continue. iOS:
- Terminates the NE process cleanly
- Marks the NETunnelProviderManager status as disconnected
- Re-spawns a fresh NE process on next `startVPNTunnel()` call

This is the programmatic equivalent of what the user did manually with profile delete + re-import — but without the user having to leave the app, and without the iOS permission prompt that profile re-creation would trigger.

### Layer 3 — Honest UI + auto-restart in the host app

Host app subscribes to `NEVPNStatusDidChangeNotification`. When status flips to disconnected (because Layer 2 killed the NE), automatically calls `connection.startVPNTunnel()` to bring it back.

UI changes:
- "PQC: N rotations ✓" should only increment on **server-confirmed** exchanges, not local FFI invocations. Otherwise the user sees a counter that was last updated before a wedge and no longer reflects reality.
- Status display should differentiate "connected and traffic flowing" vs "connected but stale" vs "reconnecting". The latter two should be visually distinct so users know something's happening even if it's invisible.
- Add a "Last data: 5s ago" or similar staleness indicator pulled from the NE's transfer counters.

### Layer 4 (optional, manual escape hatch) — "Reset Tunnel" button

For the case where Layers 1-3 fail (rare, but possible — e.g. iOS-side NE corruption that survives `cancelTunnelWithError`), a button in the host app that:
1. Calls `removeFromPreferences` on the existing manager
2. Constructs a new `NETunnelProviderManager` with identical config
3. `saveToPreferences` (this DOES require user permission — iOS will prompt "Allow Cloak VPN to add VPN configurations?")
4. Calls `startVPNTunnel`

One tap (plus one permission prompt) replaces the multi-step Settings dance.

### Estimated effort

- Layer 1: ~1-2 days (the hard part is choosing thresholds that don't cause spurious restarts on slow cellular networks, and exposing the right counters from WireGuardKitGo + RosenpassBridge)
- Layer 2: ~half day (`cancelTunnelWithError` is a one-liner, but you need to be careful about not causing infinite restart loops if the wedge is actually a real network outage)
- Layer 3: ~1-2 days (UI work + counter plumbing)
- Layer 4: ~half day

**Total: ~5-7 days of iOS work.** This is gating TestFlight invitation.

---

## Current working state

```
Branch:            wg-upstream-fork
HEAD:              5944c90 (fix(server): TCP MSS clamping on wg0)
Working tree:      clean (after this handoff is committed)
Pushed to origin:  YES (da3b30a..5944c90 pushed during session)
Stashes:           stash@{0} on main (older session-1 debugging — leave alone)
RosenpassFFI:      --release build, in xcframework, unchanged this session
On-device app:    installed and running on the user's iPhone 17,2 / iOS 26.4.2
                   — RECOVERED via iOS Settings profile delete + re-import
Active tunnel:    iphone-prod-1 ↔ us-west-1, PQC rotating, traffic flowing
```

**Server state (us-west-1, `5.78.203.171`):**
- `cloak-rosenpass.service`: active (Classic McEliece + ML-KEM listener on UDP 9999)
- `cloak-psk-installer.service`: active (inotify watcher on `/run/rosenpass/psk-*`)
- `wg-quick@wg0.service`: restarted in this session (~17:20 UTC)
- `/etc/wireguard/wg0.conf`: now contains MSS PostUp/PostDown lines (8 total). Backup at `wg0.conf.bak.20260427T170926Z`
- `iptables -t mangle FORWARD`: 2 IPv4 + 2 IPv6 TCPMSS rules active
- `iptables -t nat POSTROUTING`: MASQUERADE for 10.99.0.0/24 → eth0 active

**Other regions (fi1, de1, us-east-1):** unknown MSS-clamp state. Tracked as task #11. Re-running `setup.sh` on each will inject the MSS lines via the new back-fill function, then the post-UFW direct iptables block will re-apply the rules without restarting the tunnel.

---

## What's left — recommended priorities

Updated TaskList from session 3, with session 4 outcomes. Active task numbers in the in-session task list, in case the next session keeps continuity:

```
✅ Setup.sh idempotency for servers w/ peers          — CLOSED (a24034a, this session pushed it)
✅ Diagnose post-setup.sh slow page loads on us-west-1 — CLOSED (MSS clamp regression)
✅ Permanent MSS-clamp fix: setup.sh + back-fill us-west-1 — CLOSED (5944c90)
🚨 #10. iPhone NE wedge auto-recovery (gates TestFlight) — NEW P0. Layers 1-4 above.
⏳ #11. Back-fill MSS clamp on fi1, de1, us-east-1     — quick win, ~15 min, run setup.sh on each
⏳ #2.  IPv6 leak audit (test-ipv6.com vs ipv6-test.com) — still pending, small
⏳ #3.  Native in-app provisioning UI (Phase 1→2)      — large, ~2-3 weeks. See session 3 handoff.
⏳ #4.  App Store / TestFlight readiness pass           — BLOCKED by #10. Cannot ship a
                                                          tunnel that requires Settings-based
                                                          recovery to TestFlight users.
⏳ #5.  Multi-region picker UI                          — medium, can wait
```

**Suggested next session priorities, in order:**

1. **Implement Layer 1 (NE health monitor) and Layer 2 (`cancelTunnelWithError`).** These two together unblock TestFlight. Layer 3 and Layer 4 are polish that can land in subsequent sessions but should be done before public launch.
2. **Back-fill MSS clamp on fi1, de1, us-east-1** as a 15-minute warm-up before tackling iOS work. Just SSH in and re-run `setup.sh`. The new back-fill is idempotent and non-disruptive.
3. **Once Layer 1+2 are done, return to native in-app provisioning UX.** That's the main TestFlight enabler from session 3's planning.
4. **IPv6 leak audit** can slot in opportunistically — it's small and self-contained.

---

## Things definitively learned this session (do not re-debate)

Additions to session 3's "things learned" list:

- **`ufw --force reset` flushes every iptables table.** Including `mangle`, `nat`, `raw`, `filter`. Any non-UFW iptables additions (MSS clamping, custom MASQUERADE, port redirects, etc.) MUST be re-applied after every UFW reset, OR moved into a wg-quick PostUp hook AND followed by a `wg-quick down/up` to re-fire. `setup.sh` does the former (direct iptables re-apply after `ufw --force enable`) for MSS clamp.
- **Mullvad's WireGuard adapter uses MTU 1420 by default, not 1380.** Combined with default WG overhead (60 bytes outer IPv4+UDP+WG headers), this puts the inner TCP MSS ceiling at 1420 - 40 = 1380. Without MSS clamping, clients negotiating MSS=1460 (1500 LAN MTU - 40) will produce segments that exceed wg0's MTU, requiring fragmentation. The `iptables -t mangle ... TCPMSS --clamp-mss-to-pmtu` rule lets the kernel rewrite each SYN's MSS option to the real PMTU as the SYN traverses wg0.
- **Setting up MSS clamping in the wg0.conf PostUp hook is the canonical home for it,** but it ALSO has to be re-applied directly via `iptables` in `setup.sh` after `ufw --force enable`, because UFW reset wipes the rules and we can't restart wg-quick on every setup.sh re-run (would drop active tunnels for ~120s).
- **iOS NetworkExtension processes can wedge into a "ghost connected" state** after the WG handshake fails (e.g. due to server restart or PSK desync). Symptoms: `wg show` on server shows old endpoint with stale handshake timestamp; iPhone's app shows "connected" + a stale PQC rotation counter; `tcpdump` confirms zero packets actually leaving the iPhone.
- **Toggling the VPN switch in the Cloak app does NOT recover an NE wedge.** iOS reuses the same NE process across toggle cycles. Only killing the NE process forces a fresh state. The user-facing recovery today is "delete VPN profile in iOS Settings, re-import config" — unacceptable for production.
- **The programmatic equivalent of profile delete + re-import is `cancelTunnelWithError(...)` called from inside the NE.** This is the API surface for Layer 2 of the wedge auto-recovery. It terminates the NE process; iOS re-spawns it on next start.
- **Server-side `systemctl restart wg-quick@wg0.service` is safe in the sense that all PostUp hooks re-fire** (MSS clamp + MASQUERADE both verified to come back automatically). But it's destructive to active tunnels — peers must complete a fresh handshake AND a fresh rosenpass exchange before traffic resumes. Do not restart wg-quick on a region with real users connected unless it's a recovery escalation. There's no way to selectively reset one peer without restarting the interface.

---

## Useful diagnostic commands (additions)

### Verify MSS clamp is active on a region

```bash
ssh -i ~/.ssh/cloakvpn_ed25519 root@<region-ip> '
  echo "--- mangle FORWARD ---"
  iptables  -t mangle -L FORWARD -n -v --line-numbers
  ip6tables -t mangle -L FORWARD -n -v --line-numbers
  echo "--- wg0.conf has MSS lines? ---"
  grep -c TCPMSS /etc/wireguard/wg0.conf
'
# Expect: 2 IPv4 + 2 IPv6 TCPMSS rules in mangle FORWARD
# Expect: 8 MSS clamp lines in wg0.conf (4 PostUp + 4 PostDown)
```

### Detect an NE wedge from server side

```bash
ssh -i ~/.ssh/cloakvpn_ed25519 root@<region-ip> '
  echo "--- iPhone endpoint + handshake age ---"
  wg show wg0 | grep -E "endpoint|handshake|transfer"
  echo "--- packets from iPhone in last 5s ---"
  timeout 5 tcpdump -i eth0 -nn "udp port 51820" -c 100 2>&1 | tail -20
  timeout 5 tcpdump -i eth0 -nn "udp port 9999" -c 100 2>&1 | tail -20
'
# Wedge signature: handshake age > 120s, transfer counters frozen,
# tcpdump captures zero packets despite endpoint visible in wg show.
```

### Force a clean tunnel reconvergence (server-side)

```bash
ssh -i ~/.ssh/cloakvpn_ed25519 root@<region-ip> 'systemctl restart wg-quick@wg0.service'
# WARNING: drops the live tunnel for ~120s while rosenpass re-exchanges.
# Use ONLY when an NE wedge has been confirmed and the iPhone-side
# user is willing to do a profile delete+reimport in parallel.
# After Layer 1+2 of the auto-recovery work lands, this will be
# unnecessary — the iPhone NE will detect and recover on its own.
```

### Customer-facing recovery (today, manual)

Document this for the user explicitly until Layer 1+2 are shipped:
1. iPhone Settings → General → VPN & Device Management → Cloak VPN config → tap "Delete VPN".
2. Open the Cloak app. It will re-create the VPN profile. Tap "Allow" on the iOS permission prompt.
3. Tunnel reconnects within ~30 seconds. PQC counter starts ticking from 0 again (this is expected — fresh NE process).

---

## Final notes

This session shipped two real fixes (idempotency + MSS clamp), validated the previous session's idempotency commit on a live region, and surfaced the most important pre-TestFlight blocker we've seen since session 1's WG-decryption-failure bug. The technical core of Cloak VPN works. The reliability story has one concrete gap that's now scoped and waiting for implementation.

The user has been at this for a long, long time across 4 sessions. The pattern of "things keep breaking in subtle ways" is the natural consequence of integrating two complex protocols (WireGuard + post-quantum Rosenpass) on a stack (iOS NetworkExtension) that has its own quirks and was never designed for either of them. Each session has knocked out one or two specific failure modes. The wedge auto-recovery work is the last big infrastructure piece before the product stops feeling fragile. After that, the work is mostly UX (provisioning, multi-region picker, App Store prep) — visible-progress work that is rewarding to ship.

If anything regresses next session, the failure mode tree is now (in approximate likelihood order, today):

1. **iPhone NE wedge** → delete + re-import VPN profile in Settings (recovery procedure above). Until Layer 1+2 ships, this is the user-facing dance.
2. **Tunnel works but pages slow** → check `iptables -t mangle FORWARD` for TCPMSS rules. If empty, run `iptables -t mangle -A FORWARD {-i,-o} wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu` to recover ephemerally; check `wg0.conf` for PostUp lines for permanence.
3. **Tunnel won't establish at all** → first try `wg show wg0` for handshake age; if old, follow the wedge-detection diagnostic above. If `tcpdump` shows iPhone is sending packets but server isn't responding, check rosenpass service status, server pubkey, UFW.
4. **App crashes on launch after FFI rebuild** → built with `--debug`. Use `--release`. (Session 2/3 trap, build script defaults to release now.)

Good luck. — Claude (Session 4, 2026-04-27 ~17:30 UTC)
