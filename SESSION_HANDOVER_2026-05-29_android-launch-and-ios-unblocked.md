# Session Handover — 2026-05-29 — Android launched, iOS unblocked

Handoff for a fresh chat. Read this top to bottom before doing anything.

This session followed `SESSION_HANDOVER_2026-05-26_us-east-1-outage.md`.
It started as "continue toward the Google Play upload" and turned into
a marathon launch session: live incident fix (us-east-1), full Android
Play submission (Closed Testing + Production review), website overhaul,
Stripe customer-email scrub, and finally the Apple Developer org
migration cleared so iOS is now unblocked. Lots happened. The pending
work below is what to do next.

---

## TL;DR — where things stand

| Area | Status |
|------|--------|
| us-east-1 outage (`WG_SERVER_PUB` placeholder) | **DONE** — fixed + regionsvc hardened with `mustWGPubkey`/`mustEndpoint` validators, deployed fleet-wide |
| Cancel-subscription flow (Android app + `/account` page) | **DONE** — committed, live |
| Stripe support email scrub (`support@latticevpn.ai` everywhere customer-facing) | **DONE** — `STRIPE_SETUP.md` §4a documents the trap |
| Website iPhone → Android flip (CTAs, hero, footer, etc.) | **DONE** — committed, deployed |
| Privacy policy rebuild (KryptoKnightz LLC, em dashes removed) | **DONE** — live at `latticevpn.ai/privacy` |
| Vultr SSH config block | **DONE** — `~/.ssh/config` has it |
| Android AAB build + sign | **DONE** — `versionCode=2`, `versionName=1.0.0`, sha256 `a7f3c844…` |
| Play Console app entry + developer verification | **DONE** — package `ai.latticevpn.android` verified |
| Play marketing assets (icon, feature graphic, 6 tiles) | **DONE** — in `clients/android/play-assets/` |
| **Android Play submission — Closed Testing + Production** | **IN GOOGLE REVIEW** — submitted, waiting for verdict |
| Apple Developer Program org migration | **CLEARED** — KryptoKnightz LLC, Team ID `5HYY2YP2G9` |
| App Store Connect entry (`id6764261045`) | **ALIVE** — survived migration |
| **iOS Build 102** | **REJECTED** — reason not yet investigated ← **next task** |
| **iOS launch** | **NOT STARTED** — Build 102 rejection investigation + resubmit |
| iOS Build 101 ("Ready to Submit") | Available as fallback if 102 unsalvageable |

**Immediate next task: investigate why iOS Build 102 was rejected** (see
"Next steps" below for the exact click path). The rejection reason
determines whether we fix-and-resubmit or do a fresh build (103).

---

## What was accomplished this session

### 1. us-east-1 outage diagnosed and fixed — `WG_SERVER_PUB` placeholder

Symptom: Android phone showed "Connection failed" connecting to
us-east-1. Other regions worked fine.

Diagnosed by elimination across the full stack — DNS, TLS, Caddy,
`regionsvc /healthz`, firewall, systemd drop-ins, rosenpass binary
sha256 (identical across boxes), ProtocolVersion::V03 on both sides.
The decisive test was **`tcpdump` on `:9999` during a phone connect
attempt: zero packets arrived**. That meant the phone wasn't even
reaching the Rosenpass step, so the failure was earlier (WireGuard).

Root cause: `/etc/cloakvpn/regionsvc.env` on us-east-1 carried the
**literal template placeholder string**:

```
WG_SERVER_PUB=<<< this box's server.pub
```

`regionsvc` accepted it (`mustEnv` only checks non-empty), then served
that literal string back in `ClientConfig.PeerPublicKey` to every
phone. WireGuard setup errored on unparseable key → `TunnelState.ERROR`.

Immediate fix: `sed`'d the real `wg show wg0 public-key` value into the
env file on us-east-1, restarted `regionsvc`, `pm clear` on phone,
reconnect → online. Full runbook in
`docs/HOTFIX_regionsvc-pubkey-placeholder-2026-05-26.md`.

### 2. Durable hardening — regionsvc rejects placeholder env at startup

Committed (`06ef856`) to `server/api/cmd/regionsvc/main.go`:
- `mustWGPubkey(k)` — base64-decode the env value, assert exactly 32
  bytes (a real WireGuard public key). Anything else → `log.Fatalf`
  with the offending value quoted.
- `mustEndpoint(k)` — assert `host:port` shape (last-colon split,
  IPv6-safe), reject values containing `<`, `>`, `…`.

