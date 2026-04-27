# Cloak VPN — Session Handoff Document

**Last updated:** 2026-04-27 ~03:00 HST (after ~19-hour debugging marathon)
**Status:** ⚠️ Our iOS app's NetworkExtension is BROKEN. Server-side infrastructure is FINE. Workaround in place.

This document is the canonical pickup point for any new session. Read it top to bottom before doing anything else.

---

## TL;DR for the next session

- **Server side is solid.** us-west-1 (Hetzner Hillsboro, `5.78.203.171`) is fully configured: WG, rosenpass daemon, MASQUERADE, forwarding all working.
- **Our iOS app's NE doesn't carry traffic.** WG handshake completes, encrypted bytes flow at the wire layer, but Safari sees "iPhone is not connected to the internet" with `includeAllNetworks=true`. Without `includeAllNetworks`, traffic leaks via ISP (no protection).
- **The official WireGuard iOS app works perfectly** with the same WG keys against the same server on the same network. We've definitively isolated the bug to OUR app's NE.
- **Working workaround tonight:** the user is using the official WireGuard App Store app + a wg-quick config we generated from the server. Has internet, has IP-leak protection, but no PQC.
- **Tomorrow's recommended approach:** **Option 2 — fork upstream wireguard-apple sample app as the new base**, port our PSK push opcode and rosenpass integration onto IT instead of our custom NE. The upstream app handles all the iOS subtleties we've been chasing. ~1-2 days of work.

---

## What works (committed, validated)

