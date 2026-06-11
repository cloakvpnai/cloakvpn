# Session Handover — 2026-06-11 — 🎉 Android LIVE on Google Play + iOS Build 109 ready

Follows `SESSION_HANDOVER_2026-06-05b_appstore-3.1.1-no-external-links.md`.

## 🎉 Headline: Lattice VPN is LIVE on Google Play
`https://play.google.com/store/apps/details?id=ai.latticevpn.android` is
published and installable. Listing: rating **Everyone** (IARC live notice
received), category Productivity, data-safety "No data shared / No data
collected," post-quantum messaging, screenshots all rendering. The
VpnService-declaration + demo-video fix (06-03) cleared review.

**Caveat shown on the listing:** "This app is available for some of your
devices" = the **16 KB page-size** gap (Android 15+ devices in 16 KB mode
can't install yet). Carried item — the `versionCode=3` 16 KB fix widens
device coverage. Not blocking; most devices install fine today.

## iOS — Build 109 ready to submit (supersedes 107/108)
Latest App Store rejection (Build 107, June 5) was Guideline 3.1.1 again:
Apple followed the in-app Privacy link to the marketing site's "Pricing" nav.
Fixes done across builds 108 → 109:
- **Website:** `Layout.astro` gained a `bare` prop; privacy, terms, recover,
  account pages now render with NO marketing nav/footer (no Pricing link).
  Deployed (CI). (commits `5148204`, `ab3f37a`)
- **iOS (build 108):** removed ALL app→website links except the two required
  bare legal pages. "Lost your account number?" link dropped; "Manage
  subscription" now → `https://apps.apple.com/account/subscriptions` (Apple's
  native sub management). (commit `76492e5`)
- **iOS (build 109):** added an in-app **Open-source licenses** screen
  (`AcknowledgementsView.swift` + bundled `ThirdPartyNotices.txt`, 13.7 KB,
  confirmed in the .app), crediting WireGuard (MIT/Apache-2.0), Rosenpass
  (Apache-2.0/MIT), liboqs (MIT) with full license texts. Linked from
  Account → About. Also repo `THIRD_PARTY_NOTICES.md`. (commit `24ac44b`)
- **Build 109** archived, in Organizer (2026-06-05), installed on device.

### iOS NEXT STEP (user)
Upload **Build 109** (not 108 — 109 has the license compliance too), attach
the 4 IAPs to the version, submit. Reply re: removed all external-purchase
links; legal pages are now standalone; IAP only. Build 109 > 108 > 107.

## Website — reflects Android live (this session)
Most of the site already showed Android as available. Fixed one stale
leftover: `ClosingCTA.astro` eyebrow said "AVAILABLE NOW ON IPHONE" while its
button was Google Play → now "AVAILABLE NOW ON GOOGLE PLAY." Deployed via CI.
(Navbar, Footer, Hero, Platforms already correct: Android = available, iPhone
/macOS = coming soon, all linking the live Play URL.)

## Licensing question (resolved, context)
User asked whether building on Rosenpass = "ripping off" an existing VPN.
Answer: no. Rosenpass is a PQC key-exchange tool/protocol for WireGuard (a
building block, not a consumer product), dual Apache-2.0/MIT. Using it like
Mullvad/Nord use WireGuard is legitimate. The one real obligation —
attribution — is now satisfied by the iOS acknowledgements screen (and should
be added to Android too; see below).

## Still open (carried)
- **Android acknowledgements screen** — Android bundles the same libs
  (WireGuard, Rosenpass, liboqs); add an equivalent "Open-source licenses"
  screen + notices for parity/compliance. NOT yet done.
- **Android v1.0.1 16 KB page fix** (versionCode=3) — widens device support.
- **iOS PQC re-provision loop** (recovery re-provisions on region switch).
- **iOS account recovery via iCloud Keychain** (IAP restore across reinstalls).

## Reference
- Commits this session: `24ac44b` (iOS acknowledgements, build 109),
  website ClosingCTA fix (committed this session). Earlier: `5148204`,
  `ab3f37a`, `76492e5`.
- Play URL: play.google.com/store/apps/details?id=ai.latticevpn.android
- iOS build = **109**; bundle `ai.cloakvpn.CloakVPN`; App ID `6764261045`.
- Website auto-deploys on push to `website-v2/**` (GitHub Actions →
  Cloudflare Pages `cloakvpn-ai`, serves latticevpn.ai + cloakvpn.ai).