Deployed to all 10 boxes via the standard scp + sha-verify + restart
loop. Every box came back `systemctl is-active=active`, which **is the
audit** — any other box with a placeholder would have refused to
start. None did. us-east-1 was the only affected box.

### 3. Cancel-subscription flow fixed

Android app's "Manage or cancel subscription" used to open
`https://latticevpn.ai` (marketing root). Users landed on the homepage
with no path to cancel. Two changes:

- New page `website-v2/src/pages/account.astro` — framed
  cancel-first, points at the Stripe billing portal, cross-links to
  `/recover` for account-number recovery.
- `AccountScreen.kt:213-217` now opens `https://latticevpn.ai/account`
  with a more informative subtitle.

Site verified building cleanly, page committed and deployed.

### 4. Stripe customer-facing email scrubbed to `support@latticevpn.ai`

Earlier in session, customer-portal login emails showed the user's
personal `demetris@neuroaistudios.com` in the "Questions? Contact us
at …" footer. The leak was the **"Customer support information" card
at Stripe Settings → Business → Public details → Customer support
information → Support email**, NOT any of the other email fields
(Personal details, Stripe profile, Account representative) which are
all decoys that look like they should drive customer emails but
don't.

Documented this trap in `STRIPE_SETUP.md` §4a with a decoy-fields
table so the next person doesn't waste an hour on it.

### 5. Website iPhone → Android flip across the board

Site was advertising a (broken) App Store URL for iOS and didn't
mention Android at all. Updated:

- `LatticeHero.astro` — hero CTA → "Get Lattice for Android" + Play
  Store URL + Android icon
- `Platforms.astro` — Android = available with "Get on Google Play"
  button; iPhone/iPad + macOS = coming soon; section tagline updated
- `Navbar.astro` — top-right CTA + mobile menu CTA → Play Store
- `Footer.astro` — "Download" link → Play Store
- `ClosingCTA.astro` — big closing CTA → "Get on Google Play",
  corrected misleading "Cancel anytime in iPhone settings" copy
- `Layout.astro` — page title pattern
- `index.astro` — meta description, pricing teaser copy

Site rebuilt clean (10 pages). Commit + push, host redeployed.

### 6. Privacy policy live + em dashes scrubbed

Privacy page was previously a stub redirecting to `cloakvpn.ai/privacy`
(legacy domain) — would have failed Play review. Rebuilt as a full
Astro page with:

- Effective date `2026-05-26`
- KryptoKnightz LLC, 87-154a Maipalaoa Road, Waianae, HI 96792
- Hawaii governing law
- Accurate retention statements (device records evicted by
  per-account limit; Stripe billing records 7 years per US tax law)
- Same Stripe portal URL as `/recover` and `/account`
- All `[PLACEHOLDER]` markers filled
- Zero em dashes (user explicit request)

Build verified, page live at `latticevpn.ai/privacy`. Footer Privacy
link already in place (line 41 of Footer.astro) so the URL is
discoverable.

### 7. Android Play Console submission

End-to-end, including some surprises along the way:

- **Versioning**: bumped `versionCode 1→2`, `versionName 0.1.0→1.0.0`
- **Build**: APK first (tested R8 on phone, post-quantum rotation
  verified), then AAB. AAB sha256: `a7f3c844…`
- **Android developer verification**: registered package
  `ai.latticevpn.android` with the upload-key SHA-256 fingerprint
  (verified instantly)
- **Create app**: name "Lattice VPN", en-US, App, Free, both
  declaration checkboxes
- **Marketing assets** generated in `clients/android/play-assets/`:
  - `app-icon-512.png` — 512×512 RGBA
  - `feature-graphic-1024x500.png` — 1024×500 RGB
  - `marketing-tiles/01-tile-hero.png` through `06-tile-simple.png` —
    six 1080×1920 branded marketing tiles (Lattice navy + mint, phone
    mockups with rounded corners + drop shadow, headlines like
    "Built for tomorrow's threats", "Protected in one tap",
    "10 secure locations", "Strict no-logs", "No email. No password.",
    "Designed to disappear")
- **Screenshot redactions** (critical, do not skip on future shots):
  - `04-account.png` had a real account number letter `K` showing →
    redacted to placeholder `L8XF · MRPQ · 7V3M`
  - `05-settings.png` showed a real PQ public key → redacted to
    placeholder `bwuiW…d9X3z`
