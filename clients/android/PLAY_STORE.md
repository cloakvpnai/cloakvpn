# Lattice VPN — Google Play release guide (Phase A7)

Everything needed to publish the Android app: store-listing copy, graphic
asset specs, the signed-build runbook, and the Play Console checklist.

---

## 0. Decisions

**Resolved (2026-05-23):**

- **Brand & domain** — **Lattice VPN**, `latticevpn.ai`. Used everywhere.
- **Contact** — `support@latticevpn.ai` (public listing contact),
  `legal@latticevpn.ai` (privacy / legal).
- **Privacy policy** — published on the website at
  `https://latticevpn.ai/privacy` (source: `privacy-policy.md`).

**Still open — needed before you submit:**

1. **Legal entity name + registered address** — required on the listing
   and in the privacy policy. Still `[PLACEHOLDER]` in `privacy-policy.md`.
2. **Upload keystore** — generate it per §3 below (still to do).

**Separate work item — monetization.** The plan is to sell subscriptions
on `latticevpn.ai` via Stripe. This is **not** a listing setting and not
part of finishing this guide: the app today provisions access headlessly
with no sign-in, so a paying customer has no way to authenticate. Selling
a paid subscription also has Google Play billing-policy implications.
This needs its own design pass — see "Monetization & billing" at the end.

---

## 1. Store listing copy

### App name  (max 30 characters)

> **Lattice VPN**

Alternative if you want the keyword in the title (25 chars):
`Lattice: Post-Quantum VPN`

### Short description  (max 80 characters)

> Post-quantum VPN. Strict no-logs, WireGuard speed, crypto built for the future.

### Full description  (max 4000 characters)

```
Lattice VPN is a fast, no-logs VPN built for the post-quantum era.

Most VPNs protect you against today's threats. Lattice is built for
tomorrow's. Alongside the proven WireGuard protocol, Lattice adds
Rosenpass post-quantum key exchange — so traffic captured today stays
protected by post-quantum cryptography, even against an adversary who
stores it now hoping to break it later with a quantum computer.

POST-QUANTUM BY DEFAULT
Every connection negotiates a post-quantum key (Classic McEliece +
ML-KEM) and refreshes it every couple of minutes. There is no "premium
crypto" tier — the strongest protection is on for everyone, always.

STRICT NO-LOGS
Our servers run in RAM. No traffic logs, no connection logs, and no
account identifiers tied to your activity. Nothing is written to disk to
be leaked, subpoenaed, or sold.

FAST, MODERN TUNNEL
Built on WireGuard — the lean, modern VPN protocol — Lattice connects in
seconds and stays out of your way. Streaming, calls, and browsing run at
full speed.

SIMPLE BY DESIGN
Open the app, pick a location, tap connect. No clutter and no dark
patterns. Your real IP address and your protected IP are shown side by
side, so you always know your status at a glance.

GLOBAL LOCATIONS
Connect through secure servers in the United States and Europe, with
more locations on the way.

WHY A VPN
A VPN encrypts the link between your device and the internet, so the
networks in between — public Wi-Fi, your mobile carrier, your ISP —
cannot read or profile your traffic. Lattice does that, and future-proofs
it against the next decade of threats.

Lattice VPN — privacy that holds up.

Questions or feedback: support@latticevpn.ai
Privacy policy: https://latticevpn.ai/privacy
```

### Listing metadata

| Field | Value |
|---|---|
| Category | Tools |
| Tags | security, privacy, VPN |
| Contact email | `support@latticevpn.ai` (required, public) |
| Website | `https://latticevpn.ai` |
| Privacy policy | `https://latticevpn.ai/privacy` (required) |
| Default language | English (United States) |

> Copy review: avoid absolute promises ("100% anonymous", "unhackable").
> Play rejects VPN listings that overclaim. The text above is written to
> stay on the safe side — keep it that way if you edit it.

---

## 2. Graphic assets

Produce these and upload them in the Console's **Store listing** section.

| Asset | Spec | Notes |
|---|---|---|
| App icon | 512 × 512 PNG, 32-bit with alpha | The Lattice shield. Export from the existing adaptive-icon source in `.icon-source/`. |
| Feature graphic | 1024 × 500 PNG or JPG, no alpha | Shown at the top of the listing. Lattice shield + wordmark on the brand navy, tagline optional. |
| Phone screenshots | 2–8 images, PNG/JPG, 9:16, 1080 × 1920 recommended | See shot list below. Minimum 2; 4–6 is ideal. |
| 7" tablet screenshots | optional, 1200 × 1920 | Skip unless you market to tablets. |

### Screenshot shot list

Capture on a device with `adb exec-out screencap -p > shotN.png`
(connected to a region so the "protected" state is real):

1. **Connect screen, disconnected** — the shield control + the "Your IP"
   panel showing the real IP and "Unprotected".
2. **Connect screen, connected** — "Protected", post-quantum active, the
   server IP shown. The hero shot.
3. **Region picker** — the four locations.
4. **Settings** — post-quantum status, always-on / kill-switch row.
5. *(optional)* A close-up of the post-quantum status / "Protected"
   badge to spotlight the differentiator.

Tip: add a one-line caption band to each screenshot in any image editor
("Post-quantum protection, on by default", "One tap to connect", etc.) —
plain raw screenshots convert worse, but this is optional.

---

