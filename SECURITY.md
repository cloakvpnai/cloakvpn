# Security Policy

Cloak VPN takes the security of its users seriously. This document explains how to report vulnerabilities and what to expect from us.

## Reporting a vulnerability

**Email:** `security@cloakvpn.ai`

**What to include:**
- A description of the vulnerability and the affected component (iOS app, server, infrastructure scripts, FFI, etc.)
- Steps to reproduce, or a proof-of-concept if you have one
- The version / commit hash of the code where you found the issue
- Your name or handle if you'd like credit; we honor anonymity if you prefer

**Please do not:**
- Open a public GitHub issue for the vulnerability
- Disclose the issue publicly before we've had a chance to investigate and ship a fix
- Test against production servers in ways that could affect other users (rate-limiting bypass attempts, denial of service, etc.)

## What we'll do

- **Acknowledge** your report within **72 hours**.
- Provide an initial assessment of severity and likely fix timeline within **7 days**.
- Keep you informed of progress through to remediation.
- Credit you in the release notes and (if you wish) in this repository's contributors when the fix lands. We do not currently run a paid bug bounty program; that may change as the project matures.

## Scope

**In scope:**
- The iOS client (`clients/ios/`) — including the NetworkExtension, RosenpassFFI, and any cryptographic logic
- Server bootstrap and operational scripts (`server/scripts/`)
- The Cloak API (`server/api/`) once deployed
- Terraform infrastructure (`infra/`)
- Anything in this repository's published commits

**Out of scope:**
- Third-party services we depend on (Hetzner, Apple's NetworkExtension framework, the rosenpass upstream, the WireGuard upstream)
- Issues that require physical access to a user's device
- Issues that require an attacker to already have full root on the user's iPhone or our server
- Theoretical attacks against the underlying cryptographic primitives (Classic McEliece-460896, ML-KEM-768, X25519, ChaCha20-Poly1305) — those should be reported to the relevant standards body or upstream project

## Cryptographic primitives

Cloak VPN composes well-known primitives. We do **not** roll our own crypto. The cryptographic surface includes:

- **WireGuard** — Noise IKpsk2 handshake, ChaCha20-Poly1305 AEAD, Curve25519 ECDH, BLAKE2s
- **Rosenpass** — Classic McEliece-460896 + ML-KEM-768 hybrid KEM, formally analyzed (ProVerif + CryptoVerif), peer-reviewed academic protocol [https://rosenpass.eu/whitepaper.pdf]

If you find an issue in the protocol composition or implementation glue (for example, a way to leak a derived PSK across processes, a race condition in the App Group handoff, or a way to coerce a downgrade from PQ to classical-only), that is in scope and we want to hear about it.

## Audits and transparency

We aim to publish:
- Third-party security audit reports as they become available
- Infrastructure transparency reports
- A canary statement when applicable

These will land in the `docs/` directory of this repository when ready.

## Coordinated disclosure

For high-severity issues affecting active users, we'll typically aim for **30–90 days** between report and public disclosure, depending on complexity. We're happy to negotiate a different window with you on a case-by-case basis.

Thanks for helping keep Cloak users safe.
