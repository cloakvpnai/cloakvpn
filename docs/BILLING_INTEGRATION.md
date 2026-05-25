# Lattice VPN — Billing Integration Spec

**Status:** Draft for review · 2026-05-23
**Goal:** Sell Lattice VPN subscriptions on latticevpn.ai via Stripe,
**with no user accounts** — the customer's only credential is a random
account number.

---

## 1. Summary

Lattice VPN will be sold as an auto-renewing subscription bought on
latticevpn.ai through Stripe. There are **no user accounts** — no email,
no password, no sign-up. Instead, paying generates a random **account
number** that the customer enters into the app. This is the Mullvad /
IVPN model and is itself a privacy selling point.

The backend for this is ~90% built: the Go `cloakvpn-api` service
(`server/api/`) already has the Stripe webhook, a SQLite account/device
store, tier logic, and a `/v1/device` provisioning endpoint. The work is
to (a) switch its identity model from email to account number, (b) wire
it in as the live provisioning path, (c) build the account-number entry
screen in both apps, and (d) build the website checkout + recovery pages.

## 2. Principles

- **No accounts.** The VPN service stores no email, name, or password.
  The account number is the sole credential.
- **No personal data on the VPN side.** Email/identity exists only
  inside Stripe, which is unavoidable for card billing. The VPN service
  never links payment identity to VPN usage.
- **The app is payment-silent.** No prices, no checkout, no "subscribe"
  links inside the app — required by Google Play / App Store policy when
  selling through an external website. Selling happens only on
  latticevpn.ai. The app only ever *consumes* an account number.

## 3. The account-number model

- The **account number** is a random token from a CSPRNG: recommended
  **25 characters of Crockford base-32** (alphabet excludes I, L, O, U;
  ~116 bits of entropy), displayed in five groups of five —
  `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`. Hyphens and letter case are stripped
  before hashing and lookup.
- Server-side, an account row holds: `account_number_hash`,
  `stripe_customer_id`, `tier`, `device_limit`, `active_until`. **No
  email, no name.** Only the *hash* of the number is stored, so a DB
  leak does not hand out working credentials.
- The account number is a **bearer credential**: whoever holds it can
  use the subscription up to the device limit. This is the accepted
  trade-off of the no-account model (same as Mullvad). The device limit
  and rate-limiting bound the abuse.

## 4. End-to-end flow

1. Customer opens latticevpn.ai, picks a plan, clicks Subscribe → a
   Stripe Payment Link.
2. Customer pays on Stripe's hosted page (email collected by Stripe for
   billing + receipts).
3. Stripe fires `checkout.session.completed` → `cloakvpn-api` webhook.
4. The webhook generates a random account number, stores its hash with
   the tier/limit/expiry, and writes the number into the **Stripe
   customer's metadata** (for later recovery).
5. Stripe redirects the customer to `latticevpn.ai/welcome?session_id=…`,
   which displays the account number prominently with a copy/download
   button.
6. Customer opens the Lattice VPN app, enters the account number once.
   The app stores it in secure device storage.
7. Customer picks a region → the app calls `POST /v1/device` with the
   account number → the server checks the subscription is active and
   under the device limit → provisions a WireGuard + Rosenpass peer →
   returns the config → the app connects.
8. Renewal: Stripe auto-charges the card → `customer.subscription.updated`
   → the webhook refreshes `active_until`. The customer does nothing.
9. Cancellation: customer cancels via a Stripe billing-portal link →
   `customer.subscription.deleted` → the webhook deactivates the
   account → the next `POST /v1/device` returns 402.

## 5. Component changes

### 5.1 Stripe

Per `docs/STRIPE_SETUP.docx` (rebrand "Cloak" → "Lattice", `cloakvpn.ai`
→ `latticevpn.ai` throughout):

- Pin the dashboard API version to **2025-03-30** (avoids the
  `current_period_end` Basil bug — see STRIPE_SETUP.docx §1).
- Create 4 Products/Prices: Lattice VPN Basic & Pro, each monthly +
  yearly, as **auto-renewing subscriptions**.
- Create 4 Payment Links — collect customer email, redirect to
  `latticevpn.ai/welcome?session_id={CHECKOUT_SESSION_ID}`.
