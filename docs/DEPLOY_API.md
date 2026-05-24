# Deploying cloakvpn-api — deploy + test runbook

How to get the `cloakvpn-api` billing/provisioning service (`server/api/`)
running on one concentrator and verify the whole chain — **test payment →
account number → provisioned config** — before the apps are built on top.

Do this in Stripe **Test mode**. One region is enough to validate; the
multi-region rollout is `BILLING_INTEGRATION.md` §7, later.

---

## 0. Prerequisites

- **Go 1.25+** on your Mac to build the binary (https://go.dev/dl/).
- SSH to one concentrator — pick any of the four. DNS is inconsistent,
  so SSH by IP:

  | Region    | IP             | API host                    |
  |-----------|----------------|-----------------------------|
  | us-west-1 | 5.78.203.171   | cloak-us-west-1.cloakvpn.ai |
  | us-east-1 | 5.161.198.227  | cloak-us-east-1.cloakvpn.ai |
  | de1       | 91.98.65.98    | cloak-de1.cloakvpn.ai       |
  | fi1       | 204.168.252.70 | cloak-fi1.cloakvpn.ai       |

  `ssh -i ~/.ssh/cloakvpn_ed25519 root@<ip>`
- That box already runs WireGuard + `cloak-rosenpass` (it's a live
  concentrator).
- The **Stripe CLI** — it bridges Stripe's test webhooks without needing
  DNS/TLS yet. Installed in step 4.
- Stripe Phase 1 done: the four products/prices exist, and you have the
  four `price_…` IDs and your test **secret key** (`sk_test_…`, from
  Dashboard → Developers → API keys).

---

## 1. Build the binary (on your Mac)

`cloakvpn-api` is pure Go (no CGO), so it cross-compiles cleanly:

```bash
cd server/api          # from the repo root
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
  go build -trimpath -ldflags="-s -w" -o cloakvpn-api .
```

Hetzner CX-series boxes are x86-64, hence `GOARCH=amd64`.

Copy it to the box. `scp` straight onto `/usr/local/bin/cloakvpn-api`
works only on the *first* deploy — once the service is running, Linux
refuses to overwrite a file that is currently executing (`scp: dest
open … Failure`, errno `ETXTBSY`). So always copy to a temporary name
and `mv` it into place; a rename swaps the binary atomically, with no
downtime, even while the old one is still running:

```bash
scp -i ~/.ssh/cloakvpn_ed25519 cloakvpn-api root@<ip>:/usr/local/bin/cloakvpn-api.new
ssh -i ~/.ssh/cloakvpn_ed25519 root@<ip> \
  'mv /usr/local/bin/cloakvpn-api.new /usr/local/bin/cloakvpn-api && chmod 755 /usr/local/bin/cloakvpn-api'
```

On a redeploy, follow this with `systemctl restart cloakvpn-api`.

---

## 2. Secrets + the env file (on the box)

Generate the account-number HMAC secret **once** — keep it forever; if it
ever changes, every existing account number stops validating:

```bash
openssl rand -hex 32          # this is ACCOUNT_NUMBER_SECRET
```

Create `/etc/cloakvpn/api.env`, root-owned, mode `0600`:

```bash
mkdir -p /etc/cloakvpn
cat > /etc/cloakvpn/api.env <<'ENV'
LISTEN_ADDR=127.0.0.1:8080
DB_PATH=/var/lib/cloakvpn/cloakvpn.db

STRIPE_SECRET_KEY=sk_test_…
STRIPE_WEBHOOK_SECRET=whsec_…            # filled in step 4
ACCOUNT_NUMBER_SECRET=…                  # the openssl value above
STRIPE_PRICE_BASIC_MONTH=price_…
STRIPE_PRICE_BASIC_YEAR=price_…
STRIPE_PRICE_PRO_MONTH=price_…
STRIPE_PRICE_PRO_YEAR=price_…

WG_IFACE=wg0
WG_SERVER_PUB=…                          # cat /etc/wireguard/server.pub
WG_ENDPOINT=<this region host>:51820
WG_DNS=10.99.0.1
WG_ALLOWED_IPS=0.0.0.0/0, ::/0
WG_SUBNET=10.99.0.0/24
ENV
chmod 600 /etc/cloakvpn/api.env
```

---

## 3. systemd unit (on the box)

The API shells out to `wg` / `wg-quick`, writes `/etc/rosenpass`, and
restarts `cloak-rosenpass.service` — so on this single-purpose box it
runs as **root**. Create `/etc/systemd/system/cloakvpn-api.service`:

```ini
[Unit]
Description=Lattice VPN API (cloakvpn-api)
After=network-online.target wg-quick@wg0.service cloak-rosenpass.service
Wants=network-online.target

[Service]
EnvironmentFile=/etc/cloakvpn/api.env
ExecStart=/usr/local/bin/cloakvpn-api
StateDirectory=cloakvpn
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

`StateDirectory=cloakvpn` creates `/var/lib/cloakvpn` for the SQLite DB.
Then:

```bash
systemctl daemon-reload
systemctl enable --now cloakvpn-api.service
curl -s localhost:8080/healthz        # → {"ok":true}
journalctl -u cloakvpn-api -f         # watch logs in another shell
```

(`STRIPE_WEBHOOK_SECRET` is still a placeholder — the service will run;
the webhook just won't verify until step 4.)

---

## 4. Bridge the Stripe test webhook (Stripe CLI)

You don't need DNS or TLS to test — the Stripe CLI relays test events.
**Recommended: run it on your Mac**, not the concentrator (no reason to
add dev tooling to a live VPN box).

On your Mac:

```bash
brew install stripe/stripe-cli/stripe
```

Open an SSH tunnel so the Mac's `localhost:8080` reaches the box's API,
and leave it open:

```bash
ssh -i ~/.ssh/cloakvpn_ed25519 -L 8080:localhost:8080 root@<ip>
```

In a second Mac terminal:

```bash
stripe login    # prints a pairing code + URL — open it in a browser
stripe listen --forward-to localhost:8080/v1/webhook/stripe
```

*Alternative — install on the box (Ubuntu) instead:*

```bash
apt update && apt install -y curl gnupg
curl -fsSL https://packages.stripe.dev/api/security/keypair/stripe-cli-gpg/public \
  | gpg --dearmor -o /usr/share/keyrings/stripe.gpg
echo "deb [signed-by=/usr/share/keyrings/stripe.gpg] https://packages.stripe.dev/stripe-cli-debian-local stable main" \
  > /etc/apt/sources.list.d/stripe.list
apt update && apt install -y stripe
```

Either way, `stripe listen` prints its own signing secret (`whsec_…`).
Put **that** value into `STRIPE_WEBHOOK_SECRET` in
`/etc/cloakvpn/api.env`, then:

```bash
systemctl restart cloakvpn-api.service
```

Leave `stripe listen` running for the test.

---

## 5. End-to-end test

### 5a. A real test-mode checkout

Open one of your Stripe Payment Links, pay with test card
`4242 4242 4242 4242` (any future expiry, any CVC, any postcode). Stripe
redirects to `/welcome?session_id=cs_test_…` — **note that `cs_test_…`
session id.**

In the logs you should see:

```
checkout.session.completed: account created (tier=…) for customer cus_…
```

### 5b. Verify the account was created

```bash
apt-get install -y sqlite3   # if not present
sqlite3 /var/lib/cloakvpn/cloakvpn.db \
  'SELECT tier, device_limit, active_until FROM accounts;'
```

One row, with the tier you bought. The DB stores **no email** — only the
account-number hash.

### 5c. Verify the account number

```bash
curl -s "localhost:8080/v1/account-number?session_id=cs_test_…"
# → {"account_number":"XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"}
```

Cross-check: Stripe Dashboard → Customers → that customer → Metadata →
`lattice_account_number` should hold the same value. Save the number for
the next steps.

### 5d. Verify account lookup

```bash
curl -s localhost:8080/v1/account \
  -H "Authorization: Bearer XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
# → {"tier":"…","device_limit":…,"device_count":0,"active_until":"…","devices":[]}
```

### 5e. Verify provisioning (optional — registers a real peer)

This exercises `/v1/device` with a client-style keypair. It adds a real
wg peer and restarts `cloak-rosenpass` (a brief PSK-rotation blip for
other peers), so do it on a test box or off-peak.

```bash
WG_PUB=$(wg genkey | tee /tmp/t.sk | wg pubkey)
rosenpass gen-keys --secret-key /tmp/t.rp.sk --public-key /tmp/t.rp.pk
RP_PUB=$(base64 -w0 /tmp/t.rp.pk)

# The Rosenpass public key is ~700 KB base64 — too large to pass on the
# curl command line (you'd get "Argument list too long"). Write the JSON
# body to a file and POST it with --data-binary @file instead.
printf '{"wg_pubkey":"%s","rosenpass_pubkey":"%s"}' "$WG_PUB" "$RP_PUB" > /tmp/dev.json
curl -s -X POST localhost:8080/v1/device \
  -H "Authorization: Bearer XXXXX-XXXXX-XXXXX-XXXXX-XXXXX" \
  --data-binary @/tmp/dev.json
# → {"config":{…},"tier":"…","device":{…}}

wg show wg0        # the new peer's pubkey + 10.99.0.x should appear
```

To clean it up afterwards: `DELETE /v1/device?id=<device id>` with the
same `Authorization` header (the id is in the `device` field above), or
`sqlite3 … 'DELETE FROM devices;'` + `wg set wg0 peer $WG_PUB remove`.

### Test checklist

- [ ] `/healthz` returns ok
- [ ] checkout → log line "account created"
- [ ] `accounts` row exists, correct tier
- [ ] `/v1/account-number` returns the number; matches Stripe metadata
- [ ] `/v1/account` returns the subscription state
- [ ] *(optional)* `/v1/device` returns a config and adds a wg peer

If all of that passes, the backend is proven — the apps (Phase 4) can be
built on it with confidence.

---

## 6. Going to production

For real traffic (not just the Stripe CLI bridge):

1. Point `api.latticevpn.ai` (DNS, via Cloudflare) at the concentrator.
2. Put a TLS reverse proxy in front — Caddy is simplest (automatic
   certificates): proxy `https://api.latticevpn.ai` → `127.0.0.1:8080`.
3. In the Stripe Dashboard create the real webhook endpoint
   (`https://api.latticevpn.ai/v1/webhook/stripe`, the three events from
   `STRIPE_SETUP.md` step 5) and put its `whsec_…` in `api.env`.
4. When you flip Stripe to **Live mode**, redo with the live `sk_…`,
   `whsec_…`, and `price_…` values.
5. Multi-region: deciding how one central API provisions across all four
   concentrators is `BILLING_INTEGRATION.md` §7 — settle that before the
   full production rollout.
