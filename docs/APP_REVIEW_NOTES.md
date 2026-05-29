# App Review Notes — Lattice VPN

Reusable reviewer-facing notes + test credentials for **both** App Store
Connect (iOS App Review notes field) and Google Play (App content → App
access form). Keep the account number out of git — fill it in only in the
store consoles, not here. The `[ACCOUNT NUMBER]` placeholder below stays a
placeholder in this file.

---

## Test credentials (do NOT commit the real number)

- **Reviewer account email:** `appreview@kryptoknightz.com` (dedicated)
- **Account number:** `[ACCOUNT NUMBER]` — get by subscribing the reviewer
  email to Lattice Pro on https://latticevpn.ai/pricing, then store the
  number in the password manager. Paste it into the store consoles only.
- **Subscription:** Lattice Basic (active). Tier controls device count only,
  not region access — all server regions are reachable on Basic.
- **Use the same number for App Store *and* Play** so both stores are covered.

---

## iOS — App Store Connect "App Review Information → Notes"

Lattice VPN uses an account-number authentication model (no email, no
password), the same approach as Mullvad VPN. There is nothing to "sign up"
for inside the app.

To sign in for review:

1. Launch the app and tap "I already have an account."
2. Enter this account number: [ACCOUNT NUMBER]
3. Tap Connect to establish the VPN tunnel.

This account has an active Lattice Basic subscription with full access to
the server regions. Subscriptions are handled on our website
(latticevpn.ai) via Stripe, not through in-app purchase — Lattice is a free
download, consistent with the Mullvad / Proton / ExpressVPN model.

The app uses Apple's NetworkExtension framework (Packet Tunnel Provider) for
the VPN, per Guideline 5.4. No data is logged; see latticevpn.ai/privacy.

Note: this app was previously submitted (Build 102) under an individual
developer account and rejected under Guideline 5.4. The account has since
migrated to an organization account (KryptoKnightz LLC, Team ID
5HYY2YP2G9), which resolves that issue.

---

## Android — Google Play "App content → App access"

Select: "All or some functionality is restricted" → add instructions:

Lattice VPN uses account-number authentication (no email, no password),
like Mullvad VPN.

1. Open the app and tap "I already have an account."
2. Enter account number: [ACCOUNT NUMBER]
3. Tap Connect.

This account has an active Lattice Basic subscription (all server regions
reachable — tier affects device count only). Subscriptions are purchased on
latticevpn.ai via Stripe (free app, web billing — Mullvad / Proton model),
not via Google Play billing.

---

## Maintenance

- Rotate the reviewer account number if it ever appears in a screenshot or
  leaks; account number IS the auth credential.
- Keep the Guideline 5.4 paragraph in the iOS notes until the first build
  is approved under the org account, then it can be dropped.
- If the reviewer subscription lapses, resubscribe before any resubmission —
  a reviewer hitting an expired account = Guideline 2.1 rejection.
