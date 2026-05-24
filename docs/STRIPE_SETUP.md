# Stripe setup — from zero to taking payments

End-to-end walk-through for wiring Stripe into **Lattice VPN**. Assumes
you have a Stripe account in test mode. Follow in order; ~45 minutes.

This is **Phase 1** of the rollout in
[`BILLING_INTEGRATION.md`](BILLING_INTEGRATION.md) — the no-account
model: paying generates a random **account number**, not a user
account. Steps 1–4 here are Stripe Dashboard actions only you can do.
Paired with `server/api/internal/stripe/webhook.go`.

Do everything in Stripe **Test mode** until step 7.

---

## 0. Why Payment Links instead of a custom checkout

For the ~150-subscriber / $1k-MRR target we're optimising for, Stripe
Payment Links are the fastest path to revenue: zero frontend code,
Stripe-hosted checkout page, works with the existing webhook handler
out of the box. Every event a custom `Checkout Session` would emit
(`checkout.session.completed`, `customer.subscription.updated`,
`customer.subscription.deleted`) is also emitted by Payment Links —
they're the same code path server-side.

If you later outgrow Payment Links (e.g. you want coupon codes, referral
credits, or custom checkout UI) the migration path is: add a
`POST /v1/checkout` endpoint that creates a `stripe.CheckoutSession` and
returns its URL. The webhook handler doesn't change.

---

## 1. API version — nothing to do on a new account

Older Stripe accounts could be pinned to a specific API version. A newly
created account is already on a current version, and Stripe does **not**
let you downgrade it — so there is nothing to change here. **Skip to
step 2.**

Background: Stripe's "Basil" version (`2025-03-31`+) moved
`current_period_end` off the `Subscription` object. The webhook handler
already copes — `itemPeriodEnd` in
`server/api/internal/stripe/webhook.go` reads the field from its new
location, with a 35-day grace fallback — so renewals are handled
correctly whatever version your account is on.

For reference, the API version now lives in **Developers → Workbench →
Overview tab → "API versions"** (it is no longer a row on the Developers
settings page). You don't need to open it.

---

## 2. Create the four products

Create one Stripe **Product** per pricing tier, with two recurring
**Prices** each (monthly + yearly).

Dashboard → **Product catalog** → **Create product**. Repeat four times:

| Product name        | Price  | Interval | Notes                          |
|---------------------|--------|----------|--------------------------------|
| Lattice VPN Basic   | $4.99  | Monthly  | 3 devices, EU+US core          |
| Lattice VPN Basic   | $49.99 | Yearly   | Same as above, yearly billing  |
| Lattice VPN Pro     | $9.99  | Monthly  | 10 devices, all locations      |
| Lattice VPN Pro     | $99.99 | Yearly   | Same, yearly billing           |

(Matches `docs/PRICING.md`. AI Shield is currently deferred per the
revenue-focused roadmap.)

**After each price is created, copy its `price_...` ID.** You'll need
all four in step 5.

---

## 3. Generate Payment Links

For each of the 4 prices:

1. Open the price in the dashboard
2. Click **Create payment link**
3. Under **Options**:
   - **Collect customer email** → **Yes** (required — Stripe needs it
     for billing, receipts, and account-number recovery; the VPN
     service itself never stores it)
   - **Allow promotion codes** → optional
   - **Confirmation behaviour** → "Don't show a confirmation page,
     redirect to: `https://latticevpn.ai/welcome?session_id={CHECKOUT_SESSION_ID}`"
     (`{CHECKOUT_SESSION_ID}` is a literal Stripe placeholder — paste it
     exactly. The `/welcome` page is built in Phase 3.)
4. Click **Create link** → copy the `https://buy.stripe.com/...` URL
5. These URLs go on the `latticevpn.ai` Subscribe buttons (Phase 3)

---

## 4. Enable the customer billing portal

Dashboard → **Settings** → **Billing** → **Customer portal** → activate
it and allow customers to cancel their subscription. This powers both
cancellation and account-number recovery
(`BILLING_INTEGRATION.md` §6) — without it, customers have no
self-service path.

---

## 5. Create the webhook endpoint

The webhook must reach `cloakvpn-api`, which isn't deployed until
Phase 2. So:

- **During Phase 2 development**, skip the dashboard endpoint and use
  the **Stripe CLI** (see step 6) — it forwards events to a local
  process and prints its own signing secret.
- **Create the real endpoint** once `api.latticevpn.ai` is live:
  Dashboard → **Developers** → **Webhooks** → **Add endpoint**:
  - **Endpoint URL:** `https://api.latticevpn.ai/v1/webhook/stripe`
    (until the `api.` DNS is wired you can point it at an `ngrok`
    tunnel on the server box — `ngrok http 8080`)
  - **API version:** "default" (now `2025-03-30` after step 1)
  - **Events to send** — exactly these three:
    - `checkout.session.completed`
    - `customer.subscription.updated`
    - `customer.subscription.deleted`
  - Click **Add endpoint** → copy the **Signing secret** (`whsec_...`).

