# Session Handover — 2026-07-01 — iOS PQC desync FIXED (build 113), Android STILL BROKEN

Read top to bottom. This session fixed the long-running iOS "connects then dies
after ~30 s, no internet" bug and verified the fix on real hardware + server-side.
**Android is still broken and is the main open task.** It needs *fresh* diagnosis —
the fix that cured iOS is already present in the Android code, so do not just
"port the iOS fix."

---

## TL;DR — current state

| Area | Status |
|------|--------|
| **iOS Lattice app** | **FIXED — build 113, verified.** PQC completes, PSK matches, data flows and survives past 30 s. Ship 113. |
| **Android Lattice app** | **STILL BROKEN.** Same *class* of symptom (connects, "PQC rotation 1", then no internet). Root cause NOT yet diagnosed. Android already has the InitConf-retransmit mitigation (see below), so its cause is different. |
| Fleet servers | **Healthy** (8/10 boxes). Provisioning API up, DNS/egress/NAT/forwarding fine, `cloak-rpd` daemon fix deployed fleet-wide. |
| de1 + fi1 (Hetzner) | **Up but SSH-locked** (ping OK, 22/80 filtered). Management-access issue, not an outage. Not user-facing regions. |
| App Store | Submit **build 113**. Do NOT ship 110 (lacks the fix) or 111 (broke everything). |
| Interim connectivity | User is online via a **plain-WireGuard** config (official WireGuard app), Tokyo, peer `10.99.0.50`. No PQC, but rock-solid. |

---

## The core bug (context — this is what iOS had)

**PQC PSK desync.** The client runs Rosenpass V03 to derive a 32-byte preshared
key (PSK) that gets mixed into WireGuard. The initiator (phone) derives the PSK
the moment it *sends* the final `InitConf` message — but the **server only
commits the PSK when it *receives* InitConf**. If that single UDP datagram is
lost (more likely on lossy / high-latency links), the server never installs the
PSK while the phone applies its own. WireGuard mixes the PSK into the **next**
rekey, so the tunnel silently wedges ~30 s later: "connects, PQC rotation 1, then
no internet, drops." Because the Rosenpass exchange rides *outside* the tunnel
but the data does not, the tunnel can't self-heal.

Decisive proof it was PQC and not network/servers: a **plain-WireGuard** config
(no PQC) to the *same* concentrator connects and works perfectly on the *same*
network. PQC on = 30 s death; PQC off = solid.

## iOS fix — build 113 (DONE + VERIFIED)

- **File:** `clients/ios/CloakTunnel/RosenpassDriver.swift`, `singleHandshake()`,
  the `.sendMessage` arm (~line 217). After deriving the PSK, **retransmit
  InitConf 4× at 180 ms** before handing the PSK to wg-go, so a single lost
  InitConf can't cause the desync. Idempotent — responder commits on first
  receipt, ignores duplicates. No data-plane change; safe.
- **Build:** bumped `CURRENT_PROJECT_VERSION` 110 → **112**, user re-uploaded as
  **113** (renumber for App Store Connect). Same code.
- **VERIFIED 2026-07-01 on za1 (South Africa)** while the user was connected on
  113: peer had `preshared key` applied, server wrote `/run/rosenpass/psk-peer-e76fc62df828`,
  handshake **18 s ago** (successfully rekeying *past* the old 30 s death point),
  **2.9 MiB rx / 51.6 MiB sent**, `tcpdump -ni wg0` = **1548 packets in 12 s** of
  real traffic. PQC genuinely active, data flowing, stable.
- **Action:** make **113** the build Apple reviews (swap it into the in-review
  version, replacing 110/111).

---

## ANDROID — the main open task (STILL BROKEN)

### The key nuance — do NOT just port the iOS fix
Android **already has** the InitConf-retransmit mitigation, and more of it than
iOS ever had. See `clients/android/app/src/main/kotlin/ai/latticevpn/android/vpn/RosenpassRotator.kt`,
`singleHandshake()`:
- **Phase 1 (~lines 290-354):** in-exchange retransmit — every quiet
  `RETRANSMIT_INTERVAL_SEC` slice re-sends the last outbound message until
  `HANDSHAKE_DEADLINE_SEC` (added 2026-06-11).
- **Phase 2 (~lines 357-388):** post-derivation `INITCONF_RETRANSMITS` re-sends
  of InitConf (added 2026-05-24 — the exact mitigation iOS just got).

So the dropped-InitConf desync is *already* mitigated on Android. Its continued
failure is a **different, undiagnosed root cause**. Treat it as a fresh
investigation.

### What to diagnose (fresh)
Reproduce with the user connected on Android to a specific region, then, **in
parallel**, gather client + server evidence:

1. **Server-side** (this is fast and I did it all session for iOS — see the
   playbook below). While Android is connected, on that region's box:
   - Is a `/run/rosenpass/psk-*` file written for the device's peer? (PQC
     completed server-side?)
   - Does the device's wg peer show `preshared key: (hidden)` + a *fresh*
     handshake that keeps advancing? Or does handshake go stale (rekey failing =
     PSK mismatch)?
   - `tcpdump -ni wg0` — does *decrypted* traffic flow (data path OK) or ~0
     (routing/PSK problem)?
   - `tcpdump -ni any udp` split — `wg51820` vs `rp9999` counts (is Android even
     sending PQC? is data reaching the box?).
