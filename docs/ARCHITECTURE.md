# Cloak VPN architecture (Phase 0)

A single-diagram explanation of how Cloak VPN works today, and where PQC lives.

```
   ┌──────────────────────────────┐                       ┌──────────────────────────────┐
   │    iOS / Android client       │                       │        Cloak VPN server       │
   │                               │                       │  (Hetzner CX22, Ubuntu 24.04) │
   │  ┌────────────────────────┐   │  UDP 9999 (PQ handshake)│  ┌────────────────────────┐ │
   │  │ Rosenpass (Phase 1: on-│ ◄─┼──────────────────────►┼─►│ rosenpass (systemd)     │ │
   │  │ device via JNI/FFI)    │   │  every ~120 s         │  └───────────┬────────────┘ │
   │  └────────────┬───────────┘   │                       │              │             │
   │               │ PSK (32B)     │                       │              │ writes PSK  │
   │               ▼               │                       │              ▼             │
   │  ┌────────────────────────┐   │  UDP 51820            │  ┌────────────────────────┐ │
   │  │ WireGuard              │ ◄─┼──────────────────────►┼─►│ WireGuard (kernel)      │ │
   │  │ (wireguard-apple /     │   │  ChaCha20-Poly1305    │  │ wg0, NAT → eth0         │ │
   │  │  wireguard-android)    │   │  over Noise IKpsk2    │  └────────────────────────┘ │
   │  └────────────────────────┘   │                       │                              │
   └──────────────────────────────┘                       └──────────────────────────────┘
```

## Why this shape

- **WireGuard** is the industry-standard modern VPN tunnel: small (~4000 lines of kernel code), fast, minimal attack surface, and natively supported on all target platforms.
- **WireGuard's Noise handshake** (Noise_IKpsk2) bakes a pre-shared key into the key-derivation transcript. If the PSK has high entropy and is unknown to an attacker, the tunnel remains confidential even if the classical Curve25519 exchange is broken by a quantum adversary.
- **Rosenpass** generates that PSK using a post-quantum-secure hybrid of Classic-McEliece (KEM, long-term) and Kyber (KEM, ephemeral). Academic audit by Lange et al., Rust implementation, MIT/Apache licensed. The daemon rotates the PSK every ~120 seconds, giving near-forward-secrecy even for an attacker who compromises long-term keys later.
- Everything runs **on top of unmodified WireGuard**. No forking the kernel module, no waiting for upstream to adopt ML-KEM natively.

## What "post-quantum" actually means here

For each 2-minute window the tunnel is live:

- Confidentiality is preserved against a **quantum adversary who recorded the handshake today** and tries to decrypt it after breaking X25519, because the PSK mixed in came from a PQC-secure KEM.
- Authentication is **still classical** (WireGuard's public-key identity is Curve25519). A future quantum attacker *could* impersonate either peer in a future session — but cannot retroactively decrypt captured traffic (the important guarantee for "harvest now, decrypt later" threats).
- **Roadmap (Phase 2):** add a full Noise-like PQ-authenticated handshake (e.g., Mullvad's ML-KEM + Ed25519 PSK approach ported to Rosenpass, or migrate to a ML-KEM-native protocol).

## Phase 0 vs Phase 1 vs Phase 2

| Capability | Phase 0 (now) | Phase 1 (3–6 mo) | Phase 2 (6–12 mo) |
|---|---|---|---|
| WireGuard tunnel on both clients | ✅ | ✅ | ✅ |
| Rosenpass PSK on server | ✅ | ✅ | ✅ |
| Rosenpass PSK from client | ❌ (server-only) | ✅ (JNI + Swift FFI) | ✅ |
| PQ authentication | ❌ | ❌ | ✅ (ML-KEM + signatures) |
| On-device tracker/malware blocker | ❌ | ✅ (simple blocklist) | ✅ (ML classifier) |
| Smart server selection | ❌ | ✅ (local latency heuristic) | ✅ (on-device ML) |
| Reproducible builds | ✅ (target from day 1) | ✅ | ✅ |
| Third-party audit | ❌ | Scoped | Published |

## Control plane (future work)

Phase 0 has **no server-side API** — you run `add-peer.sh` over SSH and hand the user a config. That is fine for 5–50 alpha users.

Phase 1 adds a small Go or Rust HTTPS API at `https://api.cloakvpn.io` behind TLS 1.3 with the hybrid `X25519MLKEM768` group:

```
POST /v1/signup        → returns account number + first device config
POST /v1/device        → adds a device to existing account
POST /v1/billing/pay   → Stripe card or crypto payment intent
GET  /v1/servers       → public list of active regions
```

The API stores only: account number, WireGuard public key, device name, subscription expiry. Never: email, IP, traffic, DNS queries.

## No-logs architecture

1. **`/var/log` is tmpfs.** Applied in `setup.sh`. Syslog, journald, everything — wipes on reboot.
2. **WireGuard writes nothing by default.** `wg show` state is kernel-memory only.
3. **Rosenpass `verbosity = "Quiet"`.** Set in `server.toml`.
4. **No Nginx/HTTP access logs** in Phase 1 API (configure `access_log off;`).
5. **Scheduled reboots weekly** guarantee any stray on-disk artifact is erased.
6. **Audit plan:** Cure53 or SEC Consult focused audit in Phase 2, verifying the above.

## Threat model (what this design defends against)

| Adversary | Can they do this? |
|---|---|
| Passive network observer (ISP, airport Wi-Fi) | ❌ Cannot see DNS or plaintext traffic. |
| Active MITM with current crypto knowledge | ❌ WireGuard's authenticated handshake rules this out. |
| Future quantum adversary with recorded traffic | ❌ (for any session protected by Rosenpass PSK) |
| Compromised VPS provider (Hetzner) reading RAM | ⚠️ Possible. Mitigation: own hardware (Phase 3), multi-hop, or trusted-execution-environment hosts. |
| Legal demand served on operator | ✅ Nothing to hand over — architecture enforces no-logs. |
| Malware already on user device | ❌ Out of scope for any VPN. |

## Explicit non-goals (for now)

- **Not Tor.** We do not provide anonymity against a global passive adversary.
- **Not multi-hop.** Single tunnel only in Phase 0–1.
- **Not split tunneling.** All traffic or none. Split tunneling ships in Phase 2.
- **Not AI cloud features.** Any ML runs on-device only.
