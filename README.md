# Cloak VPN

Post-quantum, strict no-logs, AI-enhanced consumer VPN for iOS and Android.

**Status:** Phase 0 — single-region PQC tunnel prototype.

## What this is

A monorepo containing:

- `infra/` — Terraform + deploy runner that spins up a Hetzner CX22 and runs `server/scripts/setup.sh` unattended. `make deploy` from zero to running concentrator in ~15 minutes.
- `server/scripts/` — Bootstrap scripts for a WireGuard VPN concentrator with post-quantum key exchange (via [Rosenpass](https://rosenpass.eu)) on fresh Ubuntu 24.04.
- `server/api/` — Go HTTP service that handles Stripe webhooks, tracks per-account tier/device-limits, and provisions new WireGuard peers for paying customers.
- `clients/ios/` — Swift skeleton using `NEPacketTunnelProvider` + the official `wireguard-apple` library.
- `clients/android/` — Kotlin skeleton using `VpnService` + the official `wireguard-android` library.
- `website/` — Static site for `cloakvpn.ai` (landing + pricing). Tailwind via CDN, deployable to Cloudflare Pages.
- `docs/` — Architecture notes, pricing rationale, and the Phase 0/1/2 roadmap.

## The crypto story

| Layer | Algorithm | Rationale |
|-------|-----------|-----------|
| Tunnel data | WireGuard (Noise IKpsk2 → ChaCha20-Poly1305) | Fast, kernel-native, small attack surface |
| Key exchange (classical) | X25519 (inside WireGuard) | Proven, battle-tested |
| Key exchange (post-quantum) | Rosenpass hybrid (Classic-McEliece + Kyber) → WireGuard PSK | Shipping PQC today without waiting for WG-native ML-KEM support |
| Control plane (signup, account, config delivery) | TLS 1.3 with `X25519MLKEM768` hybrid group | PQC on the whole surface, not just the tunnel |

Rosenpass runs alongside WireGuard and rotates the WireGuard `PresharedKey` every ~2 minutes. If the classical Curve25519 layer is ever broken by a quantum attacker, the PQC-derived PSK keeps the tunnel confidential.

## Quickstart

### 1. Stand up the server (15 minutes, one command)

Terraform-provisioned Hetzner CX22 in Helsinki + remote-executed setup:

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # paste Hetzner API token + your SSH pubkey path
cd .. && make init && make deploy
```

The runner creates the VPS, firewalls it, rsyncs this repo's `server/` directory to it, runs `setup.sh` (installing WireGuard + Rosenpass + UFW + tmpfs /var/log), reboots, and writes a ready-to-paste client config to `infra/out/client.conf.ini`. Full runbook in [`infra/README.md`](infra/README.md).

Manual alternative (you already own the box):

```bash
ssh root@<server-ip>
git clone https://github.com/<your-org>/cloak-vpn.git
sudo ./cloak-vpn/server/scripts/setup.sh
```

### 2. Connect a client

See `clients/ios/README.md` and `clients/android/README.md` for build instructions. Each app expects a config bundle exported from the server.

### 3. Stand up billing (Stripe)

```bash
cd server/api
go build -trimpath -ldflags="-s -w" -o /usr/local/bin/cloakvpn-api .
# then configure /etc/cloakvpn/api.env with the Stripe keys documented in
# server/api/README.md and enable the systemd unit.
```

Landing page + pricing page live in `website/` and are deployable to Cloudflare Pages as-is — see `website/README.md`. Tier structure and Stripe product setup are documented in `docs/PRICING.md`.

## No-logs posture

- RAM-only server (`tmpfs` for `/var/log` — applied by `scripts/harden.sh`).
- No persistent account identifiers linked to traffic (server only stores a WireGuard public key + optional expiration, no email).
- Rosenpass + WireGuard both use ephemeral handshake state; neither daemon writes tunnel traffic logs by default.

## License

TBD — reserve the name, decide license (MIT or GPLv3) before any public release.

## Roadmap

See `docs/ROADMAP.md`.
