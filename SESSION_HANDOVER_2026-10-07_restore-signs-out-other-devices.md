# Session Handover — 2026-10-07 — Restore Purchases signed out the other devices

## Incident

iOS showed "Region select failed — That account number wasn't recognized" on
every region. Servers were healthy; Android worked because it uses a separate
(Stripe) account.

Root cause, from the API journal + DB + jp1 `wg show`:

- The iPhone's subscription is Apple account #14. At 2026-10-07 06:43:46 UTC
  (8:43 PM HST Oct 6) a **second Apple device** on the same Apple ID (home IP,
  new WireGuard key, device row 55) tapped Restore Purchases.
- `/v1/iap restore=true` re-minted the number and **replaced the only stored
  hash** (`UpdateAccountHashByAppleTxn`), silently invalidating the iPhone's
  number. The iPhone kept working on its cached jp1 config (last handshake
  2026-10-08 03:09 UTC over cellular) until it had to provision again, then
  every `POST /v1/device` returned 401 (sub-millisecond = auth reject).
- The same replace behavior existed for Google Play restores.

Diagnostic technique worth keeping: the API log has no status codes, but a
`POST /v1/device` that finishes in well under a millisecond is an auth reject;
a real provision takes 0.5 to 3 s. Match devices to people with
`wg show wg0 dump` on the region box (endpoint IP + last handshake per pubkey).

## Fix (branch `fix/account-number-restore`, 3 commits on top of f78da51)

Server (`server/api`):
- New table `account_number_aliases`. A restore makes the new number current
  and keeps the replaced one valid, capped at clamp(device_limit, 3, 10) live
  numbers per account (oldest pruned). HMAC only, no plaintext.
- `AccountByNumberHash` matches the current number or a live alias.
- "Unknown account" 401s carry `X-Lattice-Keeps-Previous-Numbers: 1`.
- `store.Open` now sets busy_timeout / foreign_keys / WAL in the DSN so they
  apply to every pooled connection (previously only the first), and uses
  `_txlock=immediate` so concurrent restores wait instead of SQLITE_BUSY.
- Tests: regression (fails on the old replace behavior), cap/prune, concurrent
  restores (fails without the immediate lock), pragmas per connection, HTTP
  401 header.

iOS (`clients/ios`):
- On a 401 that carries the header, silently redeem this device's App Store
  entitlement (no `AppStore.sync`, so no Apple ID prompt), adopt the number,
  retry provisioning once. Shared in-flight recovery, 60 s back-off after a
  failure, sign-out/sign-in races guarded.
- Otherwise: clear message + "Sign Out" button in the region alert, which
  leads to Restore Purchases / number entry.
- **NOT YET COMPILED**: the Mac mini's Xcode license is not accepted
  (`sudo xcodebuild -license accept`). Two code reviews found no compile
  issues, but build + device test before shipping.

## Deployed

- 2026-10-08 04:37 UTC: central API on us-west-1 (5.78.203.171) replaced with
  the branch build (sha256 prefix `dea917ca18f62dda`). Migration created
  `account_number_aliases`; integrity_check ok; 15 accounts / 21 devices.
- Backups: `/usr/local/bin/cloakvpn-api.bak-20261008`,
  `/var/lib/cloakvpn/cloakvpn.db.bak-20261008`.
- Verified live: `/healthz` 200; unknown number → 401 with the header.
- Rollback: `cp -p /usr/local/bin/cloakvpn-api.bak-20261008 /usr/local/bin/cloakvpn-api && systemctl restart cloakvpn-api`
  (the alias table is additive; the old binary ignores it).
- Note: the deployed binary before this was the 2026-06-15 build; the
  2026-06-17 `wg.go` IPv6 change only affects `regionsvc`, not the central API.

## Still open

- Fix the iPhone: Account → Sign out → Restore Purchases (safe now; the other
  device keeps working).
- Compile + test the iOS change, ship a build. Server is already compatible.
- Push the branch to GitHub (no GitHub access from the Claude session).
- Revocation gap (from review): no endpoint to "sign out other devices" and
  aliases never expire. Add an authenticated rotate endpoint.
- iCloud Keychain sync of the account number is not implemented (the old
  StoreManager comment claimed it was); that is why a second device needs a
  restore at all.
- API request log has no status codes.
- Earlier list: `fleet-health.sh` `ENJ` typo; uncommitted work on the Mac
  clone (incl. deleted Mac Xcode project); rotate the committed
  `GOOGLE_PLAY_NOTIFICATION_SECRET`; verify a Play renewal via RTDN; delete the
  `recheck-googleplay-grant` scheduled task; revoke the Cloudflare API token.