2. **Client-side** (this is the part I could NOT do — needs the device):
   `adb logcat` while connecting. Filter the app's tags. Look at:
   - `RosenpassRotator` — does the handshake complete? how many rotations?
   - `TunnelManager` **watchdog** — the code comment says "Any residual desync is
     caught by the TunnelManager watchdog, which tears the tunnel down and
     re-keys from the outside." **Prime suspect:** is the watchdog tearing down
     the tunnel too aggressively (the Android analog of the iOS 30 s self-kill)?
   - `PskApplicator` / `UapiPskApplicator` — does the PSK actually get applied to
     wg via UAPI (`preshared_key=`), and with what timing vs the server commit?

### Android code map (where to look)
All under `clients/android/app/src/main/kotlin/ai/latticevpn/android/vpn/`:
- `RosenpassRotator.kt` — PQC handshake loop + rotation (has the retransmits).
- `RosenpassBridge.kt` / `RosenpassTransport.kt` — FFI session + UDP transport.
- `PskApplicator.kt` + `UapiPskApplicator.kt` — apply the derived PSK to
  wireguard-go via the UAPI (`preshared_key=` set on the peer).
- `WgUapi.kt` — UAPI plumbing.
- `TunnelManager.kt` / `TunnelRepository.kt` — tunnel lifecycle + the **watchdog**
  (recovery/teardown logic — check its thresholds).
- `ConfigParser.kt`, `KeyStore.kt`, `AccountClient.kt` — config/keys/provisioning.
- FFI: `uniffi/rosenpassffi/rosenpassffi.kt` (generated); Rust source shared with
  iOS at `clients/ios/RosenpassFFI/src/lib.rs`.

### Leading hypotheses for Android (unproven)
1. **Watchdog too aggressive** — tears the tunnel down during PQC convergence /
   before a rekey lands (analog of the iOS 30 s self-kill that we had to soften
   with a convergence grace). Most likely given "connects ~30 s then drops."
2. **PSK-apply timing** — Android applies the PSK via UAPI before/independent of
   the server commit, and its watchdog doesn't fall back to plain-WG (iOS now
   survives because the InitConf retransmit makes the server commit reliably; if
   Android's retransmit still races the watchdog, it can drop first).
3. **Installed APK is older than the code** — confirm the user's Play/sideload
   build actually contains the Phase-1/Phase-2 retransmits (check versionCode;
   the retransmits landed 2026-05-24 / 06-11). If they're on an old build, a
   rebuild may just fix it.
4. **Data-plane/routing** (less likely on Android than iOS, which used a custom
   Mullvad-fork NE; Android uses upstream wireguard-android).

### Suggested first step for fable 5
Get the user connected on Android to **one** region (Tokyo/jp1 is closest to
them; they're in Japan) and simultaneously (a) watch that box server-side with
the playbook below and (b) pull `adb logcat`. That single correlated capture will
say whether PQC completes server-side, whether the watchdog is killing it, and
whether data ever flows — which picks between the hypotheses above.

---

## Server-side state & the cloak-rpd fix (deployed this session)

**`cloak-rpd` self-poke fix — DEPLOYED fleet-wide, verified.** Root cause: on
idle boxes, a runtime peer-add sent over the control socket never drained because
the mio Waker's wake was swallowed by `AppServer::poll()` (returns to the caller
only on real network events). Fix (bin-only, `server/cloak-rpd/src/main.rs`
`control_thread`): after queuing an ADD/REMOVE, send a 1-byte "self-poke" UDP
datagram to the daemon's own listen socket so `poll()` returns and the event loop
drains the command immediately. Built native amd64 in Docker on the VM
(178.104.136.167), canary-verified on us-east-1 (saw the poke packet on `lo`),
rolled to 8/10 boxes. Binary sha256 `326cba2e8570c74fcd9c762d46d47f2f2d296fd7c0dad73cdf1ddd5d99d2c9f5`;
old binary backed up per box as `/usr/local/bin/cloak-rpd.bak.poke`. Effect:
devices now register on any box without a manual `systemctl restart cloak-rpd`.
(de1/fi1 did NOT get it — unreachable; still on old binary.)

**DNS changed fleet-wide:** `WG_DNS` in `/etc/cloakvpn/regionsvc.env` is now
`1.1.1.1, 1.0.0.1` (was Quad9 `9.9.9.9, 2620:fe::fe`). Quad9 was *blocking*
`dnsleaktest.com` (returns no record), which looked like a VPN failure but wasn't.
Backups: `regionsvc.env.bak-dns` on each box. Restart `regionsvc` after edits.

