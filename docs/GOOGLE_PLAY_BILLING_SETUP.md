# Google Play Billing — setup & operations

In-app subscriptions for the Android app, verified server-side and reconciled
with the no-account account-number model (the same model Stripe and the iOS
IAP use). This doc is the checklist for the parts that **only you** can do in
the Play Console and Google Cloud — the code is already written and wired.

## How it works (the flow)

1. The app (`PaywallScreen`) loads the two subscription products from Google
   Play via the Play Billing Library and shows Basic/Pro × monthly/yearly.
2. The user taps Subscribe → Google's purchase sheet → on success the Billing
   Library hands the app an opaque **purchase token**.
3. The app POSTs the token to `POST /v1/googleplay`. The server calls the
   **Google Play Developer API** (`purchases.subscriptionsv2`) to verify it,
   reads the product + expiry + state, then **mints an account number** keyed
   by the purchase token and returns it. The app stores it and the user is
   signed in — they never type anything.
4. The server **acknowledges** the purchase (required within 3 days, else
   Google auto-refunds).
5. Renewals, cancellations, refunds, grace/hold are delivered by **Real-time
   Developer Notifications (RTDN)** over Pub/Sub to
   `POST /v1/googleplay/notifications`. The server re-queries the Developer API
   (never trusts the notification blindly) and updates tier/expiry/active state.

Web (Stripe) checkout at latticevpn.ai still works — this is **dual billing**.
Google's cut (15–30%) applies only to in-app purchases.

---

## Checklist

### 1. Create the subscription products (Play Console)

Play Console → your app → **Monetize → Products → Subscriptions**.