- **App Access** task: user needs a real Stripe-subscribed account
  number for Play reviewers (still not provided to Play — see
  "Things still open" below)
- **16 KB page support**: Play threw an error that the AAB doesn't
  support 16 KB memory pages (newer Pixel/Samsung devices). User
  hit a "Proceed anyway" option. Queued as a fix for `versionCode=3`.
- **Submitted to both Closed Testing track and Production track** —
  same AAB. Both in Google review queue now.

### 8. Apple Developer Program migration complete

User received confirmation: KryptoKnightz LLC enrollment complete,
Team ID `5HYY2YP2G9`. iOS is now unblocked after months of waiting.

App Store Connect side verified:
- "Lattice VPN" app entry alive under KryptoKnightz LLC
- App ID `6764261045` intact
- TestFlight build history preserved:
  - **Build 102 — Rejected** (need to investigate why)
  - Build 101 — Ready to Submit (clean fallback)
  - Build 1 — Expired
- Tester groups still labeled with legacy "Cloak VPN App" naming
- `clients/ios/CloakVPN.xcodeproj` already has
  `DEVELOPMENT_TEAM = 5HYY2YP2G9` set, so signing should work without
  any code change
- Bundle IDs still in `ai.cloakvpn.*` namespace — works fine; rename
  to `ai.latticevpn.*` is cosmetic only and not required (would force
  a fresh App Store Connect entry, not worth it)

### 9. Apple W-9 / Paid Apps Agreement issue (deferred)

User hit "Tax ID entered already exists" on the W-9 for the Paid Apps
Agreement. EIN `873944997` is registered in Apple's system from a
previous attempt or the individual-account era.

**Recommendation given: skip the Paid Apps Agreement entirely**, since
Lattice is a free download with Stripe-on-web subscriptions (Mullvad /
ExpressVPN / ProtonVPN model). Only the **Free Apps Agreement** is
needed for App Store review. The user can revisit the EIN duplicate
later via Apple Developer Support if they ever want Paid Apps active.

User to verify Free Apps Agreement is Active at the start of the next
session, then proceed without the W-9.

---

## Next steps

### IMMEDIATE — Investigate iOS Build 102 rejection

1. Open App Store Connect → Lattice VPN → TestFlight → click on
   Build **102** in the BUILD column.
2. Look for **Resolution Center** / **rejection reason** in the build
   detail. Also check the **App Store** tab → **App Review** sidebar
   for the rejection notes.
3. Paste the reason back to the next chat. Common VPN-app rejections:
   - **Guideline 5.1.1 (Privacy)** — fix the App Store Connect
     privacy questionnaire to match `latticevpn.ai/privacy`
   - **Guideline 2.1 (App completeness — needs credentials)** —
     reviewer hit account-number screen, couldn't proceed.
     Same fix as the Play "App access" task: provide a real account
     number with active subscription. Have not done this yet for
     either Play or App Store.
   - **Guideline 5.4 (VPN apps must use NetworkExtension)** — Lattice
     does, this should not apply
   - **Metadata / branding inconsistency** — "Cloak VPN" still
     appearing somewhere (tester group names, in-app text, etc.)

### After understanding the rejection

If 102's reason is **metadata / privacy form / App access only** →
fix the App Store Connect form, resubmit Build 102 (or promote 101
if 102 is permanently rejected). No rebuild needed.

If 102's reason requires **code change** → archive in Xcode (build
103), upload via Organizer, submit.

