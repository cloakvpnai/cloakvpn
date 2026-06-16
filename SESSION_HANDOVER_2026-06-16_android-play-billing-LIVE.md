# Session Handover — 2026-06-16 — 🎉 Android Google Play Billing LIVE end-to-end

Follows `SESSION_HANDOVER_2026-06-15_android-play-billing.md` (which covered the
code build). This doc covers the **go-live**: deploy, Play/GCP setup, the
service-account saga, production promotion, and RTDN.

## Headline
Google Play in-app subscriptions are **fully working** on Android. A real
customer completed a purchase: server verified the token, minted an account
number, signed them in. Production rollout of **v1.0.2 (versionCode 4)** is
submitted and rolling out (pending Google review). RTDN is live (test ping
confirmed). Web/Stripe billing unaffected; dual billing as designed.

## What shipped / changed this session

### Server (cloakvpn-api on us-west-1 = 5.78.203.171, behind api.latticevpn.ai)
- Deployed the **v2 binary** with the `googleplay` package. Atomic swap; backup
  at `/usr/local/bin/cloakvpn-api.bak-20260615`. Health OK, logs show
  `google play billing enabled (package ai.latticevpn.android)`.
- Linux build artifact (if a redeploy is needed):
  `server/api/dist/cloakvpn-api-v2-googleplay` (static amd64). Rebuild with
  `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w"`.
- **Env added** to `/etc/cloakvpn/api.env` (root, 0600):
  - `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON=/etc/cloakvpn/play-service-account.json`
  - `GOOGLE_PLAY_PACKAGE_NAME=ai.latticevpn.android`
  - `GOOGLE_PLAY_NOTIFICATION_SECRET=336059bce39ed9e3716737e47049ecdab5638085f610744e`
  - (Product IDs left at defaults `basic`/`pro`.)
- **Service-account key** installed at `/etc/cloakvpn/play-service-account.json`
  (root, 0600). NOT in git. Email:
  `lattice-play-billing@lattice-vpn.iam.gserviceaccount.com` (GCP project
  `lattice-vpn`).
- DB auto-migrated (Migration 4: `google_play_purchase_token`) on boot.

### Google Cloud (project `lattice-vpn`, in org neuroaistudios.com)
- Enabled **Google Play Android Developer API**.
- Created service account `lattice-play-billing` + JSON key.
- **Two org-policy overrides were required** (scoped to the `lattice-vpn`
  project; user granted themselves *Organization Policy Administrator* to do
  them):
  1. `iam.disableServiceAccountKeyCreation` → **Off** (to download the SA key).
  2. `iam.allowedPolicyMemberDomains` (Domain restricted sharing) → **Allow
     all** (to grant Google's publisher SA on the Pub/Sub topic).
- **Pub/Sub** topic `play-rtdn`; granted
  `google-play-developer-notifications@system.gserviceaccount.com` the
  **Pub/Sub Publisher** role on it; created **push** subscription
  `play-rtdn-push` → endpoint
  `https://api.latticevpn.ai/v1/googleplay/notifications?token=<NOTIFICATION_SECRET>`.

### Play Console (developer 5806528867291868951, app 4974426127600924727)
- Created subscriptions **`basic`** (monthly $4.99 / yearly $49.99) and
  **`pro`** (monthly $9.99 / yearly $99.99), base plans `monthly`/`yearly`,
  all **Active**.
- Granted the service account in **Users & permissions**: *View financial data,
  orders, and cancellation survey responses* + *Manage orders and
  subscriptions* (account-level).
- **Monetization setup → Real-time developer notifications** → topic
  `projects/lattice-vpn/topics/play-rtdn`. Test ping confirmed in server logs.
- Uploaded **v1.0.2 / versionCode 4** to Internal testing, then **promoted to
  Production** (full rollout, sent for review; managed publishing off → auto-
  publishes on approval).

## Gotcha that cost the most time (note for future)
After granting the service account in Play Console, the Developer API returned
`401 permissionDenied` for **~9 hours** before activating. Per Google's docs the
config was correct the whole time; a brand-new SA "may take up to 24h" to
activate. A clean **remove + re-invite** of the SA in Users & permissions
preceded it clearing. Lesson: this delay is normal/Google-side — don't churn the
config; just wait (and a re-invite can help). The diagnostic that proved it was
ready: a fake purchase token flips from `permissionDenied` to
`"Invalid Value"/"invalid"`.

## Commits
- `180d306` — Android bump to versionCode 4 / 1.0.2 for the Play Billing build.
- `864a1ef` — (prev session) Google Play Billing code (client + server).

## Still open / next
- **Production review**: v1.0.2 rolling out once Google approves (auto-publish).
- **Verify a renewal** lands via RTDN at the first monthly cycle (watch for
  `googleplay notification type=2 ... refreshed` in logs).
- **Disable/delete** the `recheck-googleplay-grant` scheduled task (it errored
  on the Fable-5 model and is no longer needed).
- iOS carry-overs unchanged: PQC re-provision loop; iCloud Keychain restore.

## Quick reference
- Re-test billing reachability (should NOT say permissionDenied):
  `curl -s -X POST https://api.latticevpn.ai/v1/googleplay -H 'content-type: application/json' -d '{"purchase_token":"x","restore":false}'`
  → expect HTTP 400 `invalid purchase` (server log shows `"Invalid Value"`).
- Server logs: `ssh -i ~/.ssh/cloakvpn_ed25519 root@5.78.203.171 'journalctl -u cloakvpn-api -f'`
- Endpoints: `POST /v1/googleplay` (verify+mint), `POST /v1/googleplay/notifications?token=…` (RTDN).
