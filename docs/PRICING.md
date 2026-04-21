# Cloak VPN — Pricing

Two tiers. Both tiers always include post-quantum cryptography and strict no-logs — those are the product, not a premium upsell.

## The tiers at a glance

| Feature | Basic | Pro |
|---|---|---|
| **Monthly price** | $4.99 | $9.99 |
| **Annual price** (≈ 2 months free) | $49.99 (~$4.17/mo) | $99.99 (~$8.33/mo) |
| Post-quantum (Rosenpass + WireGuard) | ✅ | ✅ |
| Strict no-logs, RAM-only servers | ✅ | ✅ |
| iOS + Android apps | ✅ | ✅ |
| Device limit | **3** | **10** |
| Server locations | Core (EU + US) | **All, including future launches** |
| AI phishing, tracker & malware shield (on-device) | — | ✅ |
| Split tunneling | — | ✅ |
| Custom / encrypted DNS | — | ✅ |
| Obfuscated / bridge servers | — | ✅ |
| Port forwarding | — | ✅ (on request) |
| Priority support | — | ✅ |
| Refund window | 7 days | 7 days |

### Why these numbers

- **$4.99 / $9.99** is the price band privacy-maximalist competitors (Mullvad is a flat €5, IVPN Pro is $10, ProtonVPN Plus is $9.99) already normalized. Going lower signals "cheap VPN" (Surfshark/Atlas territory) and weakens the premium-privacy positioning.
- **Annual at ~2 months free (≈17% off)** is the industry default customers recognize without feeling manipulated. Avoid 3-year "$1.99/mo" deals — they work against the trust narrative.
- **3 devices / 10 devices** is enough to cover the "me + partner + TV" household use case on Basic without cannibalizing Pro for small families or prosumers.

### Why PQC is NOT a Pro feature

Cloak's whole reason to exist is the post-quantum promise. Paywalling PQC to Pro would mean Basic customers run an inferior security model, which:

1. undermines the marketing ("the VPN built for the next decade of threats") for the majority of customers,
2. splits the threat model — ops would need to explain why some tunnels rotate PSKs and some don't,
3. gives reviewers a stick to beat us with.

Pro differentiates on convenience and coverage (devices, locations, obfuscation, AI shield), not on the crypto floor.

## Stripe setup checklist

1. Dashboard → **Product catalog** → create two Products: `Cloak Basic`, `Cloak Pro`.
2. On each, add two recurring Prices: monthly + annual (USD).
3. Copy the four `price_…` IDs into `server/api/` env:
   - `STRIPE_PRICE_BASIC_MONTH`
   - `STRIPE_PRICE_BASIC_YEAR`
   - `STRIPE_PRICE_PRO_MONTH`
   - `STRIPE_PRICE_PRO_YEAR`
4. Dashboard → **Developers → Webhooks → Add endpoint**:
   - URL: `https://api.cloakvpn.ai/v1/webhook/stripe`
   - Events: `checkout.session.completed`, `customer.subscription.updated`, `customer.subscription.deleted`
   - Store the `whsec_…` as `STRIPE_WEBHOOK_SECRET`.
5. Dashboard → **Product catalog → Pricing tables → Create** and add both Products. Copy the `prctbl_…` ID into `website/pricing.html` (there's a commented block ready for it).

## Payment methods beyond Stripe

Stripe is the default checkout for Phase 0 — fastest to integrate, easiest to refund, works worldwide except OFAC-embargoed regions. For brand credibility with the privacy crowd we also plan:

- **Bitcoin / Monero** via **BTCPay Server** (self-hosted, no KYC). Ship after Stripe is stable.
- **Cash by mail** (anonymous account top-up). Low volume, high signal — Mullvad / IVPN both offer it and it costs us ~nothing.
- **Paddle** as a merchant-of-record fallback if Stripe ever flags VPN risk. Paddle handles global VAT/GST for us in exchange for ~5% vs Stripe's ~3%.

## Promotions and discounts

Avoid permanent discounts. One-off allowed:

- **Student / educator** — 30% off Pro, verified via SheerID or equivalent.
- **Launch credit** — first 500 annual Pro sign-ups get 6 extra months.

Never: lifetime deals, "3 years for $X" upfront pricing, or discounts gated on installing a browser extension / uninstall survey. These are the patterns that correlate with shady VPN marketing and will cost us more in credibility than they make in revenue.