Create **two** subscriptions (the server's defaults expect these exact IDs):

| Subscription (product) ID | Base plan IDs        | Prices (match the website)                 |
|---------------------------|----------------------|--------------------------------------------|
| `basic`                   | `monthly`, `yearly`  | $4.99/mo, $49.99/yr                         |
| `pro`                     | `monthly`, `yearly`  | $9.99/mo, $99.99/yr                         |

For each subscription: add a base plan with ID `monthly` (auto-renewing, 1
month) and another with ID `yearly` (auto-renewing, 1 year). Activate all base
plans. No intro offers are required (the app picks the plain base-plan price).

> The IDs `basic`/`pro` and `monthly`/`yearly` are referenced in two places:
> `BillingManager` (constants `PRODUCT_BASIC`, `PRODUCT_PRO`, `PLAN_MONTHLY`,
> `PLAN_YEARLY`) and the server env (`GOOGLE_PLAY_PRODUCT_*`, default
> `basic`/`pro`). If you choose different IDs, change **both**.

### 2. Service account for the Developer API (Google Cloud + Play Console)

The server authenticates to Google with a service account.

1. **Link a Google Cloud project**: Play Console → **Setup → API access**.
   Either link an existing GCP project or let it create one.
2. In that GCP project, enable the **Google Play Android Developer API**
   (console.cloud.google.com → APIs & Services → Library).
3. Create a **service account** (GCP → IAM & Admin → Service Accounts).
   Create a **JSON key** for it and download it. This is the file the server
   reads.
4. Back in Play Console → **API access**, find the service account in the list
   and **Grant access**. Give it permission to **View financial data, orders,
   and cancellation survey responses** and **View app information** (these
   cover the read + acknowledge calls). Apply to this app.
5. Copy the JSON key to the API server, e.g.
   `/etc/cloakvpn/play-service-account.json`, `chmod 600`, owned by the service
   user. **Never commit it** (it's a credential).

> Permission propagation can take a few minutes to ~24h. If `subscriptionsv2`
> returns 401/403 right after granting, wait and retry.

### 3. Real-time Developer Notifications (Pub/Sub)

1. In the **linked GCP project**, create a **Pub/Sub topic**, e.g.
   `play-rtdn`.
2. Grant Google Play permission to publish to it: add the principal
   `google-play-developer-notifications@system.gserviceaccount.com` as a
   **Pub/Sub Publisher** on the topic.
3. Create a **push subscription** on that topic with the endpoint:
   `https://api.latticevpn.ai/v1/googleplay/notifications?token=<SECRET>`
   where `<SECRET>` matches the server's `GOOGLE_PLAY_NOTIFICATION_SECRET`
   (see env below). The `?token=` query param is a lightweight shared-secret
   gate so only your push reaches the endpoint.
4. Play Console → **Monetize → Monetization setup → Real-time developer
   notifications**: set the **Topic name** to your topic
   (`projects/<gcp-project>/topics/play-rtdn`) and **Send a test
   notification**. You should see `googleplay notification: test ping ok` in
   the server log.

### 4. Server environment variables

Add to the `cloakvpn-api` service environment (e.g. the systemd unit's
`Environment=` / EnvironmentFile). The feature stays **off** until
`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` is set, so deploying the new binary alone
changes nothing.

```
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON=/etc/cloakvpn/play-service-account.json
GOOGLE_PLAY_PACKAGE_NAME=ai.latticevpn.android        # default; override if needed
GOOGLE_PLAY_NOTIFICATION_SECRET=<long-random-string>  # must match the Pub/Sub push URL ?token=
# Product IDs — defaults are "basic"/"pro"; only set these if you used other IDs:
# GOOGLE_PLAY_PRODUCT_BASIC_MONTHLY=basic
# GOOGLE_PLAY_PRODUCT_BASIC_YEARLY=basic
# GOOGLE_PLAY_PRODUCT_PRO_MONTHLY=pro
# GOOGLE_PLAY_PRODUCT_PRO_YEARLY=pro
```

The DB migrates itself on startup (Migration 4 adds
`accounts.google_play_purchase_token`). No manual SQL needed.

On boot you should see either
`google play billing enabled (package ai.latticevpn.android)` or
`google play billing disabled (set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON to enable)`.

### 5. Build & ship the app

- `billing-ktx:7.1.1` is already added to `app/build.gradle.kts`. The
  `com.android.vending.BILLING` permission is merged in by the library — no
  manifest change.
- Bump `versionCode` and build a release App Bundle, upload to a **Closed
  testing** track first.

### 6. Test purchases (no real charges)

1. Play Console → **Setup → License testing**: add the Google accounts that
   will test as license testers (their purchases are test purchases, refunded
   automatically and not charged).
2. Install the build from the testing track on a device signed in with a
   tester account.
3. Sign-in screen → **"Don't have an account? See plans"** → pick a plan →
   purchase. You should land on Home, signed in, with a freshly minted account
   number (check Account screen). Server log: `googleplay: minted account ...`.
4. Test **Restore purchases** after clearing app data: it should re-issue a
   number for the still-owned subscription.
5. Cancel from Google Play and confirm an RTDN arrives and the account
   deactivates at period end.

---

## Endpoints (reference)

- `POST /v1/googleplay` — body `{"purchase_token": "...", "restore": false}`;
  returns `{"account_number": "...", "tier": "basic", "active_until": "..."}`.
  `account_number` is present only when minted/re-issued.
- `POST /v1/googleplay/notifications?token=<secret>` — Pub/Sub push target for
  RTDN. Returns 200 on success so Pub/Sub stops retrying; 5xx (retry) only if
  Google's Developer API is unreachable.

## Files (already implemented)

- `server/api/internal/googleplay/verify.go` — Developer API client (service-
  account JWT→OAuth2, `subscriptionsv2.get`, acknowledge, RTDN decode).
- `server/api/internal/googleplay/handler.go` — `/v1/googleplay` (+notifications).
- `server/api/internal/store/store.go` — `google_play_purchase_token` column,
  Migration 4, and the `*GooglePlayToken` account methods.
- `server/api/main.go` — env + route wiring (feature-gated on the key path).
- `clients/android/.../billing/BillingManager.kt` — Play Billing client.
- `clients/android/.../data/GooglePlayIapClient.kt` — posts the token to the API.
- `clients/android/.../ui/screens/PaywallScreen.kt` — the in-app paywall.
- `LatticeViewModel`, `LatticeApp`, `SignInScreen` — paywall nav + auto sign-in.

## Notes / gotchas

- **Acknowledge or lose the sale**: unacknowledged purchases auto-refund after
  3 days. The server acknowledges on verify; if that ever fails, the next RTDN
  re-query path provides a retry.
- **Plan changes issue a new purchase token** whose `linkedPurchaseToken` names
  the old one. The server re-points the existing account row onto the new token
  (`RelinkGooglePlayToken`) so an upgrade/downgrade stays one account.
- **We never mint from a notification** — only from the app's verify call,
  because a freshly minted number has to be returned to a waiting client. RTDNs
  only refresh/deactivate existing rows.
- **Google's fee** is 15% (first $1M/yr, and most subscription revenue) to 30%.
  Web/Stripe stays fee-free; that's why dual billing is worth keeping.
