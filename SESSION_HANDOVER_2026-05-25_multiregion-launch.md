# Session Handover — 2026-05-25 — Multi-region launch

Handoff for a fresh chat. Read this top to bottom before doing anything.

---

## TL;DR — where things stand

| Area | Status |
|------|--------|
| Multi-region backend (10 concentrators) | **DONE** — deployed and verified end-to-end |
| Central API (`cloakvpn-api`, region-aware) | **DONE** — live on us-west-1 |
| Stripe billing (4 plans) | **DONE** — all 4 price IDs verified |
| Website recovery messaging | **DONE** — committed (deploys on `git push`) |
| **Android app** | Code **DONE** (10-region picker). **Needs rebuild + Play submission** ← next task |
| **iOS app** | Code **DONE**, builds clean in Xcode. **BLOCKED on Apple** (see below) |

**Immediate next task for the new chat: rebuild and ship the Android app.**

---

## What was accomplished today

### 1. Multi-region backend — the headline work

The project went from one concentrator to **ten**. Architecture (see
`docs/BILLING_INTEGRATION.md` §7, `docs/DEPLOY_MULTIREGION.md`):

- One central **`cloakvpn-api`** on us-west-1 owns accounts, billing, the
  SQLite DB. It no longer drives WireGuard directly.
- Every one of the 10 boxes runs **`regionsvc`** — a small authenticated
  HTTP service that adds/removes the WireGuard + Rosenpass peer on its own
  box.
- On `POST /v1/device {region}`, the central API validates the
  subscription, allocates an IP, and calls that region's `regionsvc`.
- One active region per device; switching region revokes the old peer and
  re-provisions on the new box.

Done today: built the region-aware `cloakvpn-api` + `regionsvc`,
cross-compiled both (`linux/amd64`), deployed `regionsvc` to all 10 boxes
with Caddy + TLS fronting the 9 remote ones, deployed the new central API
on us-west-1, wrote `regions.json`. **End-to-end test: a device
provisioned successfully into all 10 regions — HTTP 200 across the board.**

### 2. The 10 regions

| id | location | provider | IP | regionsvc hostname |
|----|----------|----------|-----|--------------------|
| us-west-1 | Oregon | Hetzner | 5.78.203.171 | *central box — loopback* |
| us-east-1 | Virginia | Hetzner | 5.161.198.227 | rgn-us-east-1.latticevpn.ai |
| us-central-1 | Dallas | Vultr | 207.148.1.253 | rgn-us-central-1.latticevpn.ai |
| de1 | Germany | Hetzner | 91.98.65.98 | rgn-de1.latticevpn.ai |
| fi1 | Finland | Hetzner | 204.168.252.70 | rgn-fi1.latticevpn.ai |
| es1 | Madrid | Vultr | 65.20.99.121 | rgn-es1.latticevpn.ai |
| mx1 | Mexico City | Vultr | 216.238.95.21 | rgn-mx1.latticevpn.ai |
| za1 | Johannesburg | Vultr | 139.84.248.50 | rgn-za1.latticevpn.ai |
| in1 | Mumbai | Vultr | 65.20.77.179 | rgn-in1.latticevpn.ai |
| jp1 | Tokyo | Vultr | 167.179.75.10 | rgn-jp1.latticevpn.ai |

All 10 run `wg-quick@wg0` + `cloak-rosenpass` + `regionsvc` (`active`).
The 9 remote boxes have Caddy serving TLS for their `rgn-*` hostname.

### 3. Stripe billing fix

The Pro-Monthly Payment Link charged a price ID that wasn't in `api.env`,
so the webhook silently ignored purchases. Fixed `STRIPE_PRICE_PRO_MONTH`,
then verified **all four** Payment Link price IDs match `api.env`:

- Basic Monthly `price_1Tai1UG6CrlPVbxShEuSYwVM`
- Basic Yearly `price_1Tai6EG6CrlPVbxSI8YkhtAs`
- Pro Monthly `price_1Tai7pG6CrlPVbxSUx8RvsPF`
- Pro Yearly `price_1Tai9sG6CrlPVbxSihcmhvm5`

### 4. Website

`welcome.astro` and `recover.astro`: corrected the account-number
recovery messaging (the invoice-footer copy only lands on *renewal*
receipts, not the first one). Deploys automatically on `git push`.

### 5. Android app

Region picker re-expanded from 1 to all 10 regions; it now sends the
chosen `region` on `POST /v1/device`; added a cache-invalidation fix so a
region switch can't serve a stale config. Code complete, committed.

### 6. iOS app — full account-number migration

The iOS app was still on the *old* architecture (per-region
cloak-api-server, JWT/bootstrap-key auth, **StoreKit in-app purchase**).
Migrated it to the account-number model so it matches Android and the
website (sold on latticevpn.ai, payment-silent app — see
`BILLING_INTEGRATION.md` §9):

- New: `LatticeAPI.swift`, `LatticeAccountClient.swift`,
  `AccountEntryView.swift` (full-screen account-number sign-in).
