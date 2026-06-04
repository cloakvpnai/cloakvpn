# Session Handover — 2026-06-03 — App Store round 3 (3.1.x) + Play VpnService declaration

Follows `SESSION_HANDOVER_2026-06-01_iap-storekit-3.1.1.md`.
Both stores were rejected again and re-fixed this session. **Both apps are now
back in review.**

---

## TL;DR — where things stand

| Area | Status |
|------|--------|
| App Store (iOS) | **Build 106 fixes done; resubmitted (user) → in review.** Round-3 rejection was 3.1.1 + 2.1(b) + 3.1.2(c). |
| Google Play (Android) | **VpnService declaration completed + demo video added → in review.** |
| PQC re-provision loop (iOS) | **STILL OPEN** (from prior handover). |
| Android v1.0.1 16 KB page fix | **STILL OPEN.** |

---

## App Store — Build 105 rejected (3 items), fixed in Build 106

Rejection (review June 3, build 105):
- **3.1.1 — "custom code to unlock subscriptions."** Read as: reviewer saw the
  account-number sign-in as the only purchase path, because (see 2.1b) the
  IAPs weren't actually in the submission.
- **2.1(b) — App Completeness.** "One or more IAP products have not been
  submitted for review." **Root cause** — the four subscriptions existed but
  were **not attached to the version submission**. Fix: on the 1.0 version
  page → In-App Purchases and Subscriptions → add all four → submit WITH the
  binary.
- **3.1.2(c) — Subscriptions.** App's purchase flow must show title/length/
  price **and functional Terms of Use (EULA) + Privacy Policy links**. The
  paywall had no legal links.

Fixes (Build 106, committed `69fd2ce`):
- `PaywallView.swift`: added **Terms of Use** (`latticevpn.ai/terms`) +
  **Privacy Policy** (`latticevpn.ai/privacy`) links + clearer renewal copy.
- Also (user UX request): the Pro rows no longer show a default green outline;
  the green highlight now appears only on the plan the user taps
  (`selectedProductID`).
- Bumped 105 → **106**, archived, placed in Organizer, installed on device.
- App Store Connect metadata to set: Privacy Policy URL + Terms (EULA) in the
  app description. Review-notes verbiage covering all 3 items was provided
  (cite 3.1.3(b) for the account sign-in = multiplatform sign-in, IAP is the
  in-app purchase path).

**WATCH on next iOS rejection:** make sure Build 106 is the **attached** build
and the **four subscriptions are included in the submission** (the 2.1b trap).

### Incident: iOS Xcode project was deleted (recovered)
`clients/ios/CloakVPN.xcodeproj` (+ some `clients/android/play-assets`) were
**deleted from disk but uncommitted** (stray event; `build_cowork.log`
present). Recovered with `git restore clients/ios/CloakVPN.xcodeproj` and
`git restore clients/android/play-assets/` — both fully back. If the project
vanishes again, the files are in git HEAD; just `git restore`.

## Google Play — VpnService declaration rejection
"Missing or Incomplete Declaration." The Play Console **VPN service**
declaration form was insufficient. Root cause: the **Video instructions**
field had the marketing URL (`https://latticevpn.ai`) instead of a real demo
video. The other answers were correct (General VPN service = Yes, Data
collection = No, Monetization = No).
Fix (user): recorded a ≤90s screen capture showing the app opening, Connect →
**VPN key icon in the status bar** → traffic, uploaded to YouTube unlisted,
pasted that URL into Video instructions, resubmitted. **No code/build change.**

## Still open (carried)
- **PQC re-provision loop** (iOS recovery re-provisions ~15s on region switch
  → rosenpass churn). See `SESSION_HANDOVER_2026-05-29_...pqc-reprovision-loop`.
- **Android v1.0.1 16 KB page fix** (versionCode=3).
- **iOS account-number recovery via iCloud Keychain** (so IAP restore works
  across reinstalls — see 06-01 handover).

## Reference
- Commits this session: `69fd2ce` (paywall legal links + selected-plan green,
  build 106). Plus the project/play-assets `git restore` (no commit needed —
  restored working tree to match HEAD).
- iOS in-review build = **106**; bundle `ai.cloakvpn.CloakVPN`; App ID
  `6764261045`; team `5HYY2YP2G9`.
- IAP setup + review reply: `docs/IAP_SETUP.md`. StoreKit test config:
  `clients/ios/CloakVPN/Lattice.storekit` (set scheme StoreKit Config → None
  for production builds).
- Server `cloakvpn-api` (with `/v1/iap`) on `5.78.203.171`; backup
  `cloakvpn-api.bak-20260601`.