Either way, the iOS App Review path mirrors what we just did for
Play: App Store Connect listing copy, screenshots, privacy
questionnaire, age rating, App Privacy declarations (which are
analogous to Play's Data safety form), VPN entitlement confirmation.

### Verify the Free Apps Agreement is Active

App Store Connect → Business → Agreements, Tax, and Banking. Confirm
**Free Apps Agreement = Active**. If it isn't, complete it — that
unblocks the App Store submission. Skip the Paid Apps Agreement
(deferred per the W-9 issue).

### Provide reviewer credentials (Play AND App Store)

For both stores, you need a working account number that reviewers can
use. We have not yet done this for Play either — the production
submission is currently being reviewed without test credentials,
which may come back as a 2.1-equivalent rejection.

Recommended: subscribe to Lattice Pro annual ($99) on
`latticevpn.ai/pricing` using a dedicated email like
`play-reviewer@kryptoknightz.com`. Save the resulting account number
in a password manager. Add it to **Play Console → App content → App
access** form, and to the **App Review notes** field in App Store
Connect when submitting iOS.

### Android: monitor Play review verdict

Production review typically 3-7 days for VPN apps. Closed Testing
review is faster (same-day to ~1 day). When the email arrives:
- **Approved on Closed Testing** → you can graduate the same AAB to
  Production from within Play Console (no rebuild, no re-review)
- **Rejected** → read the reason in Play Console resolution center,
  fix, rebuild with new versionCode if needed

### Android v1.0.1 — fix 16 KB page support (versionCode=3)

Required for newer Pixel/Samsung devices running Android 15+ in 16
KB-page mode. Affects:
- `librosenpassffi.so` — needs
  `RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384"` passed to
  cargo-ndk, **plus** the same flag pushed through the cmake-rs
  sub-build of liboqs (CFLAGS)
- `libwg-go.so` — needs `-extldflags '-Wl,-z,max-page-size=16384'`
  via Go's linker, through the wireguard-android Makefile

After rebuilding, verify with `readelf -l libfoo.so | grep LOAD` —
alignment should be `0x4000`. Then bump `versionCode` to 3, rebuild
AAB, push as update.

Not blocking, but important to ship within a week or two of launch.

---

## Things still open / open questions

- **Reviewer credentials for both stores** — see "Next steps" above.
- **iOS bundle IDs still in `ai.cloakvpn.*` namespace** — cosmetic
  only, do not rename (would force a fresh App Store Connect entry).
- **TestFlight groups labeled "Cloak VPN App" / "External Cloak VPN
  App Te…"** — cosmetic, rename in App Store Connect when convenient.
- **`Comparison.astro`** is dead code (not imported anywhere) — has
  stale "Apple App Store native / iOS-built" copy. Either delete or
  update + re-link from the homepage. Not blocking.
- **PLAY_STORE.md** is partly stale — its "Decisions" section lists
  "Legal entity + registered address" as TODO, but these are now
  known (KryptoKnightz LLC / 87-154a Maipalaoa Road). The
  Monetization section claims account-number system doesn't exist;
  it does. Cleanup item.
- **Add a `/privacy` link to the website navbar?** Not standard
  practice (footer is the universal pattern), and the user already
  has it in the footer. I did not add a nav-level link. Revisit if
  the user wants more discoverability.

---

## Gotchas hit this session (so the next chat doesn't repeat them)

- **`WG_SERVER_PUB` placeholder bug** is now caught at startup by
  `mustWGPubkey`. If a future region setup fails to substitute the
  env file, `regionsvc` refuses to start and the journal names the
  bad env var. Lesson: every required env field with a constrained
  format should have a runtime validator, not just non-empty check.
- **"Tax ID already exists" on Apple's W-9** is solvable but doesn't
  need to be solved if you're using the Mullvad model (free app, web
  subscriptions). Verify Free Apps Agreement is Active and skip
  Paid Apps until you actually want IAP.
- **Stripe customer-portal email's "Questions? Contact us at …"
  footer** is driven by the **"Customer support information" card**
  in Settings → Business → Public details. NOT the Personal details
  email, NOT the Stripe profile business email, NOT the account
  representative email. Documented in `STRIPE_SETUP.md` §4a with a
  decoy-fields table.
- **Account number IS the auth credential** — any screenshot that
  shows it (even partially, e.g., a leading character) must be
  redacted before going into marketing. Play Store screenshots are
  permanent once submitted; redact before upload.
- **Rosenpass public key**, while not strictly a cryptographic
  secret, is a per-device identifier and should be redacted in
  marketing materials for privacy-positioning consistency.
- **Play Console's `App access` task** is required even for "free"
  apps if any screen requires sign-in. Have a real working account
  number ready before getting to this task; otherwise Google's
  automated scanner flags it as "Missing login credentials".
- **Play Console's "Set up your app" task list** is reached from the
  **Dashboard**, not from a sidebar item called "App content" — UI
  reorganized. The internal-testing-only task subset is shown under
  "Start testing now" → "View tasks" if you only want to ship to
  internal.
- **16 KB page support warning on Play** is currently a soft block
  with "Proceed anyway" available. Will become a hard requirement.
- **Apple iOS dev account migration** doesn't destroy App Store
  Connect entries, TestFlight build history, or related metadata.
  The DEVELOPMENT_TEAM in Xcode project files DOES need to match the
  new Team ID — verify in `project.pbxproj`.
- **Marketing screenshots take real time**. Allow ~20-30 min per
  branded tile if you want NordVPN-quality. Raw `adb screencap`
  screenshots work for internal testing but convert poorly for
  production listing.

