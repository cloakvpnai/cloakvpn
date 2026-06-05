# Session Handover — 2026-06-05 — App Store 3.1.1 round 4 (stale metadata pricing URL)

Follows `SESSION_HANDOVER_2026-06-03_appstore-3.1.x-and-play-vpn-declaration.md`.

## What happened
Apple reviewed **Build 107** (1.0) and rejected again under **Guideline
3.1.1** — but this time it's a **single, narrow metadata issue**, not the app:

> the app's metadata includes the following ... URL that directs users to
> external mechanisms for purchases: **https://cloakvpn.ai/pricing/**

This is a stale leftover from the old **Cloak** branding (old domain + a
`/pricing` purchase page) sitting in an App Store Connect listing field.

## Verified
- **The binary is clean** — grep of `clients/ios/**.swift` shows **no
  `/pricing` link and no purchase CTA**. External URLs in the app are only:
  `latticevpn.ai/privacy`, `latticevpn.ai/terms`, `latticevpn.ai/recover`
  (recover = account-number recovery, not purchase), plus IP-check hosts.
  So this is **metadata-only — no new build required** to fix.

## Fix (user, in App Store Connect — metadata only, resubmit Build 107)
Find and delete `cloakvpn.ai/pricing` from the listing. Check in order:
1. **App Information → Marketing URL** (most likely). Set blank or
   `https://latticevpn.ai` (homepage, NOT /pricing).
2. **App Information → Support URL**.
3. **1.0 version → Description**, **Promotional Text**, **What's New**.
4. Also confirm the **Privacy Policy URL** points to `latticevpn.ai/privacy`,
   not the old `cloakvpn.ai` (same era of leftover).
Then Submit for Review (keep Build 107). Reply: "We removed the external
pricing URL (cloakvpn.ai/pricing) from the app metadata. Subscriptions are
available only via In-App Purchase in the app."

## Code cleanup done (ships in next build, NOT required for this resubmit)
`ContentView.swift` Account screen had two stale old-domain links — fixed to
Lattice (commit `045c964`):
- privacy link `cloakvpn.ai/privacy` → `latticevpn.ai/privacy`
- support email `support@cloakvpn.ai` → `support@latticevpn.ai`
These are NOT purchase links, so they didn't trigger 3.1.1. Build 107 still
contains the old ones; ship the fix in the first update (1.0.1).

## Still open (carried)
- **PQC re-provision loop** (iOS recovery re-provisions on region switch).
- **Android v1.0.1 16 KB page fix** (versionCode=3).
- **iOS account-number recovery via iCloud Keychain** (IAP restore across
  reinstalls).
- **Google Play**: VpnService declaration + demo video resubmitted 06-03 — in
  review.

## Reference
- Commits this round: `045c964` (stale-link cleanup).
- iOS in-review build = **107**; bundle `ai.cloakvpn.CloakVPN`; App ID
  `6764261045`; team `5HYY2YP2G9`.
