# Cloak VPN — App Store Connect Metadata

This document is the source of truth for all the text fields you'll
paste into App Store Connect when submitting Cloak VPN. Update this
file when copy changes, then re-paste from here. That way the live
listing and the repo never drift apart.

---

## App information

- **App name (30 chars max):** `Cloak VPN`
- **Subtitle (30 chars max):** `Post-quantum no-logs VPN`
- **Bundle ID:** `ai.cloakvpn.CloakVPN`
- **Primary category:** Utilities
- **Secondary category:** Productivity
- **Age rating:** 17+ (required for VPN apps — Apple's standard policy)
- **Copyright:** `© 2026 Neuro AI Studios`

---

## Promotional text (170 chars max — editable without re-review)

```
Quantum-resistant VPN protection. Pick a region, tap connect. Your traffic is shielded with WireGuard + post-quantum Rosenpass key exchange. No logs, ever.
```

---

## Description (4000 chars max — re-review required to change)

```
CLOAK VPN — Quantum-resistant privacy in one tap.

Your encrypted internet traffic today might be quietly archived by adversaries waiting for quantum computers to crack it tomorrow. Cloak VPN closes that gap with post-quantum cryptography on every connection — your data stays private even against future quantum attackers.

WHAT MAKES CLOAK DIFFERENT

· POST-QUANTUM PROTECTION
Cloak combines WireGuard (the fastest modern VPN) with Rosenpass — an academically-audited post-quantum key exchange using NIST-standardized algorithms. A fresh quantum-safe key is rotated every two minutes. No other consumer VPN does this today.

· STRICT NO-LOGS
We do not log your real IP, your DNS queries, your browsing history, or your bandwidth use. We can't hand over what we never collected. Read our complete privacy policy at cloakvpn.ai/privacy.

· KILL SWITCH BY DEFAULT
If your VPN tunnel ever drops, no traffic leaks to your ISP. iOS keeps the kill switch enforced even during reconnection.

· FAST GLOBAL REGIONS
Connect to high-performance servers in the US (West and East), Germany, and Finland. Tap a flag to switch. We run on bare-metal Hetzner infrastructure tuned for low latency.

· CLEAN, BEAUTIFUL UI
A premium interface designed to disappear. Tap CONNECT and forget about it.

WHAT'S INSIDE

· WireGuard tunnel for fast, modern transport
· Rosenpass post-quantum key-exchange (Classic McEliece + ML-KEM)
· Quad9 DNS resolution to prevent DNS leaks
· Full IPv4 and IPv6 leak protection via includeAllNetworks=true
· Auto-recovery from network changes and tunnel wedges
· No third-party trackers or analytics SDKs in the app

SUBSCRIPTION TIERS

· Cloak Basic — Two regions, single device. Best for casual everyday use.
· Cloak Pro — All four regions, additional bandwidth, priority support, custom Pro app icon. Best for power users and travelers.

Subscriptions auto-renew unless cancelled at least 24 hours before the end of the current period. Manage in your Apple ID Subscriptions settings.

WHO WE ARE

Cloak VPN is built by Neuro AI Studios. We are a small independent team focused on shipping privacy tools that actually work — not selling your data with extra steps.

Privacy policy: cloakvpn.ai/privacy
Terms of service: cloakvpn.ai/terms
Support: support@cloakvpn.ai
```

---

## Keywords (100 chars max, comma-separated, no spaces)

Note: Apple counts the comma-separated string. Reuse of words in the
title/subtitle is wasteful — Apple already indexes those.

```
quantum,postquantum,vpn,wireguard,encryption,privacy,security,nologs,killswitch,tunnel
```

---

## Support URL

```
https://cloakvpn.ai/support
```
(Currently mailto:support@cloakvpn.ai redirect — fine for launch.)

## Marketing URL (optional)

```
https://cloakvpn.ai
```

## Privacy Policy URL (REQUIRED)

```
https://cloakvpn.ai/privacy
```

---

## App Privacy declaration (App Store Connect → App Privacy section)

Must match `clients/ios/CloakVPN/PrivacyInfo.xcprivacy` exactly.

**Data Types Collected:**

| Data type | Linked to user? | Used for tracking? | Purpose |
|---|---|---|---|
| Device ID (per-install UUID) | No | No | App Functionality |
| Purchase History (StoreKit transaction ID) | Yes | No | App Functionality |

**Data NOT collected:** Contact info, health, financial info, location, sensitive info, contacts, user content, search history, identifiers (other than the per-install UUID), usage data, diagnostics.

**Tracking:** None. App does not link user/device data to third-party data for advertising or share data with data brokers.

---

## App Review notes (private — for Apple review team only)

```
Cloak VPN is a consumer VPN app with optional in-app subscriptions.

VPN entitlement (com.apple.developer.networking.vpn.api) is used to provide the VPN service that is the entire point of this app. The NetworkExtension entitlement (packet-tunnel-provider) is used by the bundled CloakTunnel.appex which runs the WireGuard tunnel.

How to test:
1. Install the app.
2. Tap any of the four region flags (US-W, US-E, Germany, Finland).
3. Wait for the spinner to clear (~3-5s for first-time provisioning).
4. Tap the green CONNECT button at the top.
5. iOS will prompt to allow VPN configuration — tap Allow.
6. Once connected, visit https://ipleak.net in Safari — IP should match the chosen region.
7. The post-quantum status indicator at the bottom should transition to "PQC: 1 rotation ✓" within ~60 seconds.

Subscription test (sandbox):
- Tap hamburger menu → Account → Plan preview → Pro
- A system alert may appear about icon change — accept it.
- Home screen icon switches to the gold-ringed Pro variant.

We do not send any user data to third-party analytics, advertising, or
crash reporting services. The only outbound network calls are:
1. To our own region API at https://cloak-{region}.cloakvpn.ai (TLS 1.3, Let's Encrypt) for tunnel provisioning.
2. To our region's WireGuard endpoint over UDP for the actual VPN traffic.
3. (Once IAP is wired) to Apple's StoreKit endpoints for receipt validation.

Demo subscription credentials are not required — the app's "Plan preview" picker in Account allows toggling Basic/Pro for review purposes.
```

---

## Localization

Initial release: English (US) only. Localization roadmap: ES, DE, FR, JA — to follow after first 1k users.

---

## Build & TestFlight

- Internal TestFlight group: yourself + 1 trusted reviewer
- External TestFlight group: 10 selected beta users — wait for ~1 week of clean usage before promoting to App Store

---

## Pre-submission checklist

- [ ] All four regions reachable + working (test from clean iPhone install)
- [ ] PrivacyInfo.xcprivacy declared and matches App Store Connect privacy panel
- [ ] Privacy Policy URL live at cloakvpn.ai/privacy
- [ ] Terms of Service URL live at cloakvpn.ai/terms
- [ ] Five 6.7" screenshots uploaded (see screenshot-guide.md)
- [ ] App description, keywords, promotional text pasted from this file
- [ ] App Review notes (above) pasted into the App Review Information section
- [ ] Sandbox subscription products configured in App Store Connect (when IAP ships)
- [ ] Tested on a real iPhone via TestFlight, not just simulator