---

## Reference

### Build artifacts
- Android AAB: `clients/android/app/build/outputs/bundle/release/app-release.aab`
  - sha256: `a7f3c8448ff2f66ea33b0f113001adeeb5e07d78f9ece0b42d2defc866395602`
  - 11 MB, versionCode=2, versionName=1.0.0
- Android APK (for local install/testing only):
  `clients/android/app/build/outputs/apk/release/app-release.apk`
- iOS project: `clients/ios/CloakVPN.xcodeproj`
- iOS team: `DEVELOPMENT_TEAM = 5HYY2YP2G9` (KryptoKnightz LLC)
- iOS bundle IDs: `ai.cloakvpn.CloakVPN` (main),
  `ai.cloakvpn.CloakVPN.CloakTunnel` (NetworkExtension)
- iOS marketing version: `1.0`, current project version: `102`

### Play Store assets
All in `clients/android/play-assets/`:
- `app-icon-512.png` (512×512 RGBA)
- `feature-graphic-1024x500.png` (1024×500 RGB)
- `marketing-tiles/01-tile-hero.png` through `06-tile-simple.png`
  (1080×1920 each)
- `raw-screenshots/*.png` (raw + `.original.png` backups of redacted ones)

### Apple identity
- Team ID: `5HYY2YP2G9`
- Entity: KryptoKnightz LLC
- Account holder: Demetris Dangerfield
- App Apple ID: `6764261045`
- App Store URL (once live):
  `https://apps.apple.com/app/lattice-vpn/id6764261045`

### Google Play identity
- Package: `ai.latticevpn.android`
- Upload key SHA-256: (in `clients/android/secrets.properties`,
  password-protected `lattice-release.jks`)
- Play Store URL (once approved):
  `https://play.google.com/store/apps/details?id=ai.latticevpn.android`

### Recent docs
- `docs/HOTFIX_regionsvc-pubkey-placeholder-2026-05-26.md` — full
  postmortem of the us-east-1 outage
- `docs/STRIPE_SETUP.md` §4a — public business profile + decoy email
  fields
- `SESSION_HANDOVER_2026-05-26_us-east-1-outage.md` — prior session

### Stripe details
- Public business profile: `support@latticevpn.ai` (driving all
  customer-facing email footers)
- Personal details / Stripe profile / Account representative emails
  also set to `support@latticevpn.ai` (for consistency)
- Statement descriptor: `LATTICE VPN`
- Customer portal URL:
  `https://billing.stripe.com/p/login/9B600j83jfwo3Xv2SwfrW00`

### Commits made this session (newest first)
```
(site)    site: replace privacy stub with live privacy policy
(site)    site: flip iPhone→Android availability + remove em dashes from /privacy
(app)     app+site: dedicated /account page for managing or cancelling
(docs)    docs: hotfix runbook + session handover for the us-east-1 outage
(docs)    docs: document support-email and public business profile in STRIPE_SETUP
(docs)    docs: specify Customer support information as the source of customer-facing support email
06ef856   regionsvc: fail-fast on placeholder WG_SERVER_PUB / malformed WG_ENDPOINT
```

`git push` to back everything up to GitHub. If anything wasn't
committed at the end of the session (e.g., this handover doc itself,
Android versionCode bump in `build.gradle.kts`), add + commit + push
in the new session.

### Account numbers + secrets (do not store here)
Per project policy, no secrets in handover docs. They live only in
`/etc/cloakvpn/*.env` on the boxes and the user's password manager.

---

## What's still on the launch punch list

Roughly in order of priority once iOS is moving:

1. **iOS Build 102 rejection investigation** (next chat's first task)
2. **iOS reviewer credentials** + App Store submission
3. **Play reviewer credentials** (if not already added to the
   in-review submission)
4. **Android v1.0.1 16 KB page fix** — within a week of launch
5. **PLAY_STORE.md** cleanup (stale decisions, monetization section)
6. **TestFlight group rename** (Cloak → Lattice)
7. **Marketing tile iteration** — current ones are auto-generated;
   real designer pass would lift them another tier
8. **Provisioning self-check on regionsvc** — Tokyo postmortem
   suggested running one synthetic handshake against each newly-added
   peer before returning `200`. Would have caught both Tokyo and
   us-east-1 at deploy time. ~1 hour of work.
9. **Rosenpass restart-per-provision** scaling concern (carried over
   from prior handovers, still open).