- Rewrote `TunnelManager` (account state + region-aware provisioning),
  `Region.swift` (10 regions), `ContentView` (sign-in gate, account
  screen), `AppGroupKeyStore`, `SubscriptionInfo`, `CloakVPNApp`.
- Removed StoreKit entirely (`StoreKitManager`, `PaywallView`,
  `CloakAuthClient`, `Lattice.storekit` deleted).
- **Builds clean in Xcode** and passed an independent code review.

---

## Next steps

### IMMEDIATE — rebuild and ship the Android app

The Android code is done (commit `1bd2003`). The new chat should:

1. Open `clients/android/` in Android Studio (or build via
   `./gradlew assembleRelease` from `clients/android/`).
2. Build a release APK/AAB. Note: signing config / keystore is the
   user's — check `clients/android/` for the existing release setup.
3. Install on a device, sign in with the user's **test account number**
   (the Pro subscription created today — the user has it; it is NOT
   written in this doc on purpose).
4. Test: account-number sign-in → region picker shows all 10 → connect →
   switch regions.
5. Ship to Google Play (internal testing track first is sensible).

Android is **not** affected by the Apple problem below — it can launch
independently.

### iOS — BLOCKED ON APPLE, do not attempt to ship yet

The iOS app is finished and builds. It **cannot be signed, device-tested,
or submitted** because the user's Apple Developer membership is mid
**migration from an individual account to an organization**, and Apple
temporarily disables all membership benefits (certificate + provisioning
access) during that. Xcode shows it as a red "Unknown Name" team.

This is an Apple-side wait — typically days, up to ~2 weeks. When Apple
restores benefits:

1. Xcode → Settings → Accounts → remove and re-add the Apple ID to
   re-sync.
2. The team `5HYY2YP2G9` will resolve to its real name; the red clears.
3. Run on a device, test the sign-in → connect → region-switch flow.
4. Archive → upload to App Store Connect → submit for review.

Nothing in the iOS code needs to change. The team ID stays the same
through an org migration.

### Pre-launch checklist (before real customers)

- One clean test purchase end-to-end, **watching the `/welcome` page
  actually display the account number** (today's purchase failed before
  the account existed, so the happy path is unproven by eye).
- Cancel the test subscription(s) and remove test device rows from the
  account once testing is done.

---

## Known issues / things to watch

- **Rosenpass restart rate-limit (scaling).** Every device provision
  restarts `cloak-rosenpass` on the target box. systemd's default limit
  is 5 starts / 10s. Under heavy concurrent provisioning into one region,
  provisions past the 5th in a 10s window will 500. With normal traffic
  spread across 10 regions this is unlikely, but it *will* bite at scale.
  Worth doing before heavy launch volume: raise `StartLimitBurst` /
  `StartLimitIntervalSec` on `cloak-rosenpass` across all 10 boxes, or
  move away from restart-per-provision. (The user has explicitly raised
  scaling worries — take this seriously.)
- **Welcome page first receipt.** The account number on the Stripe
  invoice footer only appears on *renewal* invoices, not the first.
  Messaging is now honest; the welcome page itself is the primary
  delivery.

---

## Gotchas hit today (so the next chat doesn't repeat them)

- **`scp` from the wrong directory fails silently** — the new
  `cloakvpn-api` binary appeared "deployed" but wasn't, because an `scp`
  ran outside the repo folder. Always sha256-verify a deployed binary.
- **`ssh` inside a bash `for` loop swallows stdin** — only the first
  iteration produced output. Use `ssh -n` in loops.
- **Stripe Payment Link price IDs must exactly match `api.env`** — a
  mismatch makes the webhook silently ignore the purchase. Bit us twice.

---

## Reference

- Multi-region deploy runbook: `docs/DEPLOY_MULTIREGION.md`
- Billing/architecture: `docs/BILLING_INTEGRATION.md`
- Deploy binaries `server/api/cloakvpn-api` and `server/api/regionsvc`
  are gitignored build artifacts; the Go source is committed. Rebuild
  with `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build`.
- Secrets (`REGION_INTERNAL_SECRET`, Stripe keys, `ACCOUNT_NUMBER_SECRET`)
  live only in `/etc/cloakvpn/*.env` on the boxes (mode 0600) and the
  user's password manager — never in the repo, never in chat.

### Commits made today (newest first)

```
a4f3418 ios: remove the retired StoreKit / bootstrap-auth files
f47001d website: correct the account-number recovery messaging
4891135 ios: harden account-status JSON int decoding (NSNumber.intValue)
e36ebf0 ios: migrate to the account-number model (retire StoreKit)
1bd2003 android: re-expand region picker to all 10 regions
8856005 cloakvpn-api: make the central API region-aware (multi-region §7)
58b2b5f docs: add Android launch plan
79a5d98 add regionsvc — per-region provisioning service (multi-region §7)
```

Run `git push` to back these up to GitHub.
