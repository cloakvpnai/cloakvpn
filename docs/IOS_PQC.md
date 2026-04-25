# Post-Quantum Crypto on iOS — Architecture Decision Record

Status: ✅ Decision made 2026-04-25.
Reviewer: solo project, single decision-maker.
Implementation status: scaffolded; cross-compile validated.

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

## What's NOT yet done (subsequent days)

- [ ] Wire the FFI scaffolding's TODO stubs to real `rosenpass::protocol`
  calls. (Expected ~4 hours work.)
- [ ] Build pipeline that produces an `.xcframework` consumable by
  Xcode. (Expected ~1 day; can lift Mullvad's `xcframework` shell
  scripts.)
- [ ] Wire `RosenpassBridge.swift` + `PacketTunnelProvider.swift` in
  the existing iOS skeleton to the FFI.
- [ ] App Group entitlement + `sendProviderMessage` PSK push.
- [ ] First end-to-end PSK derivation against `fi1.cloakvpn.ai:9999`.
- [ ] Memory profile on physical iPhone SE 2 (worst-case device for
  jetsam pressure) using Instruments → Allocations + VM Tracker.
- [ ] App Store review submission (privacy nutrition labels, "Why does
  this app need a VPN extension" justification, etc.).

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
