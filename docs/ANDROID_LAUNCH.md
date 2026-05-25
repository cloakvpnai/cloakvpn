# Android launch plan — fastest path to "live and selling"

Goal: **Lattice VPN live on the Google Play Store, taking real payments**,
single region (us-west-1). Multi-region and iOS are deferred — see the end.

### Where things stand now

- Backend (`cloakvpn-api`) is deployed on us-west-1 and live at
  `https://api.latticevpn.ai`.
- The Android app is built, committed, and proven end-to-end on a device.
- Stripe is in **test mode**. The website exists but sits on `cloakvpn.ai`
  with unfilled placeholders.

Order matters — each phase depends on the one before it. Owner tags:
**(you)** = your account/console work, **(code)** = a code or build task,
**(both)** = collaborative.

---

## Phase A — Website onto latticevpn.ai

The app links to `latticevpn.ai`, and the API's `/v1/account-number`
endpoint only accepts the website's cross-origin request from
`https://latticevpn.ai` — so the site must live there.

- [ ] **A1.** Point the website's Cloudflare Pages project at
  `latticevpn.ai` + `www` (add them as custom domains on the Pages
  project; add the DNS records in the `latticevpn.ai` zone). **(you)**
- [ ] **A2.** Fill the remaining placeholders in the website pages —
  pricing, recover, privacy policy. **(both)**
- [ ] **A3.** Confirm live in a browser: `latticevpn.ai/pricing`,
  `/recover`, the privacy-policy page, and the `/welcome` page. **(you)**

## Phase B — Stripe live mode

Everything so far is Stripe **test mode**. Going live means new live keys,
products, Payment Links, and webhook. Detailed steps: `STRIPE_SETUP.md`
and `DEPLOY_API.md` §6c.

- [ ] **B1.** In Stripe, switch to **Live mode**; recreate the 4
  products/prices (Basic & Pro × monthly & yearly); note the live
  `price_…` IDs. **(you)**
- [ ] **B2.** Create 4 live **Payment Links**, each redirecting to
  `https://latticevpn.ai/welcome?session_id={CHECKOUT_SESSION_ID}`. **(you)**
- [ ] **B3.** Put those Payment Link URLs into the website pricing page. **(both)**
- [ ] **B4.** Create the live **webhook endpoint** →
  `https://api.latticevpn.ai/v1/webhook/stripe` (the 3 events from
  `STRIPE_SETUP.md`). **(you)**
- [ ] **B5.** Update `/etc/cloakvpn/api.env` on the box with the live
  `STRIPE_SECRET_KEY`, live `whsec_…`, and the 4 live `price_…` IDs; then
  `systemctl restart cloakvpn-api`. **(both)**
- [ ] **B6.** One real live-mode purchase as a test (refund yourself
  after) — confirm the account is created and the number shows on
  `/welcome`. **(both)**

## Phase C — App final prep

- [ ] **C1.** Trim the region picker to the one live region (us-west-1)
  so the app is honest about what's actually available. **(code)**
- [ ] **C2.** Full clean-install QA on a device: sign-in, provision,
  connect, browse, account screen, sign-out. **(both)**
- [ ] **C3.** Set the release `versionCode` / `versionName`; build the
  signed release bundle (`./gradlew :app:bundleRelease`). **(code)**

## Phase D — Google Play submission

Detailed walk-through: `clients/android/PLAY_STORE.md`.

- [ ] **D1.** In Play Console, create the app; fill the store listing
  (copy is already drafted from the A7 work). **(both)**
- [ ] **D2.** Capture screenshots from the running app; add the feature
  graphic and icon. **(both)**
- [ ] **D3.** Complete the required forms — Content rating, Data safety,
  target audience — and supply the privacy-policy URL. **(you)**
- [ ] **D4.** Upload the AAB to **Internal testing** first; install from
  that track and sanity-check. **(both)**
- [ ] **D5.** Promote to **Production** and submit for review. **(you)**
- [ ] **D6.** Answer any Google review follow-up (VPN apps often get
  one). **(you)**

## Phase E — Live

- [ ] **E1.** Review approved → release to production. **(you)**
- [ ] **E2.** Do a real install-and-subscribe from the public listing. **(you)**

---

## Deferred — not launch blockers

- **Multi-region** — deploy `cloakvpn-api` to us-east-1 / de1 / fi1 and
  share the account store across regions (`BILLING_INTEGRATION.md` §7),
  then re-expand the region picker.
- **iOS** — the full account-number migration in Swift, plus the App
  Store in-app-purchase question.

## Rough timeline

Active work across A–D is a handful of focused days. The calendar is
dominated by **Google Play review** (a few days to ~2 weeks for a VPN
app) and your own pace on the Stripe and Play Console setup. Realistic
elapsed time to live: **1–2 weeks.**