- Webhook endpoint `https://api.latticevpn.ai/v1/webhook/stripe` —
  events `checkout.session.completed`, `customer.subscription.updated`,
  `customer.subscription.deleted`.
- Enable the Stripe **customer billing portal** (used for cancellation
  and account-number recovery).

### 5.2 cloakvpn-api (Go service) — changes

The service exists; these are the deltas:

- **`internal/store`** — change the identity model from email to
  account number. New schema:
  `accounts(id, account_number_hash UNIQUE, stripe_customer_id, tier,
  device_limit, active_until)`. Drop the `email` column. Keep
  `stripe_customer_id` (the webhook and recovery need it).
- **`internal/stripe/webhook.go`** — on `checkout.session.completed`:
  generate the account number, store its hash, and write the plaintext
  number to the Stripe customer's metadata
  (`stripe.Customer.Metadata["lattice_account_number"]`). Also record
  the checkout `session_id → account` mapping so the `/welcome` page can
  fetch it. `subscription.updated/deleted` stay as-is but key on
  `stripe_customer_id` (already the case).
- **`internal/http`** — `/v1/device` is authenticated by the **account
  number**, sent as `Authorization: Bearer <account-number>`, not a raw
  email. Normalize it (strip hyphens/case), hash it (§8), look up the
  account, check `active_until` + device limit, then provision. Remove
  the email TODO. `/v1/account` is keyed the same way and should return
  the **list** of the account's devices (not just a count) so the app
  can show them. Finish the `revoke` path as `DELETE /v1/device` taking
  a device id, so a customer can free a slot.
- **New `GET /v1/account-number?session_id=…`** — used by the `/welcome`
  page. Returns the account number for a just-completed checkout. The
  webhook may not have landed when the redirect arrives, so the endpoint
  returns `404` until it has; the page polls (~1 s interval, ~20 s cap)
  and then falls back to a "check your Stripe receipt or contact
  support" message.
- **Deploy it.** Today the live provisioning path is the bootstrap-key
  Python `cloak-api-server.py`; `cloakvpn-api` is not deployed. It
  becomes the production path (see §7 for the multi-region question).
- **No transactional email provider is needed** — a nice simplification
  of the earlier design. The VPN side never sends email; Stripe sends
  receipts.

### 5.3 Website (latticevpn.ai)

- **Pricing page** — 4 Subscribe buttons pointing at the Stripe Payment
  Link URLs.
- **`/welcome`** — reads `session_id`, polls `GET /v1/account-number`,
  shows the account number large with copy + "download as .txt" and a
  clear "this is your only key — save it" message.
- **`/recover`** — account-number recovery (see §6).
- The site is `website-v2/` (Astro). These pages can be written in the
  repo; deployment is the team's (Cloudflare Pages).

### 5.4 The apps (Android + iOS)

Both clients need the same new flow; the screen is built per-platform.

- **New first-run screen: "Enter your account number."** A single text
  field. Replaces today's headless bootstrap-key auth. Keep wording
  payment-silent — e.g. "Your account number was shown when you
  subscribed." No price, no tappable purchase link (see §9).
- The account number is stored in secure storage — Android Keystore /
  iOS Keychain.
- After entry: region selection → `POST /v1/device` with the account
  number → config → connect. Identical to today's post-provisioning UX.
- **Inactive subscription (HTTP 402)** → a plain "This account's
  subscription isn't active" screen. Payment-silent.
- **Android** — rework `data/AuthClient.kt` and `data/ProvisioningClient.kt`
  to target `cloakvpn-api` with the account number; add the Compose
  entry screen.
- **iOS** — the parallel changes in the `clients/ios/` auth + provisioning
  layer and a SwiftUI entry screen.

## 6. Account-number recovery

The customer's email lives only at Stripe. Recovery uses Stripe as the
channel so the VPN backend stays email-free:

- The account number is stored in the **Stripe customer metadata** (§5.2).
- **`/recover`** on the website takes the email the customer paid with,
  finds the matching Stripe customer (Stripe customer-search API), opens
  a **Stripe billing-portal session** (Stripe authenticates them by
  emailing their own secure login link), and then shows the account
  number from that customer's metadata.