**IPv6 is half-broken on the 6 Vultr boxes** (us-central-1, es1, mx1, za1, in1,
jp1): v6 NAT/forwarding enabled but **no working v6 egress** (`ping6` fails). It
silently black-holes v6 → can cause slow/failed loads on dual-stack sites. A
fast-fail `ip6tables FORWARD REJECT` for `fd42:99::/64` was added to **in1 only**
(runtime, not persisted). TODO: either fix v6 egress or cleanly reject v6
fleet-wide + persist. Hetzner boxes (us-west, us-east) have working v6.

---

## Access & diagnostic playbook (how I did all of this)

**SSH to the fleet:** from the Mac Mini (macOS user `agentworker2`), the fleet key
is `~/.ssh/cloakvpn_ed25519`. Connect by IP:
`ssh -i ~/.ssh/cloakvpn_ed25519 root@<box-ip>`. I drove this via the
"Control your Mac" osascript tool (`do shell script "..."`). The same key reaches
the monitoring/build VM `178.104.136.167`.

**Fleet (region → IP):**
`us-west-1 5.78.203.171` (also runs `cloakvpn-api` + `regionsvc`; **Caddy** on :443
fronts `api.latticevpn.ai` → `127.0.0.1:8080`),
`us-east-1 5.161.198.227`, `us-central-1 207.148.1.253` (dallassvr1),
`de1 91.98.65.98`*, `fi1 204.168.252.70`* (*SSH-locked),
`es1 65.20.99.121` (madrid), `mx1 216.238.95.21` (mexico),
`za1 139.84.248.50` (johannesburg), `in1 65.20.77.179` (mumbai),
`jp1 167.179.75.10` (tokyo).

**The one diagnostic that classifies everything** (run on the region box while a
client connects):
```
# outer: is the client's traffic even reaching the box, and is it doing PQC?
timeout 15 tcpdump -ni any -nn udp > /tmp/c.txt 2>/dev/null
echo rp9999=$(grep -c 9999 /tmp/c.txt) wg51820=$(grep -c 51820 /tmp/c.txt)

# inner: is DECRYPTED data actually flowing through the tunnel?
timeout 15 tcpdump -ni wg0 -nn | head        # ~0 lines = no data path

# PQC state: did the server commit a PSK, and does the peer have it?
ls /run/rosenpass/psk-*                        # a psk-peer-* file = exchange completed
wg show wg0 | grep -E "peer|handshake|transfer|preshared"
```
Decision tree:
- `wg51820=0, rp9999=0` → client traffic not reaching the box → **client network
  blocking VPN UDP** (we saw this on a Japan Wi-Fi; cellular worked).
- `wg>0` handshakes succeed + inner `wg0` shows data → **working**.
- Peer has `preshared key` but no psk-* file / handshake goes stale → **PSK
  desync** (server never committed) → the bug this whole saga is about.
- Handshakes succeed, inner `wg0` ~0, no PSK issue → **client data-plane/routing**.

**cloak-rpd runs `Verbosity::Quiet` with no `log::` subscriber** — it will NOT log
"add_peer ok" etc. Verify its behavior by packets/PSK files, NOT journal logs.

---

## Other open items
- **Ship build 113** to App Store review (swap it into the in-review version).
  **Do NOT ship 110** (no fix) **or 111** (PSK-rollback that took down every
  region; it's git-stashed as `cowork-build111-psk-rollback` — do not un-stash to
  ship).
- **Android fix** (this doc's main task).
- **de1 / fi1**: up but SSH-locked (ping OK, 22/80 filtered). Reopen SSH in the
  Hetzner firewall for the admin IP so they can be managed + get the cloak-rpd fix.
- **Retire the Tokyo plain-WG fallback peer** (`10.99.0.50`, in jp1
  `/etc/wireguard/wg0.conf` + live) once 113/Android are trusted. Config artifacts
  in the project folder: `Lattice-Tokyo-PlainWG.conf` / `-QR.png`.
- **IPv6 on Vultr boxes** (see above) — decide fix vs clean-reject.

## Gotchas / lessons (hard-won today)
- **NEVER ship/install an untested client change.** Build 111 (a PSK-rollback
  "safety net") was pushed to device + uploaded before testing and took down every
  region on both platforms. Always: implement → build → install → **verify
  end-to-end on a real device or server-side** → then declare done.
- **"wg connects but no data, packets don't decrypt, rp≈0"** on iOS was **poisoned
  App Group state** (stale rosenpass keys from repeated reinstalls). Fix =
  UNINSTALL the app (`devicectl device uninstall`), not just delete the VPN
  profile (which leaves the App Group intact), then reinstall.
- macOS `base64 -D` (uppercase) to decode; Linux boxes use `-d`. Long remote
  scripts: base64-encode locally, decode on the target.
- The Control-your-Mac osascript tool times out ~30 s — background long ops
  (`setsid ... </dev/null &`) and poll; keep `sleep`s ≤ ~26 s.
- `strings` is NOT installed on the fleet boxes or the VM — use `grep -a`.
- Don't `sed -i` a single-file bind-mounted container config (e.g. Caddyfile) —
  it swaps the inode and orphans the container's mount.
