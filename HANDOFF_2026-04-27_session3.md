# Cloak VPN — Session Handoff #3

**Date:** 2026-04-26 (~20:30 HST → 21:00 HST)
**Session length:** ~2 hours
**Status:** ✅ **PQC end-to-end working on iPhone.** Custom NE handles WireGuard, rosenpass UDP relay through NE, and PSK rotation. Validated against us-west-1 with continuous 120s rotations and full-tunnel traffic flowing.

> **One-line summary for the next session:** The technical core of Cloak VPN works. Three commits on `wg-upstream-fork` deliver post-quantum WireGuard end-to-end on iOS 26.4. What's left is product polish, ops hardening, and the longer-term roadmap items.

---

## TL;DR

- **The 19-hour bug from Session 1** (custom NE doesn't carry traffic) — **FIXED in Session 2**, committed at `514d4ab`. Mullvad's WG fork removed `setTunnelNetworkSettings`; we call it ourselves before `adapter.start`.
- **The crash-on-launch bug from Session 2** (rebuilt FFI poisons the app) — **FIXED in Session 3** by rebuilding the xcframework with `--release`. The diagnosis Session 2 latched onto (uniffi version drift) was wrong. Real cause: McEliece-460896 zero-buffer materialized on stack in debug mode, overflowing iOS's 1 MB main-thread stack.
- **PQC opcodes 0x02–0x04 + V03 InitConf fix from `stash@{0}`** — **APPLIED and COMMITTED** in Session 3.
- **Server-side wiring** (re-register iPhone rosenpass pubkey, restart `cloak-rosenpass.service`, restart `cloak-psk-installer.service` which Session 2 found dead) — **DONE.**
- **End-to-end validation** — `test-ipv6.com` shows `5.78.203.171`, server logs show 2-minute rosenpass rotations applying to wg0 cleanly.

---

## Session 3 work — what shipped

Three commits on top of `514d4ab` on branch `wg-upstream-fork`, pushed to origin:

1. **`build(ios): default RosenpassFFI to --release; warn loudly on --debug`**
   - `clients/ios/RosenpassFFI/build-xcframework.sh`
   - Defaults to `--release`. Explicit `--debug` requires opt-in and prints a 5-second stack-overflow warning before continuing.
   - Why: see "The trap that ate Session 2" below.

2. **`ios: PQC end-to-end via rosenpass UDP relay through NE`**
   - `clients/ios/CloakTunnel/PacketTunnelProvider.swift` (+313)
   - `clients/ios/CloakVPN/RosenpassBridge.swift` (NETunnelTransport replaces UDPClient)
   - `clients/ios/CloakVPN/TunnelManager.swift` (+40, sendNE wiring)
   - `clients/ios/RosenpassFFI/src/lib.rs` (+33, V03 InitConf-before-DerivedPsk fix)

3. **`docs: Session 2 handoff — WG fix landed, PQC pending FFI rebuild`**
   - Adds `HANDOFF_2026-04-27_session2.md` for historical context.

4. **`ops: fold cloak-psk-installer into setup.sh as generic systemd service`** (commit `117934f`, added in Session 3 extension)
   - New file: `server/scripts/cloak-psk-installer.sh` — generic inotify watcher that handles ALL peers via filename-derived peer-name and `/etc/wireguard/<name>.pub` lookup. No per-peer scripts.
   - `server/scripts/setup.sh` updated to install both the script and a `cloak-psk-installer.service` systemd unit, add `inotify-tools` to apt, and clean up any pre-existing per-peer scripts from the manual deployment pattern.
   - Verified surgically on us-west-1 (without re-running setup.sh — see "Suggested next session priorities" #1 about why): old `cloak-psk-installer-iphone.sh` removed, new generic active, sub-second swap, PSK rotations uninterrupted.

`stash@{0}` (the PQC work-in-progress) was dropped after the commit landed. `stash@{1}` (older Session 1 evening debugging on `main`) remains untouched.

---

## The trap that ate Session 2 — and how to never repeat it

**Symptom:** Rebuilt RosenpassFFI xcframework crashes the app immediately on launch. iOS hides the icon after repeated crashes. Session 2 ran for ~5 hours hypothesizing uniffi version drift, rust toolchain drift, debug-vs-release toolchain ABI differences. Never captured a crash log.

**Real cause:** `rosenpass_secret_memory::public::Public<_>::zero()` in **debug builds** materializes a 524,160-byte (Classic McEliece-460896 public key size) zero-buffer **on the stack** before moving it into a `Box`. iOS's main-thread stack is 1 MB (Swift Concurrency detached tasks similar). 524 KB on-stack temp + frame overhead + stdlib frames blows through it. Result: `EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE` writing into the stack guard region.

**Why release builds work:** LLVM's RVO (return-value optimization) / copy-elision rewrites `Box::new([0u8; 524160])` to construct directly into the heap allocation. No stack temp. Stack stays well under 1 MB.

**Why session 2 missed this:**
- Never grabbed a device crash log. Without the stack trace, the diagnosis was speculative.
- "Critical test" of reverting source and rebuilding gave the same crash → concluded "environmental drift" → wrong layer of speculation.
- The build script defaulted to `--debug` ("faster iteration"); Session 1's working binary had been built with `--release` ("ship this") per the script's own comment. The flag flip was the variable that changed, not the rust toolchain.

**Confirmed crash signature (from this session's iOS Settings → Analytics Data):**
```
Exception Type:    EXC_BAD_ACCESS (SIGSEGV)
Exception Subtype: KERN_PROTECTION_FAILURE at 0x000000016ed538f0
SP:                0x000000016ed538f0   ← inside Stack Guard
faulting frame:    rosenpass_secret_memory::public::Public<_>::zero + 20
parent frame:      rosenpassffi::generate_static_keypair + 40
trigger:           TunnelManager.generateAndPersistLocalKeypair (called from app .task on launch)
```

**Lesson hardened in:**
- `clients/ios/RosenpassFFI/build-xcframework.sh` (defaults to `--release`, warns on `--debug`)
- This document
- The commit message of `build(ios): default RosenpassFFI to --release...`

**If a future Claude sees a "FFI rebuild crashes app on launch" pattern again:** first action is `Settings → Privacy & Security → Analytics & Improvements → Analytics Data` on the iPhone, find the most recent `CloakVPN-*.ips`, AirDrop to Mac, look at the stack trace. If SP is in a Stack Guard region and the trace involves any McEliece-sized type's `::zero()` or `::default()`, the answer is `--release`. Do not spend hours hypothesizing without that crash log.

---

## Current working state

```
Branch:            wg-upstream-fork (pushed to origin)
HEAD:              <session 3's last commit — see git log -1>
Working tree:      clean
Stashes:           stash@{0} on main (older session-1 debugging — leave alone)
                   (the PQC stash from Session 2 has been applied and dropped)
RosenpassFFI:      --release build, ~36 MB device + ~36 MB sim, in xcframework
On-device app:     installed and running on the user's iPhone 17,2 / iOS 26.4.2
Active tunnel:     iphone-prod-1 peer connected to us-west-1, PQC rotating every 120s
```

**Server state (us-west-1, `5.78.203.171`):**
- `cloak-rosenpass.service`: active (Classic McEliece + ML-KEM listener on UDP 9999)
- `cloak-psk-installer.service`: active (inotify watcher applies new PSKs to wg0)
- `/etc/rosenpass/iphone-prod-1.rosenpass-public`: 524160 bytes, current iPhone fingerprint `f9ff7fc45286fbe3`
- `wg show wg0`: peer `1TLOHHCBu/...` connected with active handshakes

---

## How to verify PQC is live (anytime)

**On the iPhone, in the Cloak app:** the gray info panel's third line should read `PQC: N rotations ✓` where N increments every ~120s.

**On the server, two-pane log:**
```bash
ssh -i ~/.ssh/cloakvpn_ed25519 root@5.78.203.171 \
  'journalctl -fu cloak-rosenpass.service & journalctl -fu cloak-psk-installer.service & wait'
```

You should see paired entries every 2 minutes:
```
rosenpass: output-key peer pDJIFPYf...= key-file "/run/rosenpass/psk-iphone-prod-1" exchanged
cloak-psk-installer: PSK rotated for iphone-prod-1
```

**End-to-end traffic check:** Safari on iPhone → `https://test-ipv6.com` → must show `5.78.203.171`. If it shows the user's NAT IP, traffic is leaking around the tunnel (different bug class — see Session 1 handoff for the bypass-rosenpass-server fix in `excludedRoute`).

---

## Server access

**SSH:**
```bash
ssh -i ~/.ssh/cloakvpn_ed25519 root@5.78.203.171
```

**Other regions:** `infra/terraform/regions/<region>/terraform.tfvars`. Active regions: fi1, de1, us-east-1, us-west-1.

**iPhone pubkey re-registration cycle** (needed after every app uninstall — App Group container wipes, `ensureLocalKeypair` regenerates):

1. In the Cloak app → **Your PQC Identity** panel → tap **Share my public key…** → AirDrop to Mac.
2. On Mac:
   ```bash
   scp -i ~/.ssh/cloakvpn_ed25519 ~/Downloads/cloakvpn-pubkey-*.b64 root@5.78.203.171:/tmp/iphone-new.b64
   ```
3. On server:
   ```bash
   base64 -d /tmp/iphone-new.b64 > /etc/rosenpass/iphone-prod-1.rosenpass-public
   chmod 600 /etc/rosenpass/iphone-prod-1.rosenpass-public
   stat -c '%s' /etc/rosenpass/iphone-prod-1.rosenpass-public  # MUST be 524160
   systemctl restart cloak-rosenpass.service
   ```

---

## What's left — recommended priorities

Updated TaskList from the Session 1 + Session 2 handoffs, with Session 3 outcomes:

```
✅ #11. Investigate iPhone WG decryption failure        — CLOSED (Session 2 fix)
✅ #6.  Tunnel rosenpass UDP through wg0 (Option D)     — CLOSED (Session 3 commit)
✅ #7.  Verify Option D on iPhone                       — CLOSED (validated this session)
✅ #8.  Commit Option D refactor                        — CLOSED
✅ #9.  Rebuild FFI with V03 InitConf fix               — CLOSED (release build)
✅ #12. Server-side rosenpass not committing PSK        — CLOSED (was psk-installer being dead;
                                                          restarted & verified rotating)
✅ #13. Fork upstream WG iOS                            — OBSOLETE (Session 2's compensation
                                                          fix made forking unnecessary)
🟢 #1.  Validate client-keygen smoke test               — DONE
🟢 #4.  Scaffold US East + US West regions              — DONE
🟢 #5.  includeAllNetworks=true                         — DONE

✅ #10. Fold cloak-psk-installer into setup.sh          — CLOSED in commit 117934f (Session 3
                                                          extension). Generic over peers; no per-peer
                                                          scripts; inotify watcher; verified surgically
                                                          on us-west-1 with no rotation gap.
⏳ #14. Make setup.sh idempotent for servers w/ peers   — NEW TOP PRIORITY. setup.sh currently
                                                          overwrites /etc/wireguard/wg0.conf and
                                                          /etc/rosenpass/server.toml from scratch each
                                                          run, wiping any peers added via add-peer.sh.
                                                          Without this fix nobody can safely re-run
                                                          setup.sh after a region has real peers.
⏳ #2.  Native in-app provisioning (Phase 1→2)          — PENDING (large; ~2-3 weeks)
⏳ #3.  Fix IPv6 leak                                   — PENDING (separate from main IP leak)
```

**Suggested next session priorities, in order:**

1. **Make `setup.sh` idempotent for servers with appended peers** (NEW top priority — surfaced by Session 3 deployment of psk-installer). Currently `setup.sh` overwrites `/etc/wireguard/wg0.conf` and `/etc/rosenpass/server.toml` from scratch each run, which would wipe peers added later via `add-peer.sh`. Fix: detect existing configs, only seed `client1` if absent, preserve appended `[Peer]` / `[[peers]]` blocks. Without this, nobody can safely re-run setup.sh on a region after it's been provisioned with real peers — including to pick up future setup.sh changes (like the psk-installer fold-in we shipped this session, which had to be deployed surgically as a result).

2. **Add a basic onboarding/provisioning UI** so the user doesn't have to manually scp + base64 their pubkey to the server. Something like: app generates pubkey → POSTs to a Cloak API → API runs `add-peer.sh` → returns config → app imports automatically. This is the path to Phase 1 → Phase 2.

3. **IPv6 leak audit.** `test-ipv6.com` shows the IPv4 server IP, but a separate test (`ipv6-test.com`) might reveal IPv6 leaking. Worth verifying with `includeAllNetworks=true` set.

4. **App Store / TestFlight prep** — entitlements, App Store Connect setup, screenshots, privacy manifest, etc. The technical core is done; product packaging is now the gate.

5. **Multi-region picker in the UI** — currently the user pastes a region-specific config. The UI could list available regions from a Cloak API and let the user pick.

---

## Things definitively learned (do not re-debate)

These are validated through Sessions 1, 2, and 3 — please don't burn time re-testing:

- **Mullvad's `WireGuardAdapter.start()` does not call `setTunnelNetworkSettings`.** We compensate from `PacketTunnelProvider`. Keep this fix (commit `514d4ab`).
- **Upstream wireguard-apple as a SwiftPM dep is broken** (Package.swift has a 2023-era manifest bug that SwiftPM rejects). Don't switch to upstream; we're permanently on Mullvad's fork with our compensation.
- **RosenpassFFI xcframework MUST be built with `--release` for iOS.** Debug builds crash with stack overflow on the first FFI call. Build script now defaults to `--release` and warns loudly on explicit `--debug`.
- **Rosenpass V03 protocol is 1.5-RTT** (InitHello → RespHello → InitConf). Server only commits PSK after receiving InitConf. The FFI's `handle_message` must send InitConf bytes (returned in `result.resp`) BEFORE surfacing the derived PSK to the caller. The fix is in `lib.rs handle_message`: stash PSK in `last_psk`, return `SendMessage(InitConfBytes)`, expose PSK via `last_derived_psk()`.
- **PQC keys are too big for `providerConfiguration`** (~700 KB McEliece pubkey). They live in the App Group container via `AppGroupKeyStore`, never in NETunnelProviderProtocol's dictionary.
- **The user's iPhone-side `excludedRoute` for the rosenpass server IS necessary.** Without it, rosenpass UDP loops through utun (which depends on the PSK we're trying to derive — chicken/egg). Confirmed via tcpdump on the server during Session 2.
- **App Group container wipes on every uninstall.** `ensureLocalKeypair` regenerates the rosenpass keypair on next launch. Server-side pubkey re-registration is required after every reinstall (see "iPhone pubkey re-registration cycle" above).
- **iOS deployment target = 26.4 is correct, not a bug.** Apple's year-based versioning means iOS 26 is the current release in 2026. The user's iPhone runs iOS 26.4.2.

---

## Useful diagnostic commands

### iPhone crash log retrieval
1. iPhone → **Settings → Privacy & Security → Analytics & Improvements → Analytics Data**.
2. Scroll to find `CloakVPN-*.ips` entries.
3. Tap most recent → Share icon (top right) → AirDrop to Mac.
4. The first ~80 lines (everything before `Binary Images:`) contain the diagnostic gold.

### Live server-side observability
```bash
# Two-pane rosenpass + psk-installer log stream
ssh -i ~/.ssh/cloakvpn_ed25519 root@5.78.203.171 \
  'journalctl -fu cloak-rosenpass.service & journalctl -fu cloak-psk-installer.service & wait'

# wg state snapshot
ssh -i ~/.ssh/cloakvpn_ed25519 root@5.78.203.171 'wg show wg0; wg showconf wg0 | grep -i preshared'

# Verify PSK actually applied to the peer
ssh -i ~/.ssh/cloakvpn_ed25519 root@5.78.203.171 \
  'wg showconf wg0 | grep -A1 "1TLOHHCBu" | head -5'
```

### Cargo / FFI debugging
```bash
# Check what the static lib actually exports (uniffi contract verification)
nm "/Users/agentworker2/Documents/Claude/Projects/Cloak VPN App - Business Opportunity/cloak-vpn/clients/ios/RosenpassFFI.xcframework/ios-arm64/librosenpassffi.a" \
  | grep uniffi_rosenpassffi_checksum_func | head -10

# Sanity-check the xcframework slice sizes (should be ~36 MB each in release)
ls -la "/Users/agentworker2/Documents/Claude/Projects/Cloak VPN App - Business Opportunity/cloak-vpn/clients/ios/RosenpassFFI.xcframework"/*/librosenpassffi.a
```

### Full-tunnel egress verification
- iPhone Safari → `https://test-ipv6.com` → must show `5.78.203.171` (or whichever region you're connected to).
- Backup: `https://ipinfo.io/ip` → same expected output.

---

## Final notes

The user has been extremely patient through three sessions. The technical hard parts are now done — the post-quantum + WireGuard pipeline works, the build infrastructure is hardened against the McEliece-stack trap, and the server side is deployable across regions with one task pending (psk-installer in setup.sh).

The next session should be either ops hardening (psk-installer fold-in, IPv6 leak audit) or product work (provisioning UX, App Store prep), depending on the user's near-term goals. There is no longer a technical blocker preventing this from going to TestFlight after a polish pass.

If anything regresses, the failure modes are likely:
1. **App crashes after FFI rebuild** → built with `--debug`. Use `--release`.
2. **PQC stuck at handshaking** → server's registered iPhone pubkey is stale. Re-register via the cycle above.
3. **Tunnel up but no traffic** → `psk-installer` not running, OR `excludedRoute` for rosenpass server missing in `makeNetworkSettings`.
4. **Tunnel won't even establish handshake** → check the user's iPhone iOS version against the deployment target; verify the WG private key matches what's registered on the server.

Good luck. — Claude (Session 3, 2026-04-26 ~21:00 HST)
