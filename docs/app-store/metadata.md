# Lattice VPN — App Store Connect Metadata

This document is the source of truth for all the text fields you paste
into App Store Connect when submitting Lattice. Update this file when
copy changes, then re-paste from here. That way the live listing and
the repo never drift apart.

> Rewritten 2026-07-09 for the Lattice rebrand + StoreKit IAP. The
> previous version of this file was Cloak-era (Neuro AI Studios,
> cloakvpn.ai URLs, website-only billing) and contradicted the shipping
> app. History: `git log -- docs/app-store/metadata.md`.

---

## App information

- **App name (30 chars max):** `Lattice`
- **Subtitle (30 chars max):** `Post-quantum no-logs VPN`
- **Bundle ID:** `ai.cloakvpn.CloakVPN` (legacy — bundle IDs are permanent; do not change)
- **Primary category:** Utilities
- **Secondary category:** Productivity
- **Age rating:** 17+ (required for VPN apps — Apple's standard policy)
- **Copyright:** `© 2026 KryptoKnightz LLC`

---

## Promotional text (170 chars max — editable without re-review)

```
Quantum-resistant VPN. No email, no password — just an account number. WireGuard + post-quantum keys. No logs, ever.
```

---

## Description (4000 chars max — re-review required to change)

Includes the Terms of Use (EULA) + Privacy Policy links required for
auto-renewable subscriptions (Guideline 3.1.2). Do not remove them.

```
LATTICE VPN — Post-quantum privacy in one tap.

Encrypted traffic intercepted today can be archived and cracked tomorrow, once quantum computers arrive. Lattice closes that gap now: every connection is protected with post-quantum cryptography, so your data stays private even against future quantum attackers.

NO EMAIL. NO PASSWORD. NO IDENTITY.

Lattice doesn't ask who you are. When you subscribe, you get a randomly generated account number — that's your only credential. There is no email address, no password, and no profile that could ever link your identity to your traffic.

WHAT MAKES LATTICE DIFFERENT

· POST-QUANTUM PROTECTION
Lattice combines WireGuard — the fastest modern VPN protocol — with Rosenpass, an academically audited post-quantum key exchange built on NIST-standardized algorithms. Your tunnel's quantum-safe key is refreshed automatically every few minutes.

· STRICT NO-LOGS
We do not log your browsing activity, your DNS queries, your real IP, or your connection history. Our servers run in volatile memory and are not configured to write activity logs to disk. We can't hand over what we never collected.

· KILL SWITCH BY DEFAULT
If your tunnel ever drops, nothing leaks to your ISP — iOS keeps enforcement active even while reconnecting, over Wi-Fi and cellular alike.

· FAST GLOBAL REGIONS
High-performance bare-metal servers across North America and Europe. Tap a region, tap connect, done.

· LEAK PROTECTION THAT'S ACTUALLY COMPLETE
Full IPv4 and IPv6 leak protection, hardened DNS resolution, and automatic recovery from network changes.

· NO TRACKERS
No analytics SDKs, no advertising frameworks, no third-party crash reporters. The app talks to our servers and Apple — no one else.

CHOOSE YOUR PLAN

· Lattice Basic — full access to every region, up to 3 devices.
· Lattice Pro — everything in Basic for up to 10 devices, plus priority support and an exclusive Pro app icon.

Both plans are available monthly or yearly, with two months free on yearly billing.

Payment is charged to your Apple Account at confirmation of purchase. Subscriptions renew automatically for the same price and duration unless cancelled at least 24 hours before the end of the current period. Manage or cancel anytime in your Apple Account's Subscriptions settings.

Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy Policy: https://latticevpn.ai/privacy
Support: support@latticevpn.ai
```

---

## Keywords (100 chars max, comma-separated, no spaces)

Note: Apple counts the comma-separated string. Reuse of words in the
title/subtitle is wasteful — Apple already indexes those.

```
quantum,postquantum,vpn,wireguard,encryption,privacy,security,nologs,killswitch,tunnel
```

---

## URLs

- **Support URL:** `https://latticevpn.ai` (no dedicated /support page yet;
  the site footer carries support@latticevpn.ai. Build a /support page
  before adding it here.)
- **Marketing URL (optional):** `https://latticevpn.ai`
- **Privacy Policy URL (REQUIRED):** `https://latticevpn.ai/privacy`
- **Terms of Service (linked from app purchase flow):** `https://latticevpn.ai/terms`

---

## In-App Purchases (auto-renewable subscriptions)

Subscription group with four products:

| Product | Product ID | Devices |
|---|---|---|
| Lattice Basic Monthly | `ai.cloakvpn.CloakVPN.basic.monthly` | 3 |
| Lattice Basic Yearly  | `ai.cloakvpn.CloakVPN.basic.yearly`  | 3 |
| Lattice Pro Monthly   | `ai.cloakvpn.CloakVPN.pro.monthly`   | 10 |
| Lattice Pro Yearly    | `ai.cloakvpn.CloakVPN.pro.yearly`    | 10 |

- Each promoted IAP has a **unique** 1024×1024 promotional image
  (Guideline 2.3.2 — duplicates get rejected). Masters live in
  `Cloak VPN Logos/Promo Images - Final/` (Basic = teal shield,
  Pro = multicolor; Monthly = orbit arc, Yearly = gold 12-dot ring;
  each labeled with tier + duration).
- The in-app paywall (`clients/ios/CloakVPN/PaywallView.swift`) shows
  title, duration, price, auto-renewal terms, and functional Terms of
  Use + Privacy Policy links (Guideline 3.1.2).
- Android sells the equivalent products through Google Play Billing;
  the web sells via Stripe on latticevpn.ai/pricing. All three channels
  mint the same account-number credential.

---

## App Privacy declaration (App Store Connect → App Privacy section)

Must match `clients/ios/CloakVPN/PrivacyInfo.xcprivacy` exactly.

**Data Types Collected:**

| Data type | Linked to user? | Used for tracking? | Purpose |
|---|---|---|---|
| Device ID (per-install UUID) | No | No | App Functionality |
| Purchase History (StoreKit transaction ID) | Yes | No | App Functionality |

**Data NOT collected:** Contact info, health, financial info, location,
sensitive info, contacts, user content, search history, identifiers
(other than the per-install UUID), usage data, diagnostics.

**Tracking:** None. App does not link user/device data to third-party
data for advertising or share data with data brokers.

---

## App Review notes (private — for Apple review team only)

Keep the real account number OUT of git — fill it in only in the store
console. See also `docs/APP_REVIEW_NOTES.md` for the shared iOS/Android
reviewer-credentials process.

```
Lattice is a consumer VPN app with auto-renewable subscriptions sold via
in-app purchase (StoreKit 2).

AUTHENTICATION MODEL
Lattice uses account-number authentication (no email, no password), the
same approach as Mullvad VPN. There is nothing to "sign up" for with
personal information. Subscribing (via IAP, Google Play, or our website)
mints a random account number, which is the user's only credential.

To sign in for review:
1. Launch the app and tap "I already have an account."
2. Enter this account number: [ACCOUNT NUMBER]
3. Tap Connect to establish the VPN tunnel (iOS will prompt to allow the
   VPN configuration — tap Allow).

Alternatively, purchase any plan in the sandbox environment from the
paywall; a fresh account number is minted and signed in automatically.

AUTO-RENEWABLE SUBSCRIPTION INFORMATION (Guideline 3.1.2)
- The purchase flow (paywall) displays subscription title, duration,
  price, auto-renewal terms, and functional Terms of Use and Privacy
  Policy links.
- Terms of Use (EULA): standard Apple EULA, linked in the App
  Description (https://www.apple.com/legal/internet-services/itunes/dev/stdeula/).
  Our service terms are also at https://latticevpn.ai/terms.
- Privacy Policy: https://latticevpn.ai/privacy

VPN ENTITLEMENTS (Guideline 5.4)
The VPN entitlement is used to provide the VPN service that is the
entire point of this app. The NetworkExtension packet-tunnel-provider
entitlement is used by the bundled CloakTunnel.appex, which runs the
WireGuard + Rosenpass post-quantum tunnel. No data is logged; see
https://latticevpn.ai/privacy.

NETWORK CALLS
No third-party analytics, advertising, or crash-reporting services.
Outbound calls are limited to: (1) our provisioning API at
api.latticevpn.ai, (2) our region servers' WireGuard endpoints (UDP),
(3) Apple StoreKit, (4) an IP-lookup call (ipify.org) to display the
user's current IP inside the app.
```

---

## Localization

Release: English (US) only. Localization roadmap: ES, DE, FR, JA.

---

## Pre-submission checklist

- [ ] All regions reachable + working (test from clean iPhone install)
- [ ] PrivacyInfo.xcprivacy declared and matches App Store Connect privacy panel
- [ ] Privacy Policy live at latticevpn.ai/privacy
- [ ] Terms of Service live at latticevpn.ai/terms (check it is NOT the
      "PHASE 3" placeholder — that caused the 2026-07-09 3.1.2 rejection)
- [ ] Description includes the Apple standard EULA link (3.1.2)
- [ ] Four promoted-IAP promotional images are all unique (2.3.2)
- [ ] Screenshots current
- [ ] Description, keywords, promotional text pasted from this file
- [ ] App Review notes pasted, [ACCOUNT NUMBER] filled in with a live
      reviewer account (resubscribe if lapsed — an expired reviewer
      account = Guideline 2.1 rejection)
- [ ] Reply to any open App Review message with a screen recording of
      the paywall → Terms of Use → Privacy Policy flow
