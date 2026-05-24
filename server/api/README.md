# cloakvpn-api

Small Go HTTP service that:

1. Receives **Stripe webhooks** and, on checkout, mints a random **account number** — the customer's only credential, no email/password accounts — recording the tier, device limit, and expiry.
2. Exposes **`POST /v1/device`** so a customer's app can request a fresh WireGuard + Rosenpass config within their device limit, and **`DELETE /v1/device?id=`** to free a slot.
3. Exposes **`GET /v1/account`** for the app to check subscription state. Both `/v1/device` and `/v1/account` are authed by the account number (`Authorization: Bearer <account-number>`).
4. Exposes **`GET /v1/account-number?session_id=…`** for the website welcome page, and **`/healthz`** for uptime checks.

Designed to run on the same Hetzner CX22 as `wg` + `rosenpass`, behind Cloudflare. SQLite on disk, log output to journald (RAM-only via tmpfs per the server bootstrap), no request logs written to the filesystem.

## Layout

```
server/api/
├── main.go                       # wiring + graceful shutdown
├── go.mod
└── internal/
    ├── http/       http.go       # middleware + /v1/device + /v1/account + /v1/account-number
    ├── stripe/     webhook.go    # Stripe event parsing + account-number minting
    ├── store/      store.go      # SQLite-backed accounts + devices
    ├── wg/         wg.go         # thin wrapper over `wg` + `wg-quick save`
    └── account/    account.go    # account-number generation + HMAC hashing
```

## Config (env vars)

| Variable | Required | Example |
|---|---|---|
| `LISTEN_ADDR` | no (default `127.0.0.1:8080`) | `127.0.0.1:8080` |
| `DB_PATH` | no (default `/var/lib/cloakvpn/cloakvpn.db`) | `/var/lib/cloakvpn/cloakvpn.db` |
| `STRIPE_WEBHOOK_SECRET` | **yes** | `whsec_…` (verifies webhook signatures) |
| `STRIPE_SECRET_KEY` | **yes** | `sk_…` (writes/reads the account number in Stripe customer metadata) |
| `ACCOUNT_NUMBER_SECRET` | **yes** | long random string — keys the HMAC of account numbers |
| `STRIPE_PRICE_BASIC_MONTH` | **yes** | `price_…` |
| `STRIPE_PRICE_BASIC_YEAR`  | **yes** | `price_…` |
| `STRIPE_PRICE_PRO_MONTH`   | **yes** | `price_…` |
| `STRIPE_PRICE_PRO_YEAR`    | **yes** | `price_…` |
| `WG_SERVER_PUB` | **yes** | server's WireGuard public key |
| `WG_ENDPOINT`   | **yes** | `fi1.cloakvpn.ai:51820` |
| `WG_IFACE`      | no (default `wg0`) | `wg0` |
| `WG_DNS`        | no (default `10.99.0.1`) | `10.99.0.1` |
| `WG_ALLOWED_IPS`| no (default `0.0.0.0/0, ::/0`) | `0.0.0.0/0, ::/0` |
| `WG_SUBNET`     | no (default `10.99.0.0/24`) | `10.99.0.0/24` |

## Build & run (server)

```bash
cd server/api
go build -trimpath -ldflags="-s -w" -o /usr/local/bin/cloakvpn-api .

# systemd unit (place at /etc/systemd/system/cloakvpn-api.service):
```

```ini
[Unit]
Description=Cloak VPN API
After=network-online.target wg-quick@wg0.service rosenpass.service
Wants=network-online.target

[Service]
EnvironmentFile=/etc/cloakvpn/api.env
ExecStart=/usr/local/bin/cloakvpn-api
DynamicUser=yes
StateDirectory=cloakvpn
# The API needs to shell out to `wg` + `wg-quick`. Those live in root's PATH.
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/cloakvpn /etc/wireguard
PrivateTmp=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

`/etc/cloakvpn/api.env` holds the Stripe + WG env vars. Keep it `chmod 600 root:root`.

## Stripe setup

See **`docs/STRIPE_SETUP.md`** for the full runbook (products, payment
links, webhook, env vars). In brief: create the four Lattice VPN prices,
copy the `price_…` IDs, the `whsec_…`, and the `sk_…` into `api.env`, and
point the webhook at `https://api.latticevpn.ai/v1/webhook/stripe`.

## Status

The no-account billing path is implemented and compiles clean
(`go build ./...`, `go vet`):

- the Stripe webhook mints a random account number on checkout and
  writes it into the Stripe customer metadata for recovery;
- `/v1/device`, `/v1/account`, and `DeviceHandler.revoke` are authed by
  the account number; `/v1/account-number` backs the website welcome page;
- `wg.Provision` fully registers the Rosenpass peer (`gen-keys` →
  `server.toml` → service restart).

Not yet done: deploying this as the live provisioning path (today the
Python `server/scripts/cloak-api-server.py` is live), and the
multi-region topology — see `docs/BILLING_INTEGRATION.md` §7.

## Smoke test (local, Stripe CLI)

```bash
stripe listen --forward-to localhost:8080/v1/webhook/stripe
stripe trigger checkout.session.completed
curl -s localhost:8080/healthz
```
