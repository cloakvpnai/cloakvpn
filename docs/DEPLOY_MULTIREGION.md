# Deploying the multi-region stack — runbook

How to take Lattice VPN from one concentrator to **ten**, with one central
billing API and a per-region provisioning service on every box.

This is the production form of `BILLING_INTEGRATION.md` §7, now confirmed
and built. Read that section first if you want the *why*; this doc is the
*how*.

---

## 1. The topology

```
          apps  ──►  api.latticevpn.ai            (central cloakvpn-api)
                          │   us-west-1 only — owns accounts, billing, DB
                          │
            POST /v1/device {region: "jp1"}
                          │
                          ▼
        ┌─────────────────┴───────────────────────────┐
        │   central API calls the chosen region's      │
        │   regionsvc over an authenticated channel    │
        └──────────────────────────────────────────────┘
                          │
   ┌──────┬──────┬────────┼────────┬──────┬──────┬──────┬──────┐
   ▼      ▼      ▼        ▼        ▼      ▼      ▼      ▼      ▼
 us-west us-east us-cent  de1     fi1    es1    mx1    za1    in1   jp1
 (local)  └────────── regionsvc on each box, :8090 ──────────────┘
```

- **`cloakvpn-api`** runs on **us-west-1 only**. It owns the SQLite DB,
  Stripe billing, account numbers, and the device limit. The apps talk to
  nothing else.
- **`regionsvc`** runs on **all ten boxes**. It is a thin authenticated
  wrapper around `wg.Controller` — it adds/removes the WireGuard +
  Rosenpass peer on *its own* box and nothing more. No accounts, no DB.
- When an app calls `POST /v1/device` with a `region`, the central API
  validates the subscription, allocates an IP from the DB, then calls that
  region's `regionsvc` to actually create the peer.

One device has **one active region at a time**. Switching region revokes
the old peer and provisions on the new box (one DB row per physical
device).

---

## 2. The ten regions

| id            | location          | provider | concentrator IP   | regionsvc hostname (DNS A → IP)   |
|---------------|-------------------|----------|-------------------|-----------------------------------|
| us-west-1     | Oregon, US        | Hetzner  | 5.78.203.171      | *central box — loopback, no DNS*  |
| us-east-1     | Virginia, US      | Hetzner  | 5.161.198.227     | rgn-us-east-1.latticevpn.ai       |
| us-central-1  | Dallas, US        | Vultr    | 207.148.1.253     | rgn-us-central-1.latticevpn.ai    |
| de1           | Germany           | Hetzner  | 91.98.65.98       | rgn-de1.latticevpn.ai             |
| fi1           | Finland           | Hetzner  | 204.168.252.70    | rgn-fi1.latticevpn.ai             |
| es1           | Madrid, Spain     | Vultr    | 65.20.99.121      | rgn-es1.latticevpn.ai             |
| mx1           | Mexico City       | Vultr    | 216.238.95.21     | rgn-mx1.latticevpn.ai             |
| za1           | Johannesburg, ZA  | Vultr    | 139.84.248.50     | rgn-za1.latticevpn.ai             |
| in1           | Mumbai, India     | Vultr    | 65.20.77.179      | rgn-in1.latticevpn.ai             |
| jp1           | Tokyo, Japan      | Vultr    | 167.179.75.10     | rgn-jp1.latticevpn.ai             |

These ids are the contract: `regions.json`, the apps' region picker, and
`POST /v1/device {"region": "..."}` all use exactly these strings.

---

## 3. Prerequisites on every box

`regionsvc` provisions WireGuard + Rosenpass peers, so each box must
already be a working concentrator — `server/scripts/setup.sh` run, and:

```bash
systemctl is-active wg-quick@wg0 cloak-rosenpass
# both → active
```

The six Vultr boxes are done. The three non-central Hetzner boxes
(us-east-1, de1, fi1) need `setup.sh` re-run first if they have not been
brought up to the current data-plane build.

---

## 4. The shared internal secret — generate once

`regionsvc` authenticates the central API with a single bearer secret,
`REGION_INTERNAL_SECRET`. The **same value** goes on the central API and
on all ten regionsvc boxes. Generate it once and keep it:

```bash
openssl rand -hex 32
```

