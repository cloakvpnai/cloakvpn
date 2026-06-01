# In-App Purchase (StoreKit) setup — Lattice VPN iOS

Fixes App Store rejection **Guideline 3.1.1** (Build 103) by selling the VPN
subscription via In-App Purchase instead of a web-only / account-number unlock.

## How it works (architecture)

1. User taps **"See plans"** on the account-entry screen → `PaywallView`.
2. StoreKit purchase produces a signed transaction (JWS).
3. App POSTs the JWS to **`POST /v1/iap`** (`StoreManager` → `IAPClient`).
4. Server (`internal/appleiap`) verifies the JWS against the embedded **Apple
   Root CA - G3**, maps the product to a tier, and **mints/extends an account
   number** (`accounts.apple_original_txn_id`), returning it.
5. App feeds that number into the existing `TunnelManager.signIn` path — the
   VPN layer is unchanged. The number is the single credential, as before.
6. Renewals/cancellations/refunds arrive at **`POST /v1/iap/notifications`**
   (App Store Server Notifications V2) and keep `tier` / `active_until` in sync.

No App Store Server API key is required — verification is done locally from
Apple's signature chain.

## App Store Connect — products to create

Create ONE **Subscription Group** (e.g. "Lattice VPN"). Inside it, four
**auto-renewable subscriptions** with these EXACT product IDs (they must match
`StoreManager.productIDs` and the server's `APPLE_PRODUCT_*` env / defaults):

| Product ID | Tier | Duration | Price | Group level |
|------------|------|----------|-------|-------------|
| `ai.cloakvpn.CloakVPN.basic.monthly` | Basic | 1 month | $4.99 | Basic (lower) |
| `ai.cloakvpn.CloakVPN.basic.yearly`  | Basic | 1 year  | $49.99 | Basic (lower) |
| `ai.cloakvpn.CloakVPN.pro.monthly`   | Pro   | 1 month | $9.99 | Pro (higher) |
| `ai.cloakvpn.CloakVPN.pro.yearly`    | Pro   | 1 year  | $99.99 | Pro (higher) |

- Set **Pro** to a higher subscription level than **Basic** so upgrades/
  downgrades behave. Monthly + yearly of the same tier share that tier's level.
- Add a localized display name + description for each (shown on the paywall via
  `product.displayName` / `product.description`).
- Add the subscription-group localization + a review screenshot of the paywall.
- **Submit the IAPs for review together with the app build** (an app's first
  IAPs are reviewed alongside the binary).

## App Store Server Notifications V2

App Store Connect → your app → **App Information → App Store Server
Notifications**. Set the **Production** and **Sandbox** URLs to:

```
https://api.latticevpn.ai/v1/iap/notifications
```

Version **V2**. (This keeps expiry/cancellation in sync without polling.)

## Server config

The binary already ships safe defaults (the product IDs above and bundle
`ai.cloakvpn.CloakVPN`). Override via env only if product IDs change:
`APPLE_BUNDLE_ID`, `APPLE_PRODUCT_BASIC_MONTHLY`, `APPLE_PRODUCT_BASIC_YEARLY`,
`APPLE_PRODUCT_PRO_MONTHLY`, `APPLE_PRODUCT_PRO_YEARLY`. Deploy the rebuilt
`cloakvpn-api` to the box running it (us-west-1 / `5.78.203.171`).

## Testing (before submitting)

1. **StoreKit config (simulator/dev):** in Xcode add a `.storekit`
   configuration with the four products (or sync from App Store Connect), set
   it on the CloakVPN scheme (Run → Options → StoreKit Configuration). Lets you
   exercise the paywall without sandbox.
2. **Sandbox (real signature path):** create a Sandbox Apple Account in App
   Store Connect → Users and Access → Sandbox. Sign into it on the device
   (Settings → Developer → Sandbox Apple Account), run a TestFlight/dev build,
   buy a plan, confirm: paywall lists 4 products → purchase → account number
   minted → VPN connects. Watch `journalctl -u cloakvpn-api` on `5.78.203.171`
   for the `iap: minted account` line.
3. Test **Restore Purchases** on a second install (should re-issue a number).

## Account-number recovery note

The minted number should be saved to the iCloud Keychain (synchronizable) so a
reinstall/second Apple device recovers it. If absent, **Restore Purchases**
calls `/v1/iap` with `restore=true` and the server re-issues a fresh number for
the same subscription (the previous number stops working). Confirm the sign-in
path writes to the synchronizable keychain; otherwise add that.

---

## Reply to App Review (paste into Resolution Center)

> Thank you for the review. We have addressed Guideline 3.1.1.
>
> The app now offers the subscription through In-App Purchase using StoreKit.
> A new in-app paywall ("See plans") lets the customer purchase Lattice VPN
> Basic or Pro (monthly or yearly) directly via In-App Purchase. We have
> removed the prior external "Subscribe at latticevpn.ai" call to action from
> the app.
>
> Access to the VPN is granted by these In-App Purchases. Customers who already
> subscribed on another platform may still sign in with their existing account,
> and the same plans are now available for purchase in the app via In-App
> Purchase, consistent with guideline 3.1.3(b).
>
> The In-App Purchase products have been submitted for review with this build.
> To test: open the app, tap "See plans," and purchase any plan with the
> sandbox account; the app then connects to the VPN.