### Server infrastructure
- **fi1** (Hetzner Helsinki) — original server, validated PQC against earlier
- **de1** (Hetzner Falkenstein) — earlier session
- **us-east-1** (Hetzner Ashburn, cpx21) — deployed today, terraform in `infra/terraform/regions/us-east-1/`
- **us-west-1** (Hetzner Hillsboro, cpx11, IP `5.78.203.171`) — deployed today, fully configured
- All servers run `setup.sh` which: pins rosenpass to git rev `b096cb1`, installs rustup if needed, configures WG with iptables MASQUERADE, sets `net.ipv4.ip_forward=1`, configures UFW with `route allow` for wg0→eth0
- **us-west-1 specifically has** `cloak-psk-installer.service` deployed (inotify watcher that copies `/run/rosenpass/psk-iphone-prod-1` into wg0 via `wg set` whenever rosenpass writes a new PSK). NOT YET in setup.sh — needs to be folded in (task #10).

### iOS — what's committed (`git log --oneline | head -1`)
Latest commit: `e117c1c Revert full-tunnel + host-app rosenpass attempt` (this morning's known-good state).

What's committed and works (in OFFICIAL WG iOS app via wg-quick config — NOT our app):
- ✅ Multi-region deploy (4 regions)
- ✅ Privacy fix: client-side rosenpass keypair generation (`ensureLocalKeypair`, `AppGroupKeyStore.saveLocalKeypair`)
- ✅ `add-peer.sh` accepts iPhone-uploaded pubkey
- ✅ Server pinning to rosenpass `b096cb1`

### What's UNCOMMITTED and BROKEN
All of today's evening work in `clients/ios/`:
- Option D NE-side rosenpass UDP relay (PacketTunnelProvider opcodes 0x02/0x03/0x04, NETunnelTransport in RosenpassBridge, sendNEMessage in TunnelManager)
- `includeAllNetworks=true` flip in TunnelManager
- FFI fix to lib.rs for V03 InitConf bytes
- Replaced PacketTunnelProvider with upstream-equivalent structure

These are uncommitted changes on top of `e117c1c`. **DO NOT git stash them** unless rolling back — they contain valuable architectural progress that should be salvaged into the upstream-fork base tomorrow.

Run `git status` to see exactly what's modified:
```bash
cd "/Users/agentworker2/Documents/Claude/Projects/Cloak VPN App - Business Opportunity/cloak-vpn"
git status
```

---

## The big bug we couldn't crack

**Symptom:** Our app's CloakTunnel NetworkExtension establishes a WG handshake, wireguard-go's data plane starts (TUN reader, decryption/encryption workers, etc.), keepalives flow every 25s, but Safari and other apps see "iPhone is not connected to the internet" when `includeAllNetworks=true`. With `includeAllNetworks=false`, traffic leaks via ISP (test-ipv6.com shows the user's NAT IP `<USER_NAT_IP>` instead of `5.78.203.171`).

**What we eliminated as the cause:**
- ❌ `WireGuardKitGo` linkage — verified via `nm` that `_wgTurnOn`, `_wgSetConfig`, `_wgPeek`, etc. ARE in `CloakTunnel.debug.dylib`
- ❌ `setTunnelNetworkSettings` override — removed it entirely (upstream WG iOS doesn't override either); no change
- ❌ `makeTunnelConfiguration` differences — agent verified our output is byte-equivalent to wg-quick parser output
- ❌ `enforceRoutes=true` — set it; no change
- ❌ Various exclude-flag combinations — tried both with and without overriding defaults; no change
- ❌ Stale iOS state — deleted VPN profile + uninstalled app + rebooted iPhone; no change
- ❌ Custom config parsing path — replaced our PacketTunnelProvider with code structurally identical to upstream's reference; still broken

**What this means:** the bug is at a level deeper than Swift source code — likely entitlements, signing, build phases, target setup, or Apple Developer Profile mismatch. We could not diagnose this remotely without live Xcode debugging.

**The diagnostic that finally pinpointed scope:** install the official App Store WireGuard iOS app, configure it with the SAME wg-quick config we'd been using (private key + server keys), connect, load `https://test-ipv6.com`. It shows `5.78.203.171` (server's IP). So the network/iPhone/server is healthy. Our app specifically is broken.

---

## Other latent bugs surfaced tonight

### Bug A: Server-side rosenpass doesn't write PSK to file (b096cb1 specific)
**Tracked as task #12.**

The rosenpass daemon at git rev `b096cb1` running on us-west-1 receives InitHello, sends RespHello back, but **never writes `/run/rosenpass/psk-iphone-prod-1`** despite `key_out` configured in `/etc/rosenpass/server.toml`.

Investigation by agent confirmed V03 protocol is **1.5-RTT** (InitHello → RespHello → **InitConf** → optional EmptyData ack), not 1-RTT. Server only commits PSK after receiving InitConf. We never see InitConf in tcpdump (only 2 packets per handshake instead of 3) — strong evidence iPhone-side FFI isn't sending it.

### Bug B: iPhone FFI drops InitConf bytes (our RosenpassFFI bug)
**Tracked as task #9.**

In `clients/ios/RosenpassFFI/src/lib.rs`, the `handle_message` function originally returned `StepResult::DerivedPsk` immediately when `result.exchanged_with` was Some, **dropping the `result.resp` bytes (InitConf)** that the server needs to commit.

Fix applied in `lib.rs` (uncommitted): now stashes PSK in `last_psk` and returns `SendMessage(InitConfBytes)`. Bridge in `RosenpassBridge.swift` updated to fetch PSK via `lastDerivedPsk()` after sending. The xcframework was rebuilt — **we verified `_wgTurnOn` etc. are in the binary**, but in tcpdump we still saw only 2 packets per handshake. Either:
- Build pipeline didn't fully propagate the FFI change, OR
- V03 at b096cb1 is genuinely 1-RTT and our hypothesis was wrong, OR
- Server-side daemon has a separate config issue

This bug fix is **secondary**; iOS app's NE bug must be fixed first before PQC can be tested end-to-end.

---

## Critical file state

**All paths absolute below. Read these before changing anything:**

### iOS app (broken)
- `/Users/agentworker2/Documents/Claude/Projects/Cloak VPN App - Business Opportunity/cloak-vpn/clients/ios/CloakTunnel/PacketTunnelProvider.swift` — REWRITTEN tonight to mirror upstream wireguard-apple's reference. Has opcode 0x01 (SET_PSK) for rosenpass PSK push. Does NOT have Option D opcodes 0x02/0x03/0x04 (those were in the previous version).
- `/Users/agentworker2/Documents/Claude/Projects/Cloak VPN App - Business Opportunity/cloak-vpn/clients/ios/CloakVPN/TunnelManager.swift` — `proto.includeAllNetworks = true`, no exclude-flag overrides (matches upstream minimal). Wires `rosenpass.sendNE` closure (still expects opcodes 0x02/0x03/0x04 in NE — broken until we re-add to NE).
- `/Users/agentworker2/Documents/Claude/Projects/Cloak VPN App - Business Opportunity/cloak-vpn/clients/ios/CloakVPN/RosenpassBridge.swift` — Has `NETunnelTransport` that uses opcodes 0x02/0x03/0x04. Currently broken because the new PacketTunnelProvider lacks those opcodes. **Only matters if PQC is enabled** — with no-PQ config, bridge.start is never called, transport is unused.
- `/Users/agentworker2/Documents/Claude/Projects/Cloak VPN App - Business Opportunity/cloak-vpn/clients/ios/RosenpassFFI/src/lib.rs` — Has the V03 InitConf fix (stash PSK, prioritize sending response).

### Server scripts (working, partially uncommitted)
- `/Users/agentworker2/Documents/Claude/Projects/Cloak VPN App - Business Opportunity/cloak-vpn/server/scripts/setup.sh` — works
- `/Users/agentworker2/Documents/Claude/Projects/Cloak VPN App - Business Opportunity/cloak-vpn/server/scripts/add-peer.sh` — works
- **NOT YET IN REPO**: `cloak-psk-installer.sh` + systemd unit — manually deployed to us-west-1 at `/usr/local/bin/cloak-psk-installer-iphone.sh` and `/etc/systemd/system/cloak-psk-installer.service`. Needs folding into setup.sh + parameterizing for any peer name (task #10).

### Documentation
- `/Users/agentworker2/Documents/Claude/Projects/Cloak VPN App - Business Opportunity/cloak-vpn/docs/IOS_PQC.md` — comprehensive technical doc, has architecture decision, original 10 bugs from earlier sessions, "IP leak fix path" section. **Needs updating with tonight's findings** (the upstream-fork pivot).

---

## Server access

**Iphone-prod-1 WG details (registered on us-west-1):**
- WG private key: `<REDACTED-WG-PRIVATE-KEY>` (in `/etc/wireguard/iphone-prod-1.key` on server)
- WG public key: `1TLOHHCBu/FQDCjN7vsPZ+HCD7zPvTrPemPdD6huyXc=`
- Tunnel IP: `10.99.0.3/32` + `fd42:99::3/128`

**Server WG public key:** `naaRSIgUchakCi0xBnCE4IY0anMU3X7lbG0pmxyx3lQ=`

**SSH:**
```bash
ssh -i ~/.ssh/cloakvpn_ed25519 root@5.78.203.171
```

Other regions and credentials are in `infra/terraform/regions/<region>/terraform.tfvars`.

**Important:** the iPhone's CURRENT rosenpass pubkey may have drifted from what's registered on us-west-1 (`/etc/rosenpass/iphone-prod-1.rosenpass-public`). Each app uninstall wipes the App Group container; `ensureLocalKeypair` generates a fresh keypair on next launch. After any reinstall, the user must share the new pubkey via the app's PQ identity panel and we replace the file on the server. Cycle:

```bash
# On Mac
scp -i ~/.ssh/cloakvpn_ed25519 ~/Downloads/cloakvpn-pubkey-*.b64 root@5.78.203.171:/tmp/iphone-new.b64

# On server
base64 -d /tmp/iphone-new.b64 > /etc/rosenpass/iphone-prod-1.rosenpass-public
chmod 600 /etc/rosenpass/iphone-prod-1.rosenpass-public
stat -c '%s' /etc/rosenpass/iphone-prod-1.rosenpass-public  # MUST be 524160
systemctl restart cloak-rosenpass.service
```

---

## Working wg-quick config (use this in official WG iOS app)

For the user to keep using the working VPN tonight via the official WireGuard iOS app:

```
[Interface]
PrivateKey = <REDACTED-WG-PRIVATE-KEY>
Address = 10.99.0.3/32, fd42:99::3/128
DNS = 9.9.9.9, 2620:fe::fe

[Peer]
PublicKey = naaRSIgUchakCi0xBnCE4IY0anMU3X7lbG0pmxyx3lQ=
Endpoint = 5.78.203.171:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

This config is also at `/tmp/cloak-test.conf` and `/tmp/iphone-prod-1_nopq-config.txt` on us-west-1 server.

---

## Tomorrow's plan: Option 2 — fork upstream WG iOS

The user agreed (at ~02:30 HST) that the right architectural call is to fork the official wireguard-apple sample iOS app and port our customizations onto it instead of debugging our custom NE blindly.

### Steps

1. **Clone upstream wireguard-apple:**
   ```bash
   git clone https://github.com/WireGuard/wireguard-apple.git ~/wireguard-apple-upstream
   ```

2. **Identify the upstream iOS app structure:**
   - `Sources/WireGuardApp/` — the SwiftUI host app
   - `Sources/WireGuardNetworkExtension/` — the NE (PacketTunnelProvider.swift + ErrorNotifier.swift)
   - `Sources/Shared/` — Logger, FileManager extensions, NETunnelProviderProtocol+Extension (asTunnelConfiguration), TunnelConfiguration+WgQuickConfig (the wg-quick parser)

3. **Create new Cloak VPN target structure** (new Xcode project OR import upstream as a fresh basis):
   - Re-brand the host app SwiftUI screens (`WireGuardApp` → `CloakVPN`)
   - Keep upstream's `WireGuardNetworkExtension` mostly verbatim (their PacketTunnelProvider.swift)
   - Add our PSK-push opcode 0x01 to their `handleAppMessage` (small additive change)
   - Add Option D rosenpass UDP relay opcodes 0x02-0x04 (we have the proven implementation in our current source)
   - Embed our `RosenpassFFI.xcframework` in the host app (already built, has the V03 InitConf fix)
   - Bring across our `AppGroupKeyStore.swift`, `RosenpassBridge.swift`, `ConfigParser.swift`, `TunnelManager.swift`
   - Either keep upstream's wg-quick parser (preferred — works) OR keep our custom CloakConfig format (more work to keep working)

4. **Validate at each step:**
   - Step 1: vanilla upstream-cloned app with wg-quick config → must show `5.78.203.171` at test-ipv6.com (proves we have a working baseline)
   - Step 2: + our PSK opcode 0x01, no-PQ config → still works
   - Step 3: + opcodes 0x02-0x04 + RosenpassBridge → PQC handshake completes → server-side `/run/rosenpass/psk-iphone-prod-1` appears → wg0 has PSK → traffic still flows
   - Step 4: + UI rebrand, settings, region picker

5. **Estimated effort: 1-2 days of focused work.** Most risk is in step 3 (Option D rosenpass relay) since we already proved that piece worked when WG itself wasn't broken (PQC: 1 rotation ✓ was achieved earlier today on multiple regions).

---

## Outstanding tasks (TaskList)

```
#1.  [completed] Validate client-keygen smoke test
#2.  [pending]   Native in-app provisioning (Phase 1→2, ~2-3 weeks)
#3.  [pending]   Fix IPv6 leak (separate from main IP leak)
#4.  [completed] Scaffold US East + US West regions
#5.  [completed] Set includeAllNetworks=true (achieved at TunnelManager level, but
                 doesn't help because our NE is broken)
#6.  [completed] Tunnel rosenpass UDP through wg0 (Option D, code shipped but broken
                 in current NE)
#7.  [pending]   Verify Option D on iPhone — BLOCKED by NE bug
#8.  [pending]   Commit Option D refactor — DEFER until after upstream fork
#9.  [pending]   Rebuild RosenpassFFI xcframework with V03 InitConf fix — built but
                 not verified working end-to-end (server still didn't write PSK file)
#10. [pending]   Fold cloak-psk-installer into setup.sh
#11. [in_progress] Investigate iPhone WG decryption failure — RESOLVED via Option 2
                 (fork upstream); current custom NE is a dead-end
#12. [pending]   Fix server-side rosenpass not committing PSK to /run/rosenpass/
#13. [pending]   Fork upstream WireGuard iOS as new base (THIS is tomorrow's #1)
```

---

## Things NOT to repeat

When you pick up tomorrow, please don't waste time re-trying these — we've already validated they don't help:

- Removing `setTunnelNetworkSettings` override (already removed)
- Setting `enforceRoutes=true` (already true; reverted to upstream-minimal)
- Setting various `excludeXxx=false` (already reverted)
- Verifying `WireGuardKitGo` is linked (already verified — `nm CloakTunnel.debug.dylib | grep wgTurnOn` shows symbols present)
- Comparing `makeTunnelConfiguration` to wg-quick parser output (already byte-equivalent)
- Cleaning DerivedData (already done multiple times)
- Deleting + reinstalling app + rebooting iPhone (already done)
- Replacing our PacketTunnelProvider source with code structurally identical to upstream's — done, still broken

The remaining "bug surface" is at the project/target/entitlement/build-phase level, OR something specific about the user's signing identity / Apple Developer Profile, OR something subtle about how Xcode 26 + iOS 26 evaluate the NE bundle. **The fastest path through it is replacing the entire project structure with upstream's, not debugging ours further.**

---

## Useful diagnostic commands (if needed)

### iPhone status check
```bash
# On Mac terminal — assumes iPhone tethered via USB:
# (xcrun devicectl is the modern replacement for instruments-related tools)
xcrun devicectl list devices
```

### Check what's linked in our broken NE binary
```bash
NEWEST=$(find ~/Library/Developer/Xcode/DerivedData -name "CloakTunnel.debug.dylib" -type f -print0 | xargs -0 ls -t | head -1)
echo "Binary: $NEWEST"
otool -L "$NEWEST"
nm "$NEWEST" | grep -iE "wgTurnOn|wgSetConfig" | head -5
```

### Server wg state
```bash
ssh -i ~/.ssh/cloakvpn_ed25519 root@5.78.203.171 'wg show wg0; ip a show wg0; iptables -L FORWARD -nv | head -3'
```

### Live tcpdump on server during a test
```bash
# In SSH to server:
timeout 30 tcpdump -i any -nn 'udp port 51820'
```

### Console.app for iPhone NE logs
1. Mac Console.app → click iPhone in left sidebar (under Devices)
2. Action menu (top of screen) → check Include Info Messages + Include Debug Messages
3. Filter: in search bar top-right, click dropdown → choose Process → type `CloakTunnel`

If the Action menu doesn't show those options on this macOS version:
- Use Xcode → Window → Devices and Simulators → click iPhone → "Open Console" button at bottom

---

## Final notes

This document is intentionally exhaustive because the user has been pushing through 19 hours of debugging and is exhausted. The next session should NOT need to re-derive any of this context. Read this top-to-bottom, then jump straight to "Tomorrow's plan: Option 2".

If you (the next Claude) have questions about specific decisions, the relevant context is in `docs/IOS_PQC.md` (especially the "End-to-end smoke test" + "IP leak fix path" sections).

If you find a way to fix the current custom NE without forking upstream, that'd be a great win — but PLEASE timebox it to ~1 hour. After that hour, regardless of progress, switch to Option 2 (the fork). The user has explicitly chosen Option 2.

Good luck. — Claude (2026-04-27 03:00 HST)
