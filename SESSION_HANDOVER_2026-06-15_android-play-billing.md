# Session Handover — 2026-06-15 — Android Google Play Billing (in-app subscriptions)

Follows `SESSION_HANDOVER_2026-06-11b_android-v101-16kb-and-licenses.md`.

## Headline

Built **Google Play Billing (in-app subscriptions)** for Android end-to-end —
client + server — mirroring the iOS StoreKit IAP. Decision (confirmed with
Danger): **dual billing** (keep web/Stripe + add in-app) and **mint an account
number** on purchase (no Play-account-bound entitlement). The Go server
**compiles, vets, and is gofmt-clean** (verified in-sandbox with go1.25). The
Android side is written but **not yet compiled** (no Android SDK in the
sandbox) — needs a Gradle build on the Mac.

Nothing is deployed or committed yet. The feature is **fully gated off** on the
server until `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` is set, so deploying the new
binary alone is a no-op for the live iOS/Stripe flow.

## Why this was done

Danger asked "why can't users purchase a subscription for the Android app?"
The answer was that they *can* (web → Stripe → account number → enter in app),
but it's web-only and low-discoverability. He chose to add in-app purchase to
remove the web round-trip.

## What was built

### Server (`server/api/`) — COMPILES ✅
- `internal/store/store.go`: added `Account.GooglePlayPurchaseToken`,
  **Migration 4** (`google_play_purchase_token` column + index, self-applying
  on boot), updated `accountCols`/`scanAccount`, and methods
  `AccountByGooglePlayToken`, `CreateAccountGooglePlay`,
  `UpdateSubscriptionByGooglePlayToken`, `RelinkGooglePlayToken`,
  `UpdateAccountHashByGooglePlayToken`, `DeactivateByGooglePlayToken`.
- `internal/googleplay/verify.go` (NEW): Developer API client. Service-account
  **JWT→OAuth2** (RS256, stdlib only — no `google.golang.org/api`, keeps deps
  minimal like `appleiap`), `purchases.subscriptionsv2.get`, `acknowledge`, and
  RTDN Pub/Sub envelope + `DeveloperNotification` decode.
- `internal/googleplay/handler.go` (NEW): `POST /v1/googleplay` (verify token
  → map product→tier → mint/extend account, returns account number; ack after)
  and `POST /v1/googleplay/notifications` (RTDN; re-queries the API, never
  trusts the notification type alone; optional `?token=` shared-secret gate).
- `main.go`: env + route wiring, **feature-gated** on
  `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`. New env: `GOOGLE_PLAY_PACKAGE_NAME`
  (default `ai.latticevpn.android`), `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`,
  `GOOGLE_PLAY_PRODUCT_*` (default `basic`/`pro`),
  `GOOGLE_PLAY_NOTIFICATION_SECRET`.

### Android (`clients/android/`) — written, NOT yet compiled ⚠️
- `app/build.gradle.kts`: added `com.android.billingclient:billing-ktx:7.1.1`.
- `billing/BillingManager.kt` (NEW): Play Billing client — connect, query the
  `basic`/`pro` subscription products + `monthly`/`yearly` base plans, launch
  purchase, handle `PurchasesUpdatedListener`, `restorePurchases()`. Delivers
  the purchase token to a callback. Does **not** acknowledge client-side (server
  does it).
- `data/GooglePlayIapClient.kt` (NEW): `POST /v1/googleplay`, returns
  `IapResult(accountNumber, tier, activeUntil)`.
- `ui/screens/PaywallScreen.kt` (NEW): in-app paywall, monthly/yearly toggle,
  Basic/Pro cards, Subscribe buttons, Restore purchases, "Or subscribe on the
  web", Terms/Privacy. Auto sign-in on success.
- `ui/LatticeViewModel.kt`: added `Screen.PAYWALL`, billing manager + IAP client,
  `plans`/`billingReady`/`billingError`/`purchaseBusy`/`purchaseError` flows,
  `startBilling`/`launchPurchase`/`restorePurchases`, `onPlayPurchase` (verify →
  store number → go Home → warm up keys), `onCleared` disposes billing.
- `ui/LatticeApp.kt`: routes `Screen.PAYWALL → PaywallScreen`.
- `ui/screens/SignInScreen.kt`: "Subscribe at latticevpn.ai" → **"See plans"**
  (opens the in-app paywall). Recover link unchanged.

### Docs
- `docs/GOOGLE_PLAY_BILLING_SETUP.md` (NEW): the full operator checklist —
  Play Console products, GCP service account + Developer API, Pub/Sub RTDN, env
  vars, build, and license-tester testing. **This is the to-do list for Danger.**

## NEXT STEPS (in order)

1. **Build the Android app on the Mac** (`./gradlew :app:assembleRelease` or via
   Android Studio). I could not compile Kotlin in the sandbox — watch for any
   Billing Library 7.1.1 API mismatches (the callback shapes were written for
   v7, which returns `List<ProductDetails>`; **v8 changed this** to
   `QueryProductDetailsResult`, so if you bump to v8 the `queryProductDetailsAsync`
   lambda must change).
2. **Play Console + GCP setup** — follow `docs/GOOGLE_PLAY_BILLING_SETUP.md`:
   create `basic`/`pro` subscriptions, service account + Developer API access,
   Pub/Sub RTDN topic/subscription.
3. **Deploy the server** with the new env (the binary is safe to deploy now;
   stays disabled until the key path is set). Backups: prior live binaries are
   `cloakvpn-api.bak-*` on `5.78.203.171`.
4. **Test with license testers** (no real charges), verify mint + restore +
   cancel/RTDN.
5. **Commit + push.** Reminder: the sandbox can't push git or reach servers —
   run on the Mac, and `rm -f .git/*.lock` first if a stale lock blocks it.

## Open / carried (unchanged)
- iOS PQC re-provision loop (recovery re-provisions on region switch).
- Android v1.0.1 16 KB page fix (versionCode=3) — widens device support.
- iOS account recovery via iCloud Keychain (IAP restore across reinstalls).
- Android open-source acknowledgements: already present (`LicensesScreen.kt`).

## Reference
- Module: `github.com/cloakvpn/api`, Go 1.25. Android `applicationId`
  `ai.latticevpn.android`, billing lib 7.1.1, minSdk 26 / targetSdk 35.
- Play product IDs (must match server `GOOGLE_PLAY_PRODUCT_*` + `BillingManager`
  constants): subscriptions `basic`, `pro`; base plans `monthly`, `yearly`.
- New endpoints: `POST /v1/googleplay`, `POST /v1/googleplay/notifications`.
- Server build verified: `go build ./...`, `go vet`, `gofmt -l` all clean.
