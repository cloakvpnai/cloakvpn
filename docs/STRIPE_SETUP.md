# Stripe setup — from zero to taking payments

End-to-end walk-through for wiring Stripe into Cloak VPN. Assumes you have
a Stripe account in test mode. Follow in order; total time ~45 minutes.

Paired with `server/api/internal/stripe/webhook.go` — any changes here
should also be reflected in the code comments there.

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

## 1. Pin the API version to 2025-03-30

**This is the single most important dashboard-side setting.** Skip it
and your yearly subscribers will silently deactivate 35 days into their
year.

Stripe's `2025-03-31` API version (codename "Basil") moved
`current_period_end` off the `Subscription` object and onto
`SubscriptionItem`. Our Go SDK (`stripe-go/v79`) predates that change and
doesn't expose the new field as a typed struct. The webhook handler has
a defensive fallback (`itemPeriodEnd` in `webhook.go`) that reaches into
the raw JSON, but pinning the account-wide API version to pre-Basil is
simpler and more reliable.

**To pin:**

1. Stripe Dashboard → **Developers** → **API version**
2. You'll see your current default version at the top
3. If it shows `2025-03-31` or later, click the dropdown and select
   **`2025-03-30`** (the last version that populates
   `subscription.current_period_end`)
4. Save

This affects both API calls *and* webhook event payloads. Stripe
backports this version for years, so there's no urgency to migrate.

---

## 2. Create the four products

Create one Stripe **Product** per pricing tier, with two recurring
**Prices** each (monthly + yearly).

Dashboard → **Product catalog** → **Create product**. Repeat four times:

| Product name      | Price | Interval | Notes                                    |
|-------------------|-------|----------|------------------------------------------|
| Cloak VPN Basic   | $4.99 | Monthly  | 3 devices, EU+US core                    |
| Cloak VPN Basic   | $49.99| Yearly   | Same as above, yearly billing            |
| Cloak VPN Pro     | $9.99 | Monthly  | 10 devices, all locations, AI shield off |
| Cloak VPN Pro     | $99.99| Yearly   | Same, yearly billing                     |

(Matches `docs/PRICING.md`. AI Shield is currently deferred per the
revenue-focused roadmap.)

**After each price is created, copy its `price_...` ID.** You'll need
all four in step 4.

---

## 3. Generate Payment Links

For each of the 4 prices:

1. Open the price in the dashboard
2. Click **Create payment link**
3. Under **Options**:
   - **Collect customer email** → **Yes** (required — the webhook uses
     it as the account primary key)
   - **Allow promotion codes** → optional
   - **Confirmation behaviour** → "Don't show a confirmation page,
     redirect to: `https://cloakvpn.ai/welcome?session_id={CHECKOUT_SESSION_ID}`"
     (build this page later; for now you can redirect to `cloakvpn.ai`)
4. Click **Create link** → copy the `https://buy.stripe.com/...` URL
5. Paste it into the `cloakvpn.ai` Subscribe button for that tier

---

## 4. Create the webhook endpoint

Dashboard → **Developers** → **Webhooks** → **Add endpoint**:

- **Endpoint URL:** `https://api.cloakvpn.ai/v1/webhook/stripe`
  - For now you can use ngrok against cloak-fi1 until the `api.` DNS
    is wired. Run `ngrok http 8080` on the box.
- **API version:** "default" (which is now `2025-03-30` after step 1)
- **Events to send:** select exactly these three:
  - `checkout.session.completed`
  - `customer.subscription.updated`
  - `customer.subscription.deleted`

Click **Add endpoint**. On the next page you'll see a **Signing secret**
(`whsec_...`). Copy it — this is `STRIPE_WEBHOOK_SECRET` in step 5.

---

## 5. Configure environment variables on the concentrator

The API process (`cloakvpn-api`) reads these from env. For cloak-fi1
we'll put them in `/etc/cloakvpn/api.env` and load via the systemd unit.