Treat it like the Stripe secret: it goes straight into the env files on
the boxes (root-owned, mode `0600`), never into the repo and never into
chat. Anyone holding it can mutate any concentrator's WireGuard
interface — which is why §6 fronts regionsvc with TLS.

---

## 5. Deploy `regionsvc` to a box

Do this on all ten boxes (us-west-1 included — the central API reaches its
local regionsvc over loopback). Steps 5a–5c are identical everywhere;
§6 (the TLS front) is skipped on us-west-1 only.

### 5a. Copy the binary

`regionsvc` is pure Go, statically linked, `linux/amd64`. From your Mac
(repo root) — the pre-built binary is at `server/api/regionsvc`:

```bash
scp -i ~/.ssh/cloakvpn_ed25519 server/api/regionsvc root@<ip>:/usr/local/bin/regionsvc.new
ssh -i ~/.ssh/cloakvpn_ed25519 root@<ip> \
  'mv /usr/local/bin/regionsvc.new /usr/local/bin/regionsvc && chmod 755 /usr/local/bin/regionsvc'
```

Copy-to-temp-then-`mv` matters on redeploys: Linux refuses to overwrite a
running binary (`ETXTBSY`); a rename swaps it atomically.

### 5b. The env file

Create `/etc/cloakvpn/regionsvc.env`, root-owned, mode `0600`. Most `WG_*`
values are box-specific — `WG_SERVER_PUB` is `cat /etc/wireguard/server.pub`
on that box, `WG_ENDPOINT` is that box's own IP or hostname:

```bash
mkdir -p /etc/cloakvpn
cat > /etc/cloakvpn/regionsvc.env <<'ENV'
LISTEN_ADDR=127.0.0.1:8090
REGION_INTERNAL_SECRET=…            # the openssl value from §4 — SAME on every box

WG_IFACE=wg0
WG_SERVER_PUB=…                     # cat /etc/wireguard/server.pub  (this box)
WG_ENDPOINT=<this box IP>:51820
WG_DNS=10.99.0.1
WG_ALLOWED_IPS=0.0.0.0/0, ::/0
WG_SUBNET=10.99.0.0/24
ENV
chmod 600 /etc/cloakvpn/regionsvc.env
```

Each concentrator runs its own `10.99.0.0/24` — the subnets do not need to
be distinct because IP allocation is per-region (the central API's DB
tracks `UNIQUE(region, wg_ip)`).

### 5c. The systemd unit

Copy `server/systemd/regionsvc.service` to
`/etc/systemd/system/regionsvc.service`, then:

```bash
systemctl daemon-reload
systemctl enable --now regionsvc.service
curl -s localhost:8090/healthz        # → ok
```

---

## 6. Put TLS in front of regionsvc (the nine non-central boxes)

The bearer secret must not cross the public internet in cleartext, so
`regionsvc` stays bound to `127.0.0.1` and Caddy fronts it with a real
Let's Encrypt certificate — the same pattern as `cloakvpn-api`.

**DNS first.** In Cloudflare, on the **`latticevpn.ai`** zone, add an `A`
record for each of the nine boxes (see the table in §2), proxy status
**DNS only** (grey cloud) so Caddy can complete the ACME challenge:

```
rgn-us-east-1     A   5.161.198.227
rgn-us-central-1  A   207.148.1.253
rgn-de1           A   91.98.65.98
rgn-fi1           A   204.168.252.70
rgn-es1           A   65.20.99.121
rgn-mx1           A   216.238.95.21
rgn-za1           A   139.84.248.50
rgn-in1           A   65.20.77.179
rgn-jp1           A   167.179.75.10
```

**Caddy on each box** (skip us-west-1):

```bash
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy

# <hostname> is this box's row from §2, e.g. rgn-jp1.latticevpn.ai
cat > /etc/caddy/Caddyfile <<'EOF'
rgn-<id>.latticevpn.ai {
	reverse_proxy 127.0.0.1:8090
}
EOF
systemctl restart caddy
```

Open the firewall for HTTP/HTTPS (Caddy needs :80 for the ACME challenge
and :443 to serve). `setup.sh` brings UFW up; add:

```bash
ufw allow 80/tcp
ufw allow 443/tcp
```

Verify (give Caddy ~30s to fetch the cert):

```bash
curl -s https://rgn-<id>.latticevpn.ai/healthz     # → ok
```

