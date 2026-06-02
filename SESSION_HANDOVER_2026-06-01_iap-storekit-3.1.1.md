# Session Handover — 2026-06-01 — In-App Purchase (StoreKit) for Guideline 3.1.1

Follows `SESSION_HANDOVER_2026-05-29_ios-appstore-submit-and-pqc-reprovision-loop.md`.
This session: Build 103 came back **rejected under Guideline 3.1.1** (paid
content must use In-App Purchase, not a web-only / account-number unlock).
We implemented full StoreKit IAP end-to-end, created the products in App
Store Connect, and built/uploaded **Build 105**. Submission to review is the
last user step.

---

## TL;DR — where things stand

| Area | Status |
|------|--------|
| iOS Build 103 (1.0) | **REJECTED — Guideline 3.1.1** (no IAP). Superseded by Build 105. |
| In-App Purchase (StoreKit) | **BUILT end-to-end + deployed.** Server verify/mint live; iOS paywall in Build 105 (uploaded). |
| App Store Connect IAP products | **4 created, all "Ready to Submit"** (Basic/Pro × monthly/yearly). |
| Build 105 | **UPLOADED** to App Store Connect (IAP paywall + external CTA removed). |
| Final submit (Build 105 + 4 subs → 1.0 version → Submit for Review) | **PENDING — user action.** Review notes ready (below). |
| PQC re-provision loop (from prior handover) | **STILL OPEN** — client recovery loop. |
| Android v1.0.1 16 KB page fix | **STILL OPEN** — from earlier handover. |

---

## What was accomplished

### 1. Guideline 3.1.1 rejection (Build 103)
Apple rejected the web-only/Stripe + account-number-unlock model: paid
digital content used in-app must be sold via In-App Purchase (US storefront
external-link path also exists but commission is in legal flux — chose IAP
for reliability/global). Decision: **add StoreKit IAP**, mint/extend the
existing account number server-side so the whole backend is unchanged.

### 2. Server — `internal/appleiap` (verify + mint), deployed
- `verify.go`: verifies Apple's signed StoreKit transactions + App Store
  Server Notifications V2 JWS by validating the **x5c chain to the embedded
  Apple Root CA - G3** (`AppleRootCA-G3.pem`, vendored from the Mac keychain)
  and the ES256 signature. No App Store Server API key needed.
- `handler.go`: `POST /v1/iap` (verify → map product→tier → mint or extend an
  account number keyed by `originalTransactionId` → return number) and
  `POST /v1/iap/notifications` (DID_RENEW/EXPIRED/REFUND → keep tier/expiry
  in sync).
- `store.go`: migration 3 adds `accounts.apple_original_txn_id` + index;
  `CreateAccountApple` / `AccountByAppleTxn` / `UpdateSubscriptionByAppleTxn`
  / `UpdateAccountHashByAppleTxn` / `DeactivateByAppleTxn`.
- `main.go`: routes wired; product IDs + bundle from env with **safe
  defaults** (no new required env).
- **Deployed** to `5.78.203.171` (cloak-us-west-1, runs cloakvpn-api).
  Backup: `/usr/local/bin/cloakvpn-api.bak-20260601`. Verified `/v1/iap`
  returns 400 on empty body through `https://api.latticevpn.ai` (route live).
  Rollback = restore .bak + `systemctl restart cloakvpn-api`.

### 3. iOS — StoreKit 2 client + paywall (Build 105)
- `StoreManager.swift`: load products, purchase, `Transaction.updates`,
  restore; posts the signed JWS to `/v1/iap`, gets the account number, feeds
  it into the existing `TunnelManager.signIn` path.
- `PaywallView.swift`: in-app paywall (the four plans), presented from
  AccountEntryView via a new "See plans" button.
- **Removed** the external "Subscribe at latticevpn.ai" CTA (the exact thing
  3.1.1 flagged).
- `Lattice.storekit`: local StoreKit config (4 products) for simulator/dev
  testing. **Set scheme StoreKit Configuration back to None for production.**
- Build bumped 104 → **105**, archived, **uploaded** to App Store Connect.
- "See plans" only shows on the signed-out account-entry screen.

### 4. App Store Connect
- Subscription group **Lattice VPN** (group ID 22127574). Four
  auto-renewable subs, all **"Ready to Submit"**:
  - `ai.cloakvpn.CloakVPN.basic.monthly` $4.99 / `.basic.yearly` $49.99
  - `ai.cloakvpn.CloakVPN.pro.monthly` $9.99 / `.pro.yearly` $99.99
  - (Product IDs keep the legacy `cloak` namespace — internal only, never
    user-visible; must match `StoreManager.productIDs` + server config.)
- Levels: Pro above Basic. Server Notifications V2 URL →
  `https://api.latticevpn.ai/v1/iap/notifications`.
- Each product: price + availability (all countries) + localization +
  **review screenshot** (`appstore-assets/Lattice-paywall-screenshot.png`,
  1242×2688). "Missing Metadata" gotchas were: per-product screenshot,
  **Availability**, and **price** — all must be set per product.

### Gotchas this session (so they aren't re-hit)
- IAP **promo Image** (1024×1024, 72 dpi, RGB, flattened) ≠ Review
  **Screenshot** (a real phone-shaped device screenshot, ≥640×920, must be a
  valid device size — 1024² and cropped sizes are rejected as "dimensions
  wrong"). See `appstore-assets/`.
- "Missing Metadata" = a per-product required field is blank/unsaved
  (price, **availability**, localization, screenshot). Set them per product.
- The first subscription must be submitted **with the app version** (attach
  on the 1.0 version page).

---

## LAST STEP (user, in App Store Connect)
1. 1.0 version page → **In-App Purchases and Subscriptions** → add all four.
2. Attach **Build 105** to the version.
3. **App Review Information → Notes**: paste the text in
   `docs/IAP_SETUP.md` (3.1.1 fix + how to test paywall + account number
   `KPNX3-WBPVH-E6JTK-583EH-SJG1K`).
4. **Submit for Review.**

## Account-number recovery caveat (revisit)
First purchase mints a number and returns it to the app once. The app should
store it in the **iCloud Keychain (synchronizable)** so reinstall/2nd device
recovers it; otherwise **Restore Purchases** re-issues a fresh number
(`restore=true` → server re-mints, old number stops working). Confirm the
sign-in path writes to the synchronizable keychain.

## Still open (carried)
- **PQC re-provision loop** (iOS recovery re-provisions ~every 15s on region
  switch → rosenpass churn). See prior handover's "Next task."
- **Android v1.0.1 16 KB page fix** (versionCode=3).
- **Play reviewer credentials** — account number in Play App access form.

## Reference
- Commits this session: `fef613e` (IAP server+client), `7f18b96` (build 105
  bump), `8805f2e` (storekit config + appstore assets). All pushed.
- IAP setup + review reply: `docs/IAP_SETUP.md`.
- iOS: team `5HYY2YP2G9`, bundle `ai.cloakvpn.CloakVPN`, App ID `6764261045`,
  in-review build = 105.
- Central API: `https://api.latticevpn.ai` → `5.78.203.171`.