- Mitigations that make loss rare / non-critical: the `/welcome` page
  pushes saving the number; and because the subscription auto-renews, a
  lost number only blocks *adding a new device* — already-connected
  devices keep working.
- *Optional future addition:* let customers opt in to storing an email
  purely for recovery. Still "no account required"; not needed for v1.

## 7. Architecture decision — multi-region topology  (CONFIRMED — built)

> **Status:** confirmed and implemented. The central API is region-aware
> (`internal/regions`, `regionsvc`); ten regions are registered. See
> `docs/DEPLOY_MULTIREGION.md` for the rollout runbook. The text below is
> the original decision, kept for context.

There are 10 concentrators (us-west-1, us-east-1, us-central-1, de1, fi1,
es1, mx1, za1, in1, jp1).
`cloakvpn-api`'s `wg.Controller` provisions on the box it runs on, but
accounts must work across all regions.

**Recommended:** one **central `cloakvpn-api`** at `api.latticevpn.ai`
owns accounts + billing + the database and is the only API the apps
talk to. Each concentrator runs a small **provisioning endpoint** (the
existing per-region service, re-secured with an internal shared secret
instead of the bootstrap key). On `POST /v1/device`, the central api
verifies the subscription, calls the chosen region's provisioning
endpoint over an authenticated internal channel, records the returned
device, and hands the config back to the app.

This keeps accounts central, provisioning regional, reuses code that
already exists, and means the app only ever talks to one host.

Only the cross-region *provisioning call* depends on this decision — the
store schema, webhook, account-number generation, and the auth endpoints
in §5.2 can all be built in parallel while it is being settled.

## 8. Security

- Account number: high entropy; stored only as
  **HMAC-SHA256(server-secret, normalized account number)** so a DB leak
  yields no usable credentials. Provisioning, account lookup, and
  recovery endpoints are **rate-limited** (e.g. ~10 requests per IP per
  minute) to prevent brute-forcing the number space.
- The device limit caps abuse of a leaked number.
- Stripe webhook secret, the account-number hashing secret, and the
  internal region-provisioning secret all live in server-side env
  (`0600`), never in the repo.
- No new personal data on the VPN side — the model is *more* private
  than today (no per-install identifier needed either).
- `clients/android/privacy-policy.md` should be updated to describe the
  account-number model once this ships.

## 9. Google Play / App Store policy

Selling on the website rather than via in-app purchase is deliberate: it
avoids the 15–30% store commission, and — decisively — in-app purchase
would tie every customer to a Google or Apple account, which defeats the
no-account privacy model. The cost is that store policy then constrains
what the app may show:

- The app must stay **payment-silent**: no prices, no checkout, no
  tappable links to the Stripe checkout. It only accepts an account
  number. This is the compliant pattern for selling via an external
  website (see `clients/android/PLAY_STORE.md` → "Monetization &
  billing").
- The store *listing* may mention latticevpn.ai; the *app UI* should
  not steer users to buy. Keep on-screen wording neutral and finalize
  it against current policy before submission.

## 10. What this retires

- The headless bootstrap-key auth in both apps and the Python
  `cloak-api-server.py` provisioning path go away for production (keep
  for internal/dev testing if useful). Because the apps are not yet on
  the stores, there are no live users to migrate — a clean cutover.

## 11. Phased implementation plan

1. **Stripe setup** — products, payment links, webhook, API-version pin
   (test mode). Low risk, no code.
2. **cloakvpn-api** — store schema, webhook account-number generation +
   Stripe metadata write, `/v1/device` + `/v1/account` auth, new
   `/v1/account-number`, finish `revoke`. Decide §7 first.
3. **Website** — pricing buttons, `/welcome`, `/recover`.
4. **Apps** — account-number entry screen + provisioning rewire;
   Android first, then iOS.
5. **End-to-end test** in Stripe test mode (Stripe CLI), then flip to
   live and do a real-card purchase before announcing.

## 12. Open items

- ~~Confirm the multi-region topology in §7.~~ Done — see
  `docs/DEPLOY_MULTIREGION.md`.
- Confirm the recommended account-number format in §3.
- Exact payment-silent wording for the app's account-number screen.
- Whether to also offer crypto/cash payment later (`docs/PRICING.md`
  already plans BTCPay / Monero) — out of scope for this spec.
