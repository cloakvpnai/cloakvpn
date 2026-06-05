# Session Handover — 2026-06-05 (later) — App Store 3.1.1: remove ALL app→site links

Follows `SESSION_HANDOVER_2026-06-05_appstore-metadata-pricing-url.md`.

## The rejection (Build 107, review June 5)
Guideline 3.1.1 again — Apple cited a specific URL `https://cloakvpn.ai/pricing/`
"in the app's metadata" and said to "remove features, account registration
links, and any other links to your site that could **indirectly** provide
access to external purchase mechanisms."

## Root cause (the real trail)
Not a metadata text field. The app's **Privacy Policy / Terms links** (and the
ASC Privacy Policy URL) pointed at pages built with the shared site `Layout`,
whose **Navbar + Footer contain a "Pricing" link**. App Review followed the
in-app privacy link → landed on the site → saw the "Pricing" nav → flagged
`cloakvpn.ai/pricing`. (cloakvpn.ai still serves the live Lattice site; both
domains share one Cloudflare Pages deploy.)

The deeper point (user caught this): the *site itself* sells via Stripe, so
**any** app→site link is an indirect path to purchase.

## Fixes — done, committed, deployed/built

### Website (commits `5148204`, `ab3f37a` — auto-deployed via GitHub Actions
`deploy-website.yml` → Cloudflare Pages `cloakvpn-ai`, serves latticevpn.ai +
cloakvpn.ai)
- Added a `bare` prop to `website-v2/src/layouts/Layout.astro`: when set, the
  page renders WITHOUT the marketing Navbar and Footer (minimal copyright
  footer only, no links).
- Set `bare` on **privacy.astro, terms.astro, recover.astro, account.astro**.
  Verified live: `cloakvpn.ai/privacy` now has 0 pricing links (home has 7).
  These pages are now dead-ends — no path to pricing.

### iOS app — Build 108 (commit `76492e5`; archived, in Organizer under
2026-06-05, installed on device)
Removed every app→website link except the two required bare legal pages:
- `AccountEntryView.swift`: removed the "Lost your account number?" button
  (→ `latticevpn.ai/recover`); replaced with plain text ("it's on your
  purchase confirmation email"). Removed now-unused `openURL`.
- `ContentView.swift`: the Account screen "Manage your subscription at
  latticevpn.ai" (→ `/recover`) is now **"Manage subscription" →
  `https://apps.apple.com/account/subscriptions`** (Apple's native sub
  management). Privacy-policy link already fixed to latticevpn.ai (045c964).
- Net: the only browser-opening links left in the app are
  `latticevpn.ai/terms` + `latticevpn.ai/privacy` (PaywallView) and
  `latticevpn.ai/privacy` (Account screen) — all bare pages — plus Apple's
  subscriptions URL. No /recover, /account, /pricing, no cloakvpn.ai.
- Build bumped to **108** (local was 106; in-review was 107).

## LAST STEP (user, App Store Connect)
1. Upload **Build 108** (Organizer → Distribute).
2. **Attach the 4 IAPs to the version submission** (the recurring 2.1(b) trap).
3. Confirm no metadata field has `cloakvpn.ai/pricing`; Privacy Policy URL →
   the bare privacy page.
4. Submit + reply (see chat / below).

Reply: "Fully addressed 3.1.1. The app no longer links to our website except
the legally-required Privacy Policy and Terms pages, which are now standalone
legal pages stripped of all navigation and any purchase link. Removed the
'Lost your account number?' and website 'Manage subscription' links;
subscription management now opens the user's Apple Account settings.
Subscriptions are sold only via In-App Purchase. The 'I already have an
account' screen is multiplatform sign-in (3.1.3(b)). Build 108 contains these."

## Still open (carried)
- **PQC re-provision loop** (iOS recovery).
- **Android v1.0.1 16 KB page fix**.
- **iOS account recovery via iCloud Keychain** (IAP restore).
- Google Play: VpnService declaration + video resubmitted (06-03) — in review.

## Reference
- Commits: `5148204`, `ab3f37a` (site bare pages), `76492e5` (iOS no-link +
  build 108). All pushed.
- iOS build = **108**; bundle `ai.cloakvpn.CloakVPN`; App ID `6764261045`.
- Website deploy: push to `website-v2/**` on main → GitHub Actions auto-deploys
  to Cloudflare Pages (both domains). Manual: Actions tab → Run workflow.
