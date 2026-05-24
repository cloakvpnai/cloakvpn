# Session handover — 2026-05-24 — Phase 4 + billing deploy

## Status: WORKING end to end ✅

The complete Lattice VPN flow is proven on a real Android device against
the **us-west-1** concentrator:

account-number sign-in → device provisioning → WireGuard tunnel →
post-quantum (Rosenpass) key exchange → working internet through the tunnel.

No email, no password — the account number is the only credential.

## Shipped & committed this session

| Commit    | What |
|-----------|------|
| `ea5e080` | cloakvpn-api billing fixes (Stripe API version, line-items fetch, SQLite time round-trip) |
| `747b44d` | DEPLOY_API.md §6 — Caddy + DNS production steps |
| `2cb0696` | Phase 4 — Android account-number sign-in (whole app migrated off the JWT model) |
| `b41373b` | wg.go provisioning fixes — rosenpass `protocol_version` + peer `.pub` file |

Backend is deployed on us-west-1 (`5.78.203.171`): `cloakvpn-api` behind
Caddy, reachable at `https://api.latticevpn.ai`.

## TODO — make Phase 4 permanent (2 items)

Today's end-to-end success relied on two live hand-patches on the box.
Until these are made permanent, **only the one test phone works**, and a
reboot will break VPN DNS.

### 1. Deploy the fixed `cloakvpn-api` binary

The binary running on the box predates the `b41373b` fixes. Without the
new binary, every *newly* provisioned device hits the two bugs we
hand-patched (no `protocol_version`, no `.pub` file) and cannot connect.

- Built binary: `server/api/cloakvpn-api`
- sha256: `bb75ca1c313155aa006d08c9e2d9e5683e95255ec0a89445d61b34e815056713`
- Mac: `scp -i ~/.ssh/cloakvpn_ed25519 "<repo>/server/api/cloakvpn-api" root@5.78.203.171:/usr/local/bin/cloakvpn-api.new`
- Box: verify the sha matches, then
  `mv /usr/local/bin/cloakvpn-api.new /usr/local/bin/cloakvpn-api && chmod 755 /usr/local/bin/cloakvpn-api && systemctl restart cloakvpn-api`

### 2. Make the DNS redirect permanent

The VPN hands clients `10.99.0.1` as their DNS server, but no resolver
runs there. A temporary `iptables` redirect to `1.1.1.1` is in place —
but it is runtime-only and vanishes on reboot. Make it survive a reboot
by adding it to `/etc/wireguard/wg0.conf` so wg-quick re-applies it:

```
PostUp = iptables -t nat -A PREROUTING -i wg0 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1:53
PostUp = iptables -t nat -A PREROUTING -i wg0 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1:53
```

Proper long-term fix: run a real resolver on `10.99.0.1`, or set
`WG_DNS=1.1.1.1` in `api.env` and re-provision. The redirect is fine for now.

## Known larger items (not blockers for the single-region test)

- **Multi-region** — only us-west-1 is wired up. US-East / DE / FI need
  `cloakvpn-api` deployed and the account store shared across regions.
  See `BILLING_INTEGRATION.md` §7.
- **Domain split** — the website is on `cloakvpn.ai`; the app and API use
  `latticevpn.ai`. Consolidate onto one domain.
- **Billing go-live** — create the 4 Stripe Payment Links, fill the
  website placeholders, switch Stripe from test to live mode
  (`DEPLOY_API.md` §6c, `STRIPE_SETUP.md`).
- The us-west-1 box has been a test rig for weeks (stale peers, the old
  `cloak-api-server` still running, `protocol_version`/`.pub` gaps fixed
  by hand). For production a clean concentrator built from `setup.sh` is
  tidier than continuing to patch this one.

## Test account

`36ASS-06QHX-877TR-8T1D0-6DV38` — Stripe **test mode**, Basic tier,
active until ~2026-06-28.