---

## 6. Configure environment variables

The API process (`cloakvpn-api`) reads these from env — server-side,
file mode `0600`, never committed. The host topology (one central API
vs. per-region) is decided in `BILLING_INTEGRATION.md` §7.

```ini
# api.env — owned by root, chmod 600
LISTEN_ADDR=127.0.0.1:8080
DB_PATH=/var/lib/cloakvpn/cloakvpn.db

STRIPE_WEBHOOK_SECRET=whsec_...                    # from step 5
STRIPE_PRICE_BASIC_MONTH=price_...                 # from step 2
STRIPE_PRICE_BASIC_YEAR=price_...
STRIPE_PRICE_PRO_MONTH=price_...
STRIPE_PRICE_PRO_YEAR=price_...

WG_IFACE=wg0
WG_SERVER_PUB=$(cat /etc/wireguard/server.pub)     # expand at install time
WG_ENDPOINT=<region endpoint>:51820
WG_DNS=10.99.0.1
WG_ALLOWED_IPS=0.0.0.0/0, ::/0
WG_SUBNET=10.99.0.0/24
```

**Security note:** the webhook secret is the difference between "my API
is secure" and "anyone can mint active subscriptions." Keep the file
`0600` and root-owned.

---

## 7. Test the flow end-to-end with Stripe CLI

Before pointing a real Payment Link at the live endpoint, dry-run it.

```bash
# Install if you don't have it
brew install stripe/stripe-cli/stripe

# Login
stripe login

# Forward events to the running API (locally or via ssh tunnel)
stripe listen --forward-to http://localhost:8080/v1/webhook/stripe

# In another terminal, trigger a fake event
stripe trigger checkout.session.completed
```

You should see the forwarded event hit your API and log `POST
/v1/webhook/stripe 200 OK`. If you see signature-verify failures, the
`STRIPE_WEBHOOK_SECRET` env isn't being picked up — `stripe listen`
prints its own test secret, *different* from the dashboard one. Set
`STRIPE_WEBHOOK_SECRET` to the `whsec_...` the CLI prints on startup.

---

## 8. Go live

1. Flip the dashboard from **Test mode** to **Live mode** only when
   you're ready to take real money
2. Re-do steps 2, 3, 5 in live mode — products, payment links, and
   webhook endpoints are scoped per-mode
3. Update the live `api.env` with the live `whsec_...` and live
   `price_...` IDs (prefixed `price_1Live...` vs `price_1Test...`)
4. Restart `cloakvpn-api`
5. Buy a subscription yourself with a real card to prove the full path
   works before telling anyone it's open

---

## 9. What happens when someone subscribes

The no-account flow (full detail in `BILLING_INTEGRATION.md` §4):

1. User clicks "Subscribe" on `latticevpn.ai` → redirected to
   `https://buy.stripe.com/...`
2. User enters email + card on Stripe's page, pays
3. Stripe sends `checkout.session.completed` → our webhook
4. The webhook generates a random **account number**, stores its hash
   with `tier` / `device_limit` / `active_until`, and writes the number
   into the Stripe customer's metadata (for later recovery)
5. User is redirected to `latticevpn.ai/welcome?session_id=cs_...`,
   which displays the **account number** prominently — "save this, it's
   your only key"
6. User opens the Lattice VPN app and enters the account number once.
   The app calls `POST /v1/device` with it → the server checks the
   subscription is active → provisions a WireGuard + Rosenpass peer →
   returns the config → the app connects
7. Renewal: Stripe charges the card → `customer.subscription.updated` →
   webhook refreshes `active_until` to the new period end + 3 days grace
8. Cancellation: Stripe emits `customer.subscription.deleted` → webhook
   deactivates the account → the next `POST /v1/device` returns 402

No email, password, or user account is ever created on the VPN side —
the account number is the only credential.

---

## 10. Troubleshooting

- **Webhook retries:** Stripe retries 4xx/5xx responses for up to 3
  days. Debugging locally, check Dashboard → Developers → Webhooks →
  your endpoint → Event deliveries for the raw payload of failed events.
- **Yearly subscribers expire at 35 days:** the webhook's period-end
  fallback (`itemPeriodEnd` in `webhook.go`) isn't resolving the renewal
  date — check the `cloakvpn-api` logs for the "no period_end in event"
  warning. Restore affected customers meanwhile with `UPDATE accounts
  SET active_until = datetime('now', '+400 days') WHERE
  stripe_customer_id = 'cus_...';`.
- **New checkout emits `checkout.session.completed` but no account is
  created:** the `price_...` in the event doesn't match any of the 4
  env vars. Check the log for `"checkout completed for unknown price
  %q"` and reconcile.
