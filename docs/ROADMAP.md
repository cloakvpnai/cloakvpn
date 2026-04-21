# Cloak VPN roadmap

Honest sequence for a solo technical founder with ~$1k starting capital.

## Phase 0 — Prove it works (weeks 1–8, ~$170)

**Goal:** single-region PQC-protected tunnel, both apps connect, you have a public GitHub repo and blog post to point at.

- [ ] Rent Hetzner CX22 in Finland (€3.79/mo). Point a domain at it.
- [ ] Run `server/scripts/setup.sh`. Verify `wg show` shows rotating PSK every ~2 min.
- [ ] Open Xcode project per `clients/ios/README.md`. Wire up WireGuardKit. Ship debug build to a personal iPhone.
- [ ] `./gradlew :app:installDebug`. Verify connect on a personal Android.
- [ ] Publish the repo on GitHub. Write one technical blog post: "How Cloak VPN's post-quantum key exchange works."
- [ ] **Decision gate:** does everything work? If yes → Phase 1. If no → debug.

Budget: server (€30 for 8 weeks), domain ($12), Apple Developer ($99/yr). Google Play Console deferred until real beta ($25 one-time).

## Phase 1 — Private alpha (weeks 9–24, ~$500)

**Goal:** 10–50 paying alpha users, both apps polished enough to submit to stores.

- [ ] Second Hetzner region. Update `setup.sh` to accept a `REGION` env var and tag servers.
- [ ] Polish iOS/Android UX: config QR code scanning, multi-region picker, autoconnect on Wi-Fi untrust.
- [ ] Ship Rosenpass JNI/FFI bridges so PQC runs end-to-end, not just server-side.
- [ ] Simple Go API (`/signup`, `/device`, `/pay`) behind Caddy with TLS 1.3 hybrid group.
- [ ] Stripe integration for card payments. BTCPay server for crypto.
- [ ] Recruit 20 alpha testers from r/privacy. $5/mo flat, no annual discount.
- [ ] **Decision gate:** do 25+ users pay after the 30-day trial? If yes → Phase 2. If no → pivot.

Budget: 2× server (€80 for 4 months), Google Play ($25), Stripe (no upfront), misc ($50).

## Phase 2 — Public launch (months 6–12, $15k–150k)

**Goal:** published audit, 5+ regions, 500+ paying users, credible brand.

- [ ] Commission Cure53 or SEC Consult focused audit ($15–35k).
- [ ] Scale to 5–10 regions across jurisdictions.
- [ ] Implement on-device tracker/malware blocker (bundled DNS filter list + optional TinyLlama/MobileBERT-class model for URL classification — keep APK under 30MB).
- [ ] Smart server selection (on-device).
- [ ] Public launch: Show HN, blog post on audit findings, submit to /r/privacy wiki.
- [ ] **Decision gate:** CAC < 6-month LTV? If yes, modest paid spend. If no, stay content-led.

## Phase 3 — Scale (year 2+)

- Multi-hop / Secure Core (two-server chaining).
- Own hardware in one or two jurisdictions (OVPN-style).
- Additional platforms: macOS, Windows, Linux.
- Business tier for small teams.
- Replace Rosenpass with a ML-KEM-native handshake once WireGuard upstream adds protocol support (not expected before 2027).

## What could derail this

- **Apple or Google pulling the app.** Mitigate with alt-store and direct IPA/APK downloads for signed users.
- **Hetzner or OVH terminating for abuse.** Have a second provider preconfigured; document IP rotation cadence.
- **A competitor ships the same PQC + AI narrative first.** Rely on transparency/openness moat (reproducible builds, audit cadence).
- **You burn out solo.** Set one hard rule: 20 hours/week max, 1 weekend day off, quarterly 1-week breaks. This is a marathon, not a sprint.
