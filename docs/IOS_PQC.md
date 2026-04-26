# Post-Quantum Crypto on iOS — Architecture Decision Record

Status: ✅ Decision made 2026-04-25.
Reviewer: solo project, single decision-maker.
Implementation status: ✅ end-to-end smoke test PASSING against
`fi1.cloakvpn.ai` as of 2026-04-25 evening (see "End-to-end smoke
test" section below). Two consecutive 120-second PSK rotations
verified on iPhone 13 Pro Max running iOS 26.4.

## Question

How does Cloak VPN run a Rosenpass post-quantum key exchange (Classic
McEliece-460896 + ML-KEM-768) on iOS, given the platform's
NetworkExtension memory constraints?

## TL;DR Decision

**Rosenpass runs in the main app process via `uniffi-rs`-generated Swift
bindings against the upstream Rust crate. The NetworkExtension Packet
Tunnel Provider remains Swift-only and consumes 32-byte PSK updates via
`sendProviderMessage`. This mirrors Mullvad's iOS architecture.**

## Why this matters

The naive approach — embedding Rosenpass directly in the
NEPacketTunnelProvider extension — risks running into iOS's hard 50 MiB
memory cap on packet-tunnel extensions (iOS 15+; was 15 MB before).
Classic McEliece-460896 has a 524 KB public key; key generation peaks at
2-4 MB working set. Combined with WireGuardKit's runtime and packet
buffers, the NE could hit jetsam-killed states under memory pressure.

The main app process has no such cap. Apple's design intent is that
heavy work happens in the main app and only the data-plane work happens
in the extension. We follow that intent.

## Background research summary

Day-1 research synthesized from four parallel agent investigations
(2026-04-25). Full sources at the bottom of this doc.

### iOS NE memory limit

- **50 MiB hard cap** for `NEPacketTunnelProvider` on iOS 15-18.
- Other NE provider classes are smaller (App Proxy ~15 MiB, DNS Proxy
  ~15 MiB, Filter Control ~12 MiB).
- No entitlement raises the cap. Quinn "The Eskimo!" (Apple DTS)
  confirmed across multiple Developer Forum threads that
  `com.apple.developer.networking.networkextension` only declares
  provider classes, not memory budgets.
- iOS measures memory via `task_vm_info.phys_footprint` (dirty +
  compressed + IOKit + page tables), not RSS. Compressed pages still
  count.
- Realistic working budget: plan against **35 MiB**, treat 45 MiB as a
  hard ceiling. Background memory pressure can kill the NE well below
  the cap.

### Rosenpass memory footprint

| Item | Bytes |
|---|---|
| Classic McEliece-460896 public key | 524,160 |
| Classic McEliece-460896 secret key | 13,608 |
| Classic McEliece-460896 ciphertext | 156 |
| ML-KEM-768 public key | 1,184 |
| ML-KEM-768 secret key | 2,400 |
| ML-KEM-768 ciphertext | 1,088 |
| Per-handshake transient (responder) | ~600 KB above baseline |
| Persistent runtime (libsodium + liboqs + Rust + tokio) | ~3-5 MB |
| **McEliece keygen peak** (one-shot) | **2-4 MB** |

If we ran Rosenpass inside the NE we'd be at ~10-22 MB steady, ~25 MB
peaks during handshake — fits, but tight. The 2-4 MB McEliece keygen
spike at first install would be the most dangerous moment.

### Competitor patterns

- **Mullvad** ships Classic McEliece-460896 + ML-KEM-1024 on iOS today.
  They wrote a custom **Swift** implementation (NOT the Rust crate) and
  run it inside the Packet Tunnel Provider. They split the protocol
  across two tunnel sessions (open WG, do PQ inside, tear down, open WG
  with PSK). Even Mullvad doesn't default-enable PQ on iOS 18 months
  later, citing Apple sandboxing constraints.
- **IVPN** uses smaller `mceliece348864` (~261 KB pubkey) with REST API
  PSK delivery, runs from main app.
- **NordVPN** uses ML-KEM only (no McEliece) inside their NE — small
  enough to be safe.
- **Cloudflare WARP iOS** uses ML-KEM-768 only at the TLS layer.
- **NetBird** tried Rosenpass on iOS, **disabled it** ("permissive
  mode" = PQ off). Their code is Go, not Rust.

### Architectural options weighed

| Option | Verdict |
|---|---|
| **A. Rosenpass in main app, PSK via App Group + sendProviderMessage** | ✅ Chosen — Mullvad-pattern, lowest risk |
| B. Rosenpass embedded in NE | ❌ Tight memory budget; jetsam risk; Mullvad-grade iOS dev effort |
| C. Server-derived PSK pulled by HTTPS | ❌ Breaks PQ guarantees — "harvest now, decrypt later" works on the transport |
| D. Skip rosenpass, use ML-KEM only in NE | Fallback if Option A fails — sacrifices "academically peer-reviewed Rosenpass" marketing claim |

Option C is worth elaborating on because it's a tempting shortcut: the
intuition "let the server do the heavy KEM and just send me the PSK" is
*not* post-quantum secure. If the transport is classical TLS, a
quantum-equipped attacker recording today's HTTPS traffic decrypts the
PSK retroactively when quantum compute becomes available. Even if we put
the PSK fetch inside a PQ-hybrid TLS, we've just moved the same PQ
crypto burden into a different process — no win. PQ security
**requires** that the key-encapsulation operation happen on the device,
with the secret never crossing the wire as plaintext.

## Implementation plan

```
┌──────────────────── iPhone ─────────────────────────────────┐
│                                                             │
│  ┌─ Main App (1+ GB budget) ──────────────────┐             │
│  │                                            │             │
│  │  Swift UI                                  │             │
│  │     │                                      │             │
│  │     ▼ via RosenpassFFI.xcframework         │             │
│  │  Rust: rosenpass::protocol::CryptoServer   │             │
│  │     - generates McEliece keypair (one-shot,│             │
│  │       persisted to iOS Keychain)           │             │
│  │     - runs handshake every 120s while      │             │
│  │       app is foregrounded                  │             │
│  │     - emits 32-byte PSK on success         │             │
│  └────────────────────┬───────────────────────┘             │
│                       │ NETunnelProviderSession             │
│                       │   .sendProviderMessage(psk_bytes)   │
│                       ▼                                     │
│  ┌─ Packet Tunnel Provider Extension (50 MiB cap) ─┐        │
│  │                                                 │        │
│  │  Swift + WireGuardKit                           │        │
│  │     - receives PSK in handleAppMessage          │        │
│  │     - calls wg_set_config to update peer.psk    │        │
│  │     - tunnel data plane stays up; PSK swap is   │        │
│  │       hot, no reconnect                         │        │
│  │  Steady-state: ~10-15 MiB                       │        │
│  └─────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────┘
                       │
                       ▼ encrypted UDP
              cloak-fi1 / cloak-de1
              (rosenpass daemon as before)
```

### Backgrounded behavior

When the user backgrounds or force-quits the main app:

- The NE keeps running in its own process (managed by `nesessionmanager`).
- The WireGuard tunnel stays up.
- The last PSK persists.
- PSK rotation **pauses** until the user opens the app again.

This matches Mullvad's iOS behavior. The "PQC freezes when backgrounded"
limitation is acceptable because:

1. The classical WireGuard layer remains intact and secure for that period.
2. The harvest-now-decrypt-later threat model assumes attackers wait
   *years* — pausing rotation for hours while the user's phone is in
   their pocket is irrelevant in that timeframe.
3. iOS does not provide a reliable mechanism for 120-second cadence
   work in a backgrounded app. Background fetch is OS-controlled
   (~15 min minimum); silent push isn't reliable; VoIP backgrounding is
   prohibited for VPN apps.

We document this on the website's Privacy / How-it-works page so users
who care about continuous PQ have informed expectations.

## Cross-compile verification (Day 1)

The hardest unknown was: does the upstream rosenpass Rust crate
cross-compile to iOS at all? Answer: **yes, with Rust 1.77.0**.

Verification log (2026-04-25):

```
$ rustup toolchain install 1.77.0
$ rustup target add aarch64-apple-ios aarch64-apple-ios-sim --toolchain 1.77.0
$ git clone https://github.com/rosenpass/rosenpass.git /tmp/rp-experiment
$ cd /tmp/rp-experiment
$ cargo +1.77.0 check --target aarch64-apple-ios -p rosenpass --no-default-features
    Finished dev [unoptimized + debuginfo] target(s) in [success]

$ ls target/aarch64-apple-ios/debug/build/oqs-sys-*/out/build/lib/liboqs.a
-rw-r--r-- 1 user staff 1.0M ... liboqs.a  ← Classic McEliece + Kyber inside
```

Toolchain notes:
- **Rust 1.88.0** is the sweet spot. Rust 1.95+ breaks `memchr 2.7.4` on
  iOS-arm64 due to stdarch changes around NEON intrinsics (563 errors in
  `memchr` long before reaching liboqs). Rust 1.77.0 (which the upstream
  `rosenpass` workspace pins) is too old for our FFI crate's wider dep
  graph: uniffi 0.27 transitively pulls in `serde_spanned 1.1.1` which
  requires `edition2024` (stabilized in Rust 1.85).
  Cargo respects `rust-toolchain.toml` files only inside their own
  workspace; depending on rosenpass via a git URL bypasses that pin and
  uses our chosen toolchain (1.88) for the entire build.
- **CMake** must be installed (Homebrew `cmake` works); `oqs-sys`'s
  `build.rs` invokes it to compile liboqs from source.
- **iOS Simulator builds** require an extra env var to pass clang's
  triple validator:
  ```
  BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim="--target=arm64-apple-ios14.0-simulator --sysroot=$(xcrun --sdk iphonesimulator --show-sdk-path)"
  ```

This is documented in `clients/ios/RosenpassFFI/README.md` for future
deploys.

## On-device verification (2026-04-24)

After Day-1 cross-compile checkpoint, end-to-end smoke test on real
hardware (iPhone 13 Pro Max, iOS 26.4, Debug+Release builds):

**Runtime correctness**

- `generateStaticKeypair()` returns a valid keypair from Swift.
- Public key length: **524,160 bytes** (511 KB at /1024 rounding) —
  matches Classic McEliece-460896 spec exactly.
- Secret key length: **13,608 bytes** (13 KB) — matches spec exactly.
- Duration on iPhone 13 Pro Max, Release build: hundreds of ms,
  imperceptible to the user. Debug build was ~940 ms; Release builds
  finish too fast to measure precisely with Xcode's 1 Hz Memory poll.

**Memory footprint (Xcode Debug Navigator → Memory, real device)**

| Phase                                | Resident |
|--------------------------------------|----------|
| App at rest, FFI loaded, no keygen   | 18.7 MB  |
| Peak during a burst of ~5–10 keygens | 20.0 MB  |
| Steady state after keygen completes  | 17.4 MB  |

Working-set overhead per keygen: **~1–3 MB**. Lower than the 2-4 MB
estimate from the upstream rosenpass codebase analysis — Apple's
allocator and our `--release` Rust build are both more memory-efficient
than the conservative paper estimates assumed.

**Implications for the design**

- Our Mullvad-pattern (PQC in main app, PSK pushed to NE) is now
  *massively* over-provisioned. Comfortable margin even on jetsam-prone
  older devices.
- Even running PQC inside the NE itself would fit (1–3 MB overhead vs
  50 MiB cap = >15× headroom). We won't, because there's no upside,
  but the tradeoff that drove the architecture is much less tight than
  expected. If a future need arises (e.g. PSK refresh while the main
  app is jetsamed), pivoting is feasible.
- No memory leaks: post-keygen resident dropped *below* baseline,
  meaning all temp buffers were freed and iOS reclaimed some pages.

## End-to-end smoke test (2026-04-25)

**Status: ✅ PASSING.** Full McEliece-460896 + ML-KEM-768 + WireGuard PSK
rotation chain operational on iPhone 13 Pro Max (iOS 26.4) against
`fi1.cloakvpn.ai` (`204.168.252.70`). Two consecutive 120-second
rotations confirmed live; rosenpass-derived PSK swapped onto the
WireGuardKit-managed tunnel without dropping in-flight UDP. Working
classical-only fallback also confirmed via `_peer-config-wg-only.txt`.

The path to passing was longer than expected. Ten distinct bugs in the
stack between the iOS app, the NetworkExtension, the rosenpass FFI,
the server's rosenpass binary, the WireGuard tunnel routing, and iOS
provisioning. Documenting each here so a future operator (or
future-me re-spinning a region) doesn't burn another evening on the
same hazards.

### Bugs encountered, in rough order of discovery

1. **`providerConfiguration` size limit.** The original
   `CloakConfig.asDictionary` shoved all three rosenpass key blobs
   (~1.4 MB combined of base64 McEliece-460896 public keys plus the
   client secret) into `NETunnelProviderProtocol.providerConfiguration`.
   iOS persists this dictionary to a system database with practical
   size limits in the hundreds of KB; ours either silently truncated
   on save or got rejected at install time. **Fix:** moved keys to an
   App Group container via `AppGroupKeyStore.swift`; the NE doesn't
   need them anyway since rosenpass runs in the main app.
2. **Paste-only import UI.** `ContentView.importSheet` was a
   `TextEditor` paste field. 1.4 MB of base64 is unpasteable in
   practice. **Fix:** added `.fileImporter` so the user picks the file
   from Files / iCloud Drive / AirDrop instead of pasting.
3. **`providerBundleIdentifier` mismatch.** `TunnelManager.importConfig`
   hard-coded `"com.cloakvpn.app.tunnel"`, but the actual NE target's
   PRODUCT_BUNDLE_IDENTIFIER is `"ai.cloakvpn.CloakVPN.CloakTunnel"`.
   iOS uses this string to locate the NE binary; mismatch → silent
   launch failure. The host app worked fine, but every Connect tap
   transitioned `Connecting → Disconnected` instantly with **no NE
   logs whatsoever** (because the NE process never even started).
   This is one of the most painful failure modes in NE-land — there's
   no error path visible to the host app. **Fix:** match the strings.
4. **Network Extensions capability missing on the CloakTunnel target.**
   The target had App Groups but not Network Extensions in
   Signing & Capabilities. The host app has the
   `com.apple.developer.networking.networkextension` entitlement, but
   without it on the NE target the embedded entitlement is never
   granted by the provisioning profile, so iOS rejects the NE on
   launch. Same symptom as the bundle ID issue — instant
   `Connecting → Disconnected` with no logs. **Fix:** add the
   capability with `Packet Tunnel` checked. After this *and* the
   bundle ID fix, the NE finally launched and WireGuard came up.
5. **Server rosenpass version mismatch.** Server's `setup.sh` had been
   doing `apt-get install -y rosenpass` (apt 0.2.2) with a fallback
   to `cargo install --locked rosenpass` from crates.io (also a
   stable release, not git HEAD). The iOS FFI is locked to git rev
   `b096cb1`. McEliece secret-key serialization changed between
   those versions: stable rosenpass writes 13568-byte secret files
   (raw OQS layout), b096cb1 writes 13608 bytes (rosenpass-framed).
   iPhone tried to load a 13568-byte secret from a config that the
   server's add-peer.sh had written → FFI threw
   `invalid input: secret key wrong length: got 13568, want 13608`.
   **Fix:** `setup.sh` now pins via
   `cargo install --git ... --rev b096cb1`. `ROSENPASS_REV` constant
   at the top of the install block must be bumped in lockstep with
   `clients/ios/RosenpassFFI/Cargo.toml`.
6. **Stale rosenpass keys after version bump.** After installing the
   pinned binary, the server's existing `server.rosenpass-secret` and
   `client*.rosenpass-secret` files were still in the old format and
   the new binary couldn't deserialize them — daemon flapped on
   startup with "could not load secret-key file: invalid key" 200+
   times before we noticed. **Fix:** when bumping `ROSENPASS_REV`,
   regenerate ALL keys (server's own + every peer's) with the new
   binary, not just the failing peer's. Reset `server.toml` to the
   `[server]`-only block first, then re-run add-peer.sh per peer.
7. **Stale `[Peer]` blocks in `wg0.conf` and `[[peers]]` in
   `server.toml`.** Each add-peer.sh run for the same peer name
   re-generates a new WG keypair *and* appends new entries to both
   files without checking for existing ones. After several
   regenerations, both files had duplicate or stale entries pointing
   at keys that no longer existed. **Fix:** belt-and-suspenders
   nuke-and-pave: `sed -i '/^\[Peer\]/Q' wg0.conf` to wipe peer
   blocks, `cat > server.toml <<EOF` to reset to a clean
   `[server]`-only template, then `add-peer.sh` per peer.
8. **WG full-tunnel routing captured rosenpass UDP.** Once the WG
   tunnel was up with `AllowedIPs = 0.0.0.0/0, ::/0`, iOS routed
   all of the iPhone's outbound traffic through `utun` — including
   the rosenpass UDP/9999 socket the main app was trying to send
   on. `NWParameters.prohibitedInterfaceTypes = [.other]` excludes
   `utun` but doesn't fall back to a usable physical interface
   when the tunnel claims everything; the connection sat in
   `.waiting` state silently and no rosenpass packet ever escaped
   the device. **Smoke-test fix:** edited the iPhone's
   `_peer-config.txt` AllowedIPs to exclude `192.0.0.0/4` (the
   block containing the server's IP), so iOS keeps a route to
   `204.168.252.70` via the physical interface. **Production fix
   (still TODO, tracked separately):** Mullvad pattern — call
   `setTunnelNetworkSettings` after `WireGuardAdapter.start` with
   `NEPacketTunnelNetworkSettings.excludedRoutes` containing just
   the rosenpass server's `/32`. Surgical, doesn't lose routing for
   ~6% of IPv4.
9. **`FfiError` not surfacing its inner message.** uniffi's generated
   `FfiError` enum carries useful `message: String` payloads on every
   case but only conforms to `Error`, not `LocalizedError`. So
   `error.localizedDescription` collapsed to the unhelpful
   `"CloakVPN.FfiError error <N>"` form, hiding the actual reason.
   **Fix:** add a `LocalizedError` extension in `RosenpassBridge.swift`
   that pulls out and labels each variant's message.
10. **Protocol version dispatch (V02 vs V03).** The big finale.
    Rosenpass at b096cb1 supports two protocol versions:
    `ProtocolVersion::V02` uses Blake2b-keyed HMAC,
    `ProtocolVersion::V03` uses keyed SHAKE256. Each peer entry has
    its own `protocol_version`. The iOS client at b096cb1 defaults to
    V03 (SHAKE256). The server's TOML `[[peers]]` block defaults to
    V02 (Blake2b) when `protocol_version` is unset. Server
    received the InitHello, tried Blake2b → failed, tried SHAKE256
    → also failed (the per-peer `verify_hash_choice_match` blocks
    cross-matching even when SHAKE256 *would* parse it), and bailed
    with `"No valid hash function found for InitHello"`. **Fix:**
    explicitly set `protocol_version = "V03"` in `[[peers]]` blocks.
    `add-peer.sh` now writes this automatically.

### Manual config import: known sharp edges

The current "AirDrop a `.txt` file → iOS Files app → Import from file" flow
has multiple failure modes that are easy for a user to hit, and we hit
several of them ourselves during the 2026-04-26 client-keygen smoke
test (took ~3 hours of debugging the wrong server):

1. **`_peer-config*.txt` files accumulate in iOS Files across days.** Every
   AirDrop session leaves a fresh copy. After a few sessions there might
   be 5+ files, all with the same name but different contents (different
   regions, different keys, different generations). The Files import
   picker shows them by filename only — picking by the wrong timestamp
   silently imports a stale config. The user only notices when the in-app
   `Endpoint:` line shows a different IP than expected.
2. **iOS Settings → VPN profile state is sticky.** Even after deleting
   the in-app config, iOS retains the `NETunnelProviderManager` until
   explicitly removed via Settings → General → VPN & Device Management →
   VPN → Delete. A new import overwrites in-memory state but not always
   the system profile, leading to "iPhone shows Connected to wrong
   server" symptoms.
3. **App Group container survives Delete VPN, but NOT app uninstall.**
   The locally-generated rosenpass keypair lives in the App Group
   container. If the user uninstalls and reinstalls CloakVPN to recover
   from a wedged state, they get a fresh keypair — but the server still
   has the OLD pubkey registered, so handshakes silently fail with no
   useful error. We saw fingerprint `4ef3ae725f7c592e` (Day 1) get
   replaced by `15541d6003735382` (Day 2 after reinstall), and spent
   ~30 minutes debugging "stuck on handshaking" before realizing the
   server was registered against Day 1's pubkey.
4. **No in-app verification that the imported config is current.** The
   only signal is the `Endpoint:` line in the info panel, which means
   the user has to manually compare against expectations. There's no
   `import-time` warning if the imported config is older than a prior
   one, no fingerprint-of-server-pubkey display for cross-checking
   against the server-side admin.

These all have product-roadmap fixes (next subsection), but for tonight's
operators: when a smoke test fails, **first check the in-app Endpoint
line matches the server you THINK you're talking to**. Multiple regions
and multiple AirDrops across days makes this easy to mix up.

### Roadmap: native provisioning (eliminates the manual import flow)

The "AirDrop a config file" provisioning model is fine for an alpha
proof-of-concept, but is the wrong UX for any real product. Future
versions should support **native in-app provisioning**:

- **App generates rosenpass keypair on first launch** (already shipped
  via `ensureLocalKeypair()`).
- **App registers with a Cloak control-plane API** over PQ-hybrid TLS
  (`X25519MLKEM768`). Sends only its public key. Receives:
  - The user's WireGuard private key (or, ideally, the user generates
    that locally too — Phase 1.1 follow-up).
  - The server's WireGuard + rosenpass public keys.
  - The peer-assigned IPs, region endpoint, etc.
- **Server-side enrollment** is just a thin HTTPS shim around the
  current `add-peer.sh` flow, called from a Go service we already
  scaffold in `server/api/`. Effectively replaces the manual
  `scp pubkey + add-peer.sh + scp config + AirDrop` chain with a
  single in-app tap.
- **Region picker** in the app — list of available regions fetched
  from the API, user picks one or "auto" (lowest-latency). No more
  per-region config files to manage.
- **Re-keying / rotation flow** in the app — "rotate my PQC identity"
  generates a fresh keypair on-device and re-enrolls with the server,
  without uninstall/reinstall.
- **Subscription gating** — control-plane API checks a Stripe customer
  ID before issuing a peer config. Lapsed-subscription deactivates
  via `del-peer.sh` (which we still need to write).

This is a Phase 1 → Phase 2 transition feature. Eliminates ~all the
sharp edges in the previous subsection. Engineering size: ~2-3 weeks
of focused work — the components mostly exist (ios-side keygen done,
server-side `add-peer.sh` already pubkey-aware, Go API stub already
in `server/api/`). The integration is the work.

Tracked separately as task #35.

### Notes for future regions / future operators

- When bumping the iOS FFI's rosenpass git rev, also bump
  `ROSENPASS_REV` in `server/scripts/setup.sh` and re-run `setup.sh`
  on every server. Drift between client and server rosenpass is the
  #1 gotcha and will cost you hours.
- `add-peer.sh` is not idempotent. Re-running it for the same peer
  name produces stale entries. If you need to re-issue keys for a
  peer, manually clean the entries from `wg0.conf` and `server.toml`
  first.
- iOS NE failures during launch produce **no logs visible to the host
  app**. If you tap Connect and the status flickers
  `Connecting → Disconnected` with nothing in the Xcode console,
  immediately check (a) Signing & Capabilities for both targets,
  (b) `providerBundleIdentifier` matches the NE's
  `PRODUCT_BUNDLE_IDENTIFIER` exactly, (c) the entitlements are
  reflected in the active provisioning profile.
- iOS NE state can wedge after a few failed connection attempts. If
  Connect/Disconnect taps stop responding, the recovery is:
  Settings → General → VPN & Device Management → VPN → Delete VPN,
  then force-quit the app, re-import config, retry. iOS won't
  auto-clear a half-installed profile.
- Console.app's process filter requires the *exact* casing (`CloakTunnel`,
  not `cloak`). Plain text search matches any field, which is usually
  what you want. The default "ANY" dropdown is fine for keyword search.

## What's still open

- [x] Wire the FFI scaffolding's TODO stubs to real `rosenpass::protocol`
  calls.
- [x] Build pipeline that produces an `.xcframework` consumable by
  Xcode (`build-xcframework.sh`).
- [x] Memory profile on physical iPhone.
- [x] Wire `RosenpassBridge.swift` + `PacketTunnelProvider.swift` in
  the existing iOS skeleton to the FFI.
- [x] App Group entitlement + `sendProviderMessage` PSK push.
- [x] First end-to-end PSK derivation against `fi1.cloakvpn.ai:9999`.
- [x] WireGuardKit integration in `PacketTunnelProvider`.
- [ ] **Replace the `0.0.0.0/0`-minus-`192.0.0.0/4` AllowedIPs hack
  with surgical `excludedRoutes` in `PacketTunnelProvider`.** (Mullvad
  pattern — adds back tunnel routing for the ~6% of IPv4 we currently
  carve out, without re-introducing the rosenpass-UDP-through-tunnel
  problem.) Tracked as task #29.
- [ ] **Move rosenpass keypair generation onto the device.** Currently
  the server runs `rosenpass gen-keys` per peer and ships both halves
  of the keypair in the config file. This means the server holds
  every client's PQ private key — fundamentally defeats the privacy
  guarantee post-quantum is supposed to provide, since a server
  compromise (or "harvest now, decrypt later" against the config
  delivery channel) lets an adversary decrypt every PQ-protected
  session retroactively. Hard prerequisite before any beta. The iOS
  FFI's `generateStaticKeypair()` is already verified-working
  on-device; the missing piece is a server endpoint that registers a
  client's public key by upload rather than generating it. Tracked
  as task #22.
- [ ] **Propagate fi1 fixes to de1 and any future regions.** Rerun
  `setup.sh` (now with the pinned `ROSENPASS_REV`) and `add-peer.sh`
  (now with `protocol_version = "V03"`) on each region's server.
  Tracked as task #31.
- [ ] **TestFlight signing for non-developer device builds.** Requires
  App Store Connect bundle ID registration for both
  `ai.cloakvpn.CloakVPN` and `ai.cloakvpn.CloakVPN.CloakTunnel`,
  plus distribution provisioning profiles per target.
- [ ] **App Store review submission.** Privacy nutrition labels,
  the "Why does this app need a VPN extension" justification, the
  PQC marketing description, and the audit/security disclosures
  for app review (Apple is sensitive about VPN apps).

## References

iOS NE memory:
- [Apple Forums: NEPacketTunnelProvider Memory Limits](https://developer.apple.com/forums/thread/106377)
- [Apple Forums: iOS 17 NE memory limit (Eskimo)](https://developer.apple.com/forums/thread/763392)
- [Apple Forums: NE killed by jetsam](https://developer.apple.com/forums/thread/97788)
- [Apple Forums: handleAppMessage IPC](https://developer.apple.com/forums/thread/110264)

Rosenpass:
- [Rosenpass project + whitepaper](https://rosenpass.eu/)
- [Rosenpass crate on docs.rs](https://docs.rs/rosenpass/latest/rosenpass/)
- [NLnet — Rosenpass Broker / Integration project](https://nlnet.nl/project/Rosenpass-integration/)

Cryptography sizes:
- [Open Quantum Safe — Classic McEliece sizes](https://openquantumsafe.org/liboqs/algorithms/kem/classic_mceliece.html)
- [Classic McEliece low-memory implementation paper (eprint 2022/1613)](https://eprint.iacr.org/2022/1613.pdf)

Competitor architectures:
- [Mullvad: Quantum-Resistant Tunnels on iOS](https://mullvad.net/en/blog/quantum-resistant-tunnels-now-available-on-ios)
- [Mullvad wgephemeralpeer (iOS reference architecture)](https://github.com/mullvad/wgephemeralpeer)
- [NetBird: How We Integrated Rosenpass](https://netbird.io/knowledge-hub/how-we-integrated-rosenpass)
- [NetBird issue #2629: iOS Rosenpass disabled](https://github.com/netbirdio/netbird/issues/2629)
- [IVPN: Quantum-Resistant VPN connections](https://www.ivpn.net/knowledgebase/general/quantum-resistant-vpn-connections/)
- [Cloudflare: WARP post-quantum cryptography](https://blog.cloudflare.com/post-quantum-warp/)

Threat model context:
- [Wikipedia: Harvest now, decrypt later](https://en.wikipedia.org/wiki/Harvest_now,_decrypt_later)
- [NIST IR 8547 PQC transition guidance](https://nvlpubs.nist.gov/nistpubs/ir/2024/NIST.IR.8547.ipd.pdf)

iOS architectural patterns:
- [Mozilla uniffi-rs](https://github.com/mozilla/uniffi-rs)
- [Darwin notifications across app extensions](https://nonstrict.eu/blog/2023/darwin-notifications-app-extensions/)
