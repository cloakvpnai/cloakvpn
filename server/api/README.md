# cloakvpn-api

Small Go HTTP service that:

1. Receives **Stripe webhooks** and records who's paid, on which tier, and until when.
2. Exposes **`POST /v1/device`** so paying customers' apps can request a fresh WireGuard + Rosenpass config within their plan's device limit.
3. Exposes **`GET /v1/account?email=…`** for the apps to check subscription state.
4. Serves **`/healthz`** for uptime checks.

Designed to run on the same Hetzner CX22 as `wg` + `rosenpass`, behind Cloudflare. SQLite on disk, log output to journald (RAM-only via tmpfs per the server bootstrap), no request logs written to the filesystem.

## Layout

```
server/api/
├── main.go                       # wiring + graceful shutdown
├── go.mod
└── internal/
    ├── http/       http.go       # middleware + /v1/device + /v1/account + /healthz
    ├── stripe/     webhook.go    # Stripe event parsing + tier assignment
    ├── store/      store.go      # SQLite-backed accounts + devices
    ├── wg/         wg.go         # thin wrapper over `wg` + `wg-quick save`
    └── account/    doc.go        # Phase 1: magic-link auth (stub today)
```

## Config (env vars)

| Variable | Required | Example |
|---|---|---|
| `LISTEN_ADDR` | no (default `127.0.0.1:8080`) | `127.0.0.1:8080` |
| `DB_PATH` | no (default `/var/lib/cloakvpn/cloakvpn.db`) | `/var/lib/cloakvpn/cloakvpn.db` |
| `STRIPE_WEBHOOK_SECRET` | **yes** | `whsec_…` |
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

## Stripe setup checklist

1. Stripe Dashboard → **Product catalog** → create two Products:
   - `Cloak Basic` with prices: `$4.99 / month`, `$49.99 / year`.
   - `Cloak Pro` with prices: `$9.99 / month`, `$99.99 / year`.
2. Copy all four `price_…` IDs into `api.env`.
3. Stripe → **Developers → Webhooks → Add endpoint**:
   - URL: `https://api.cloakvpn.ai/v1/webhook/stripe`
   - Events: `checkout.session.completed`, `customer.subscription.updated`, `customer.subscription.deleted`.
   - Copy the `whsec_…` into `STRIPE_WEBHOOK_SECRET`.
4. Point `api.cloakvpn.ai` A/AAAA at the Hetzner box via Cloudflare (proxied orange cloud is fine — origin TLS handled by Caddy or `nginx` in front; cert provisioned automatically).

## What's intentionally stubbed

- `wg.Provision` mints WireGuard keys but the Rosenpass key-registration step is a placeholder. The real step is a small helper that generates a keypair with `rosenpass gen-keys`, appends a `[peer]` block to `/etc/rosenpass/rosenpass.conf`, and runs `systemctl reload rosenpass`.
- `internal/account` (magic-link auth) is a Phase 1 concern; Phase 0 trusts the email posted to `/v1/device`, and Stripe is the only way an email becomes paid.
- `DeviceHandler.revoke` is stubbed pending the magic-link flow.

## Smoke test (local, Stripe CLI)

```bash
stripe listen --forward-to localhost:8080/v1/webhook/stripe
stripe trigger checkout.session.completed
curl -s localhost:8080/healthz
```
