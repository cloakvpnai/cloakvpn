# infra/ — Cloak VPN Phase 0 concentrator

One-command deploy for a **Hetzner CX22 in Helsinki** running WireGuard + Rosenpass, provisioned by `server/scripts/setup.sh`.

```
infra/
├── terraform/          # Hetzner SSH key + firewall + server
│   ├── versions.tf
│   ├── variables.tf
│   ├── main.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── deploy.sh           # terraform apply → rsync → setup.sh → reboot → smoke test
├── Makefile            # thin wrappers: make deploy / ssh / wg / destroy
└── out/                # gitignored: known_hosts, setup.log, client.conf.ini
```

## Runbook (first-time deploy, ~15 minutes)

### 1. Install prerequisites (your workstation)

```bash
# macOS
brew install terraform rsync

# Ubuntu/Debian
sudo apt install -y terraform rsync openssh-client
```

Also: an SSH key dedicated to this project. Do not reuse your personal key.

```bash
ssh-keygen -t ed25519 -C cloakvpn -f ~/.ssh/cloakvpn_ed25519
```

### 2. Get a Hetzner token

1. Create a Hetzner Cloud account → **console.hetzner.cloud**.
2. Create a project named `cloakvpn`.
3. Inside the project → **Security → API Tokens → Generate API Token**. Scope: **Read & Write**. Copy it — you won't see it again.

### 3. Configure and deploy

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # paste your token, tighten admin_ip_cidrs to your /32

cd ..
make init
make deploy
```

Expected timeline:
- `terraform apply` — 30 s (Hetzner creates the box).
- Wait-for-SSH — 1–2 min (Ubuntu finishes cloud-init).
- `rsync` + `setup.sh` — 3–5 min (apt update, WireGuard + Rosenpass install, key generation, firewall).
- Reboot + smoke test — 1–2 min.

At the end you'll have:
- A running server, IPv4/IPv6 printed to your terminal.
- `infra/out/client.conf.ini` with a working peer config for testing.
- `infra/out/setup.log` with the full boot log.

### 4. Point DNS at it (Cloudflare)

Once DNS is up, also flip `enable_api_port = true` in `terraform.tfvars` and re-run `make deploy` when you're ready to expose the Go API.

```
A     fi1.cloakvpn.ai   → <ipv4 output>
AAAA  fi1.cloakvpn.ai   → <ipv6 output>
A     api.cloakvpn.ai   → <ipv4 output>    # later, once Caddy is up
AAAA  api.cloakvpn.ai   → <ipv6 output>
```

Keep the **proxy status** *DNS-only (gray cloud)* for `fi1.cloakvpn.ai` — Cloudflare's proxy doesn't handle UDP on non-standard ports, and WireGuard is UDP. `api.cloakvpn.ai` *should* be proxied (orange cloud), because the API is plain HTTPS.

### 5. Smoke test the tunnel

```bash
# On your phone/laptop: paste infra/out/client.conf.ini into the Cloak VPN app.
# Or use wg-quick locally:
#   sudo wg-quick up ./peer.conf   (convert from the ini block)

# On your box (from another terminal):
make wg
# Look for:
#   - latest handshake: a few seconds ago
#   - transfer: > 0 received, > 0 sent
#   - systemctl is-active: active
```

If `make wg` shows non-zero traffic and the Cloak PSK rotates every ~2 minutes (the `latest handshake` line refreshing even when idle), the post-quantum path is working end-to-end.

## Day-2 operations

| Command | What it does |
|---|---|
| `make ssh` | Open a root shell on the box. |
| `make setup` | Re-run `setup.sh` without creating a new server (idempotent). |
| `make wg` | Quick peer/state check. |
| `make plan` | Show terraform drift. |
| `make destroy` | Tear the box down. Billing stops within the hour. |

## Costs

| Resource | Monthly |
|---|---|
| Hetzner CX22 in Helsinki | **€3.79** (≈ $4.10) |
| Outbound traffic (first 20 TB) | **included** |
| Extra TB outbound | €1.00 |
| IPv4 address | €0.60 (if you upgrade from CX22's included 1 IPv4) |

Minimum realistic Phase 0 bill: **< €5/month**. There is no per-hour billing surprise — Hetzner bills hourly but caps at monthly.

## Jurisdiction choice

`hel1` (Helsinki) is the default because:

- Finland is **not** a 14 Eyes member and has strong constitutional privacy protections (Section 10 — secrecy of correspondence).
- Latency from US East is ~95 ms, Western Europe ~25 ms — workable for both target regions.
- Hetzner has a public, specific law-enforcement response policy and publishes a transparency report.

Alternatives (see `variables.tf`):

- `fsn1` / `nbg1` — Germany. Stronger GDPR enforcement in practice, but Germany is in 14 Eyes.
- `ash` / `hil` — US. Best US latency, but worst jurisdictional posture. Avoid for the primary concentrator; fine for an expansion node.
- `sin` — Singapore. Good APAC latency; Singapore's privacy posture is weaker than EU.

## Things that are intentionally NOT in this module yet

- **Caddy / nginx + Let's Encrypt for `api.cloakvpn.ai`.** Will arrive as `server/scripts/api-tls.sh` when the Go API is ready to serve public traffic.
- **Backups.** Nothing on the box is worth backing up: state lives in the Go API SQLite (which runs on a *separate* future instance) and in Stripe. The concentrator is intentionally cattle.
- **Observability.** Journald-only, RAM-only, on purpose. Metrics will go to a separate Prometheus instance that pulls a coarse counter (peer count, handshake count) without per-peer identifiers.
- **Multi-region.** Add by duplicating the `hcloud_server` resource with a different `location`/`server_name` — they are independent concentrators sharing only the Go API for account state.
