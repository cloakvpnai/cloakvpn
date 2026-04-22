# infra/ — Cloak VPN concentrators (multi-region)

One-command deploy for a **Hetzner CX23** (Ubuntu 24.04) concentrator running WireGuard + Rosenpass. Each region is an independent box, provisioned by `server/scripts/setup.sh`. They share nothing at this layer — account state lives in the future Go API, not on the concentrators.

```
infra/
├── terraform/
│   ├── modules/
│   │   └── concentrator/        # reusable: SSH key + firewall + server
│   │       ├── versions.tf
│   │       ├── variables.tf
│   │       ├── main.tf
│   │       └── outputs.tf
│   └── regions/
│       ├── fi1/                 # Finland · Helsinki (hel1)         — LIVE
│       │   ├── versions.tf
│       │   ├── variables.tf
│       │   ├── main.tf          # instantiates modules/concentrator
│       │   ├── outputs.tf
│       │   └── terraform.tfvars.example
│       └── de1/                 # Germany · Falkenstein (fsn1)      — ready
│           └── …same shape…
├── deploy.sh                    # region-aware: ./deploy.sh <region>
├── Makefile                     # make deploy REGION=de1  (defaults to fi1)
└── out/
    └── <region>/                # gitignored per-region artifacts
```

## Adding a new region

1. **Copy a region dir:** `cp -r terraform/regions/fi1 terraform/regions/<slug>`
2. **Edit `main.tf`:** set `server_name = "cloak-<slug>"` and `location = "<hetzner-dc>"` (options: `hel1`, `fsn1`, `nbg1`, `ash`, `hil`, `sin`).
3. **Copy the tfvars:** `cp terraform/regions/<slug>/terraform.tfvars.example terraform/regions/<slug>/terraform.tfvars` and fill in your Hetzner token (project-scoped — reuse across regions).
4. **Deploy:** `make deploy REGION=<slug>`.

That's it. Each region is a separate terraform state file, so re-running a deploy on one region never touches another.

## Runbook — first-time deploy (~15 minutes)

### 1. Install prerequisites (your workstation)

```bash
# macOS
brew install terraform rsync

# Ubuntu/Debian
sudo apt install -y terraform rsync openssh-client
```

Also an SSH key dedicated to this project:

```bash
ssh-keygen -t ed25519 -C cloakvpn -f ~/.ssh/cloakvpn_ed25519
```

### 2. Get a Hetzner token

1. Sign in at **console.hetzner.cloud**.
2. Create a project named `cloakvpn`.
3. **Security → API Tokens → Generate API Token** (scope: Read & Write). Copy it — you won't see it again. Tokens are project-scoped, not region-scoped, so the same token works for every region in that project.

### 3. Configure and deploy a region

```bash
cd infra/terraform/regions/fi1
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # paste your token, tighten admin_ip_cidrs to your /32

cd ../../..                # back to infra/
make init REGION=fi1
make deploy REGION=fi1
```

`REGION` defaults to `fi1`, so `make deploy` with no args deploys fi1.

Expected timeline:
- `terraform apply` — 30 s.
- Wait-for-SSH — 1–2 min (cloud-init).
- `rsync` + `setup.sh` — 3–5 min (apt, WireGuard + Rosenpass, key generation, firewall).
- Reboot + smoke test — 1–2 min.

### 4. Point DNS at it (Cloudflare)

```
A     <region>.cloakvpn.ai   → <ipv4 output>
AAAA  <region>.cloakvpn.ai   → <ipv6 output>
```

**Proxy status must be DNS-only (grey cloud).** Cloudflare's proxy is HTTP/HTTPS only — WireGuard is UDP on 51820 and would just time out behind an orange cloud.

`api.cloakvpn.ai` is different — that's plain HTTPS and *should* be proxied (orange cloud) when it comes online.

### 5. Smoke test the tunnel

Each successful deploy produces two client configs in `infra/out/<region>/`:

- `client.conf.ini` — Cloak app format, includes the Rosenpass PQC block.
- `cloak-<server-name>-smoketest.conf` — stock WireGuard `.conf` for the official WireGuard app. **Classical WG only**, no Rosenpass. Use this to prove end-to-end routing before the Cloak app is built.

```bash
# On your Mac: import cloak-<server-name>-smoketest.conf into the WireGuard app, activate.
# Visit https://www.cloudflare.com/cdn-cgi/trace
#   - 'ip=' should match the server's IPv4/IPv6
#   - 'loc=' should match the server's country (FI / DE / …)

# On the server (from another terminal):
make wg REGION=<region>
#   - latest handshake: a few seconds ago
#   - transfer:          > 0 received, > 0 sent
#   - cloak-rosenpass.service: active
```

When PSK rotation is working, `latest handshake` will refresh every ~2 minutes even when the tunnel is idle — that's Rosenpass injecting a fresh post-quantum PSK into WG.

## Day-2 operations

Every command accepts `REGION=<slug>` (default `fi1`).

| Command                         | What it does                                                 |
|---------------------------------|--------------------------------------------------------------|
| `make regions`                  | List all configured regions.                                 |
| `make ssh REGION=de1`           | Open a root shell on the box.                                |
| `make setup REGION=de1`         | Re-run `setup.sh` without creating a new server (idempotent). |
| `make wg REGION=de1`            | Quick peer/state check.                                      |
| `make plan REGION=de1`          | Show terraform drift for that region.                        |
| `make destroy REGION=de1`       | Tear down that region's box. Billing stops within the hour.  |

## Costs (per region)

| Resource                           | Monthly         |
|------------------------------------|-----------------|
| Hetzner CX23                       | **€4.59** (≈ $4.90) |
| Outbound traffic (first 20 TB)     | **included**    |
| Extra TB outbound                  | €1.00           |

Minimum realistic Phase 0 bill per region: **< €5/month**. Hetzner bills hourly and caps at monthly — you can spin a region up to experiment and destroy it the same day without a surprise charge.

## Jurisdiction notes

| Region | DC    | 14-Eyes | Notes                                                                     |
|--------|-------|---------|---------------------------------------------------------------------------|
| `fi1`  | hel1  | No      | Strong constitutional privacy (Section 10). Our recommended primary.     |
| `de1`  | fsn1  | **Yes** | Strong GDPR enforcement, 14-Eyes membership. Disclose on regions page.   |
| `us-e` | ash   | **Yes** | Best US latency; worst jurisdictional posture. Expansion only.           |
| `us-w` | hil   | **Yes** | See above.                                                               |
| `sg1`  | sin   | No      | Good APAC latency; weaker privacy posture than EU.                       |

## Things that are intentionally NOT in this module yet

- **Caddy / nginx + Let's Encrypt for `api.cloakvpn.ai`.** Arrives as `server/scripts/api-tls.sh` when the Go API is ready to serve public traffic.
- **Backups.** Nothing on the concentrator is worth backing up — keys regenerate on `setup.sh`, state lives in the Go API SQLite on a separate future instance, billing lives in Stripe. Concentrators are cattle.
- **Observability.** Journald-only, RAM-only `/var/log` on purpose. Metrics will go to a separate Prometheus instance that pulls a coarse counter (peer count, handshake count) without per-peer identifiers.
- **Shared state between concentrators.** They are independent. The Go API is the single source of account + peer-key state.

## Migrating from the pre-module layout

If you already have a live box under the old `infra/terraform/` root (no `regions/`, no `modules/`), see `MIGRATE-fi1.md` in this directory for a zero-downtime state migration script. The server keeps running — only terraform's bookkeeping changes.
