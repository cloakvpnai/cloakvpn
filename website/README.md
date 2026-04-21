# cloakvpn.ai — marketing site

Static, zero-build. Tailwind via CDN, vanilla JS. Deploys anywhere that serves HTML; recommended host is **Cloudflare Pages** (free tier, Cloudflare-managed TLS, no Cloudflare account required for the visitor, no JS runtime on our server to worry about logs for).

## Files

```
website/
├── index.html          # landing page
├── pricing.html        # Basic + Pro plans (with monthly/annual toggle + Stripe placeholder)
├── assets/             # reserved for /logo.svg, /og.png, etc.
└── README.md
```

Future: `privacy.html`, `terms.html`, `canary.html` (warrant canary), `transparency.html`, `audit.html`.

## Local preview

```bash
cd website
python3 -m http.server 8000
# open http://localhost:8000
```

## Deploy to Cloudflare Pages

Recommended because:
- Free, global CDN, automatic HTTPS for `cloakvpn.ai`.
- Supports deploying a subdirectory of a monorepo.
- No build command needed — we serve `website/` directly.

**One-time setup:**

1. Push this repo to GitHub (private is fine).
2. Cloudflare dashboard → **Workers & Pages → Create → Pages → Connect to Git**.
3. Pick the repo. In build settings:
   - **Framework preset:** *None*.
   - **Build command:** *(leave empty)*.
   - **Build output directory:** `website`.
   - **Root directory (advanced):** `/` (or `cloak-vpn` if you push the outer folder).
4. Environment variables: none needed yet.
5. Deploy. You'll get `https://cloakvpn.pages.dev`.

**Attach `cloakvpn.ai`:**

1. Buy `cloakvpn.ai` (Cloudflare Registrar is cheapest and does not resell — ~$10/yr for `.ai` depending on registrar, `.ai` is usually pricier; confirm at checkout).
2. If you bought it through Cloudflare, nameservers are already set. If elsewhere, set their nameservers to the two Cloudflare ones shown in the dashboard.
3. In Pages → *Custom domains* → add `cloakvpn.ai` and `www.cloakvpn.ai`. Cloudflare provisions TLS automatically (takes < 5 min).
4. Turn on **Always use HTTPS** and **HSTS** in the zone's SSL/TLS → *Edge Certificates*.

## Stripe Pricing Table (when you're ready)

The pricing page currently uses static HTML cards with a client-side billing toggle. To swap in a real Stripe-hosted Pricing Table:

1. Create two **Products** in Stripe: `Cloak Basic` and `Cloak Pro`, each with a monthly and annual **Price**.
2. Stripe → *Product catalog → Pricing tables → Create pricing table*. Add both products; enable monthly+annual.
3. Copy the generated `prctbl_...` ID and your `pk_live_...` publishable key.
4. In `pricing.html`, find the commented-out `<!-- Stripe Pricing Table placeholder -->` block, paste the IDs, and uncomment.
5. Optionally delete the static card markup above it (or keep both and A/B which converts better).

For a fully branded checkout you can skip the pricing table and instead POST to `/v1/checkout` on the Go API (`server/api/`), which will create a Stripe Checkout Session and redirect the customer. That's the path the CTA links already use (`/api/v1/checkout?tier=basic&interval=month`).

## Content conventions

- Dark ink theme with `cloak` blue accents. Colors are defined inline in `<script>tailwind.config</script>` in each page — keep them in sync.
- No tracking scripts. No third-party fonts. No third-party JS besides Tailwind CDN and (optionally) Stripe Pricing Table.
- Every page ships a footer with links to `/privacy.html`, `/terms.html`, `/canary.html`.
- Keep JS inline and vanilla. No bundler.
