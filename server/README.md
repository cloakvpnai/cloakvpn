# Cloak VPN server

A single-node WireGuard + Rosenpass (post-quantum) VPN concentrator. Target host: Ubuntu 24.04 LTS on a cheap cloud VPS.

## One-command install

```bash
sudo ./scripts/setup.sh
```

The script:

1. Installs `wireguard`, `wireguard-tools`, `rosenpass` (from apt on 24.10+; from cargo as fallback), `ufw`, `qrencode`.
2. Generates server keypairs for both WireGuard and Rosenpass (4 keys total).
3. Writes `/etc/wireguard/wg0.conf` and `/etc/rosenpass/server.toml`.
4. Enables IP forwarding (v4 + v6), configures NAT masquerading.
5. Installs two systemd units — `wg-quick@wg0.service` and `cloak-rosenpass.service`.
6. Locks UFW to: SSH, `51820/udp` (WireGuard), `9999/udp` (Rosenpass handshake).
7. Mounts `/var/log` as tmpfs (RAM-only) — data wipes on reboot.
8. Prints a config block to paste into the iOS/Android app.

## Adding more peers

```bash
sudo ./scripts/add-peer.sh alice
```

Prints a new client config block. Existing tunnels keep working (WireGuard is hot-reloaded).

## Cost

On Hetzner Cloud CX22 (2 vCPU / 4 GB / 20 TB): ~€3.79/month including 20 TB of traffic. This is enough to serve dozens of alpha users.

## Recommended VPS providers for privacy

| Provider       | Region strength               | Notes                                    |
|----------------|-------------------------------|------------------------------------------|
| Hetzner Cloud  | Finland, Germany, US East/West| Cheapest reputable. GDPR-friendly.       |
| OVH            | Global                        | Owns infrastructure; less third-party.   |
| Quadranet      | US                            | DDoS-tolerant, VPN-friendly.             |
| M247           | Global (many popular exits)   | Used by many consumer VPNs.              |
| 1984 Hosting   | Iceland                       | Strong privacy jurisdiction; pricier.    |

Avoid: DigitalOcean, AWS, GCP — they log hypervisor-level metadata and respond rapidly to abuse complaints in ways that can interrupt users.

## Verifying PQC is active

After connecting a client, check WireGuard's handshake state and confirm the PSK is being rotated:

```bash
sudo wg show wg0 latest-handshakes
sudo wg show wg0 preshared-keys
journalctl -u cloak-rosenpass -n 50 --no-pager
```

The `preshared-keys` output should show a non-zero key per peer that changes every ~2 minutes. That's Rosenpass's PQC-derived PSK being injected.

## Hardening checklist (before production)

- [ ] Switch from root SSH to a non-root sudo user with key-only auth.
- [ ] Fail2ban for SSH.
- [ ] Unattended-upgrades for security patches.
- [ ] Offsite monitoring (uptime only, no traffic logs).
- [ ] Rotate admin SSH key every 90 days.
- [ ] Publish server's Rosenpass & WireGuard fingerprints in a public transparency log.

## Filesystem layout after setup

```
/etc/wireguard/
  wg0.conf              # WireGuard server + peers
  server.key/pub        # Server WG keys
  <name>.key/pub        # Per-peer WG keys
/etc/rosenpass/
  server.toml           # Rosenpass daemon config
  server.rosenpass-{secret,public}
  <name>.rosenpass-{secret,public}
/run/rosenpass/
  psk-<name>            # Per-peer PSK, written by rosenpass, consumed by WG
/etc/systemd/system/
  cloak-rosenpass.service
```