> **Simpler but weaker alternative.** If you want to skip Caddy + DNS for
> launch, bind `regionsvc` to `0.0.0.0:8090` and lock it down with
> `ufw allow from 5.78.203.171 to any port 8090` so only the central API
> can reach it. The trade-off: the bearer secret then travels the public
> internet in cleartext. Recommended only as a stopgap — the TLS path
> above is the launch target.

---

## 7. Update the central API on us-west-1

The new `cloakvpn-api` binary is region-aware: it reads `regions.json`,
calls `regionsvc` instead of driving WireGuard directly, and accepts a
`region` field on `POST /v1/device`.

### 7a. Region registry

Copy `server/api/regions.json` to `/etc/cloakvpn/regions.json` on
us-west-1. It is already filled in for all ten regions; us-west-1 points
at its own loopback regionsvc (`http://127.0.0.1:8090`).

### 7b. api.env — add three vars, drop the old WG ones

The central API no longer touches WireGuard directly, so the
`WG_IFACE / WG_SERVER_PUB / WG_ENDPOINT / WG_DNS / WG_ALLOWED_IPS` lines
are obsolete. Add:

```bash
REGION_INTERNAL_SECRET=…             # the §4 value — same as on every regionsvc
REGIONS_CONFIG=/etc/cloakvpn/regions.json
DEFAULT_REGION=us-west-1
WG_SUBNET=10.99.0.0/24               # keep — used for IP allocation
```

`DEFAULT_REGION` is the back-compat fallback: a `POST /v1/device` with no
`region` field is provisioned there, so older app builds keep working.

### 7c. Swap the binary

```bash
scp -i ~/.ssh/cloakvpn_ed25519 server/api/cloakvpn-api root@5.78.203.171:/usr/local/bin/cloakvpn-api.new
ssh -i ~/.ssh/cloakvpn_ed25519 root@5.78.203.171 \
  'mv /usr/local/bin/cloakvpn-api.new /usr/local/bin/cloakvpn-api && chmod 755 /usr/local/bin/cloakvpn-api && systemctl restart cloakvpn-api'
```

The DB migrates itself on first start: `store.migrate()` adds the
`region` column to the `devices` table if it is missing, backfilling
existing rows with the empty region (they read as `DEFAULT_REGION`).
It is idempotent — safe to restart repeatedly.

```bash
journalctl -u cloakvpn-api -n 30 --no-pager
curl -s localhost:8080/healthz       # → {"ok":true}
```

---

## 8. End-to-end verification

From the central box (or through the SSH tunnel from your Mac), with a
real account number, provision into a remote region and confirm the peer
appears **on that region's box**:

```bash
# build a client keypair
WG_PUB=$(wg genkey | tee /tmp/t.sk | wg pubkey)
rosenpass gen-keys --secret-key /tmp/t.rp.sk --public-key /tmp/t.rp.pk
RP_PUB=$(base64 -w0 /tmp/t.rp.pk)

printf '{"region":"jp1","wg_pubkey":"%s","rosenpass_pubkey":"%s"}' \
  "$WG_PUB" "$RP_PUB" > /tmp/dev.json
curl -s -X POST localhost:8080/v1/device \
  -H "Authorization: Bearer XXXXX-XXXXX-XXXXX-XXXXX-XXXXX" \
  --data-binary @/tmp/dev.json
# → {"config":{…},"tier":"…","device":{…}}  — the config's Endpoint is jp1
```

Then on the **jp1** box: `wg show wg0` shows the new peer. Repeat for each
region id, or script a loop over the ten ids.

A region switch — same device, different region — should remove the peer
from the old box and add it to the new one. Confirm with `wg show` on
both.

### Launch checklist

- [ ] All 10 boxes: `wg-quick@wg0` + `cloak-rosenpass` active
- [ ] All 10 boxes: `regionsvc` active, `/healthz` → ok
- [ ] 9 non-central boxes: `https://rgn-<id>.latticevpn.ai/healthz` → ok
- [ ] us-west-1: new `cloakvpn-api` running, DB migrated
- [ ] `POST /v1/device` provisions into every one of the 10 regions
- [ ] Region switch revokes old peer, adds new one
- [ ] Apps' region picker lists exactly the 10 ids above