## 3. Build the signed release

### One-time: create the upload keystore

```bash
cd clients/android
keytool -genkey -v -keystore lattice-release.jks \
    -keyalg RSA -keysize 4096 -validity 10000 -alias lattice
```

Answer the prompts and choose strong passwords. Then **back up
`lattice-release.jks` and the passwords somewhere safe** — if you lose
them you can never publish an update again. The file is gitignored
(`*.jks`); never commit it.

### One-time: fill in secrets.properties

Copy the template and add the keystore lines (see
`secrets.properties.example`):

```
RELEASE_STORE_FILE=lattice-release.jks
RELEASE_STORE_PASSWORD=<the store password you chose>
RELEASE_KEY_ALIAS=lattice
RELEASE_KEY_PASSWORD=<the key password you chose>
```

### Build + test the release, then bundle for upload

```bash
cd clients/android
export JAVA_HOME=/opt/homebrew/opt/openjdk@17

# 1. Build a signed release APK and TEST IT ON A DEVICE FIRST.
#    The release build is minified by R8 — bugs that never appear in
#    debug can appear here. Install it, connect, and confirm the
#    post-quantum rotation still works (logcat: "rotation #N succeeded").
./gradlew :app:assembleRelease
~/Library/Android/sdk/platform-tools/adb install -r \
    app/build/outputs/apk/release/app-release.apk

# 2. Once the release APK checks out, build the App Bundle to upload.
./gradlew :app:bundleRelease
# Output: app/build/outputs/bundle/release/app-release.aab
```

If the release APK crashes where the debug build worked, it is almost
certainly an R8 rule gap — `app/proguard-rules.pro` already keeps JNA,
the Rosenpass FFI, and the WireGuard JNI surface. As a quick fallback you
can set `isMinifyEnabled = false` in `app/build.gradle.kts`; the bundle
is larger but behaves exactly like the debug build.

Before each new upload, bump `versionCode` (and usually `versionName`) in
`app/build.gradle.kts`. For the first store release consider
`versionName = "1.0.0"`.

---

## 4. Play Console checklist

In order, in the Play Console:

1. **Create the app** — name "Lattice VPN", default language, "App",
   free/paid (see Decision 2).
2. **Store listing** — paste the copy from §1, upload the assets from §2.
3. **Privacy policy** — paste the hosted URL.
4. **App content / declarations:**
   - **Privacy policy URL** (again, under App content).
   - **Data safety form** — declare what the app collects. Per the
     privacy policy: a per-install identifier and the device's generated
     public keys are sent to provision a VPN peer; no traffic logs; no
     analytics/ads SDKs. Be precise — Play audits VPN apps.
   - **VPN / VpnService declaration** — the app uses Android's
     `VpnService`; declare it and confirm the VPN is the core function.
   - **Ads** — declare "No ads".
   - **Content rating** questionnaire — complete it (VPN tools rate
     "Everyone").
   - **Target audience** — adults; not directed at children.
5. **Release → Production** (or start with **Closed testing** — strongly
   recommended for a first launch) — upload `app-release.aab`.
6. **Countries / regions** — select where it ships.
7. Submit for review. First review typically takes a few days; VPN apps
   sometimes get extra scrutiny, so expect questions.

### Pre-submit sanity checks

- [ ] Release APK tested on-device: connects, and `rotation #N succeeded`
      keeps appearing in logcat (post-quantum still works after R8).
- [ ] `versionCode` is higher than any previous upload.
- [ ] Privacy policy is live at a public URL and linked in the Console.
- [ ] Data safety answers match the privacy policy exactly.
- [ ] Support email is monitored.
- [ ] Keystore + passwords backed up off-machine.

---

## Monetization & billing  (separate work item)

Decision: subscriptions are sold on **latticevpn.ai** via **Stripe**.
Getting there is a project in its own right — it is not a Play Console
setting, and none of the pieces exist yet.

### What Google Play allows

Google Play requires **Google Play Billing for digital purchases made
inside the app**, and an app may not show prices or link to an external
checkout from within the app. Selling on your own website is allowed —
the established pattern (Mullvad does exactly this; ExpressVPN does it
alongside Play Billing) is:

- the website (latticevpn.ai) sells the subscription via Stripe;
- the app stays **payment-silent** — no prices, no checkout links — and
  simply lets a customer **sign in / link the account** they bought on
  the web;
- the Play **listing** may mention the website.

Note: from 29 Oct 2025 Google relaxed external-payment rules for
developers serving US users. That change is US-specific and still
settling — verify current Play policy before relying on any in-app
external-payment link.

### What this requires — none of which exists yet

1. **App** — an account-link / sign-in screen. Today auth is headless
   (a per-install UUID + a shared bootstrap key), so there is no notion
   of "this install belongs to a paying customer". The app needs a way
   to enter and store an account credential issued after web checkout.
2. **Server** — provisioning must be gated on live subscription status.
   Today `server/scripts/cloak-api-server.py` provisions against the
   bootstrap key; the Stripe scaffold in `server/api/` (Go) is separate
   and not in the provisioning path. They must be connected, with the
   per-tier device limits from `docs/PRICING.md` enforced.
3. **Website** — the latticevpn.ai Stripe checkout must issue the
   account credential the app consumes. See `docs/STRIPE_SETUP.docx`.

This is the recommended next phase after the store listing ships.