```ini
# /etc/cloakvpn/api.env — owned by root, 0600
LISTEN_ADDR=127.0.0.1:8080
DB_PATH=/var/lib/cloakvpn/cloakvpn.db

STRIPE_WEBHOOK_SECRET=whsec_...                    # from step 4
STRIPE_PRICE_BASIC_MONTH=price_...                 # from step 2
STRIPE_PRICE_BASIC_YEAR=price_...
STRIPE_PRICE_PRO_MONTH=price_...
STRIPE_PRICE_PRO_YEAR=price_...

WG_IFACE=wg0
WG_SERVER_PUB=$(cat /etc/wireguard/server.pub)     # expand at install time
WG_ENDPOINT=fi1.cloakvpn.ai:51820                  # OR de1.cloakvpn.ai for de1
WG_DNS=10.99.0.1
WG_ALLOWED_IPS=0.0.0.0/0, ::/0
WG_SUBNET=10.99.0.0/24
```

**Security note:** file should be `chmod 600 /etc/cloakvpn/api.env`,
owned by root. The webhook secret is the difference between "my API is
secure" and "anyone can mint active subscriptions."

---

## 6. Test the flow end-to-end with Stripe CLI

Before pointing the real Payment Link at the live endpoint, dry-run it.

On your laptop:

```bash
# Install if you don't have it
brew install stripe/stripe-cli/stripe

# Login
stripe login

# Forward events to the running API (locally or via ssh tunnel to fi1)
stripe listen --forward-to http://localhost:8080/v1/webhook/stripe

# In another terminal, trigger a fake event
stripe trigger checkout.session.completed
```

You should see the forwarded event hit your API and log a line like
`POST /v1/webhook/stripe 200 OK`. If you see signature-verify failures,
the `STRIPE_WEBHOOK_SECRET` env isn't being picked up — the `stripe
listen` command prints its own test secret, which is *different* from
the one in the dashboard. Use `--skip-verify` for CLI testing OR set
`STRIPE_WEBHOOK_SECRET` to the `whsec_...` the CLI prints on startup.

---

## 7. Go live (test-mode first)

1. Flip the dashboard from **Test mode** to **Live mode** only when
   you're ready to take real money
2. Re-do steps 2, 3, 4 in live mode — products, payment links, and
   webhook endpoints are scoped per-mode
3. Update `/etc/cloakvpn/api.env` with the live `whsec_...` and live
   `price_...` IDs (they're prefixed `price_1Live...` vs
   `price_1Test...`)
4. Restart `cloakvpn-api.service`
5. Buy a subscription yourself with a real card to prove the full
   path works before telling anyone it's open

---

## 8. What happens when someone subscribes

The flow that makes all of this actually work:

1. User clicks "Subscribe" on `cloakvpn.ai` → redirected to
   `https://buy.stripe.com/...`
2. User enters email + card, pays
3. Stripe sends `checkout.session.completed` → our webhook
4. Our webhook calls `UpsertAccountByStripeCustomer`, creating the
   account row with `tier`, `device_limit`, `active_until = now + 35d`
5. User is redirected to `cloakvpn.ai/welcome?session_id=cs_...` where
   the page instructs them to open the Cloak app and sign in with the
   email they paid with
6. The Cloak app calls `POST /v1/device` with that email → server
   checks the account is active → `wg.Controller.Provision` mints
   WG+Rosenpass keys, adds the peer, returns the config → app imports
   it into the TunnelManager
7. Monthly/yearly renewal: Stripe charges the card → emits
   `customer.subscription.updated` → webhook refreshes `active_until`
   to the new period end + 3 days grace
8. Cancellation: Stripe emits `customer.subscription.deleted` → webhook
   deactivates the account → on next app call `/v1/device` returns 402
   Payment Required

---

## 9. Troubleshooting

- **Webhook retries:** Stripe retries 4xx/5xx responses for up to 3
  days. If you're debugging locally, check Dashboard → Developers →
  Webhooks → your endpoint → Event deliveries for the raw payload of
  failed events.
- **Yearly subscribers expire at 35 days:** you forgot step 1 (pin API
  version). Fix it, then manually run `UPDATE accounts SET active_until
  = datetime('now', '+400 days') WHERE stripe_customer_id = 'cus_...';`
  to restore affected customers. Future updates will then refresh
  correctly.
- **New checkout emits `checkout.session.completed` but no account is
  created:** the `price_...` in the event doesn't match any of the 4
  env vars. Check the log for `"checkout completed for unknown price
  %q"` and reconcile.
