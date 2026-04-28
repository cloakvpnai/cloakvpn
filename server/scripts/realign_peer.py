#!/usr/bin/env python3
"""
Realign rosenpass + WireGuard peer entries on a Cloak VPN region so
the rosenpass [[peers]] entry has the SAME peer NAME as the
corresponding WG [Peer]. This ensures cloak-psk-installer maps the
derived PSK to the correct WG peer pubkey.

Background: when the dedup script ran, it kept the FIRST [[peers]]
block by file order (iphone-prod-1, the legacy hand-registered entry)
and dropped the second (cloak-XXXXXXXX, the API-generated entry that
the iPhone is actually using). Both files held the SAME rosenpass
key bytes — so rosenpass handshake against the iPhone succeeds
either way — but cloak-psk-installer derives the WG peer name from
the rosenpass peer name (key_out path: psk-iphone-prod-1) and applies
the PSK to /etc/wireguard/iphone-prod-1.pub's WG pubkey, which is
NOT the iPhone's actual current WG pubkey. Result: PSK desync, WG
handshake instability, sometimes-broken connectivity.

Strategy:
  1. Find the WG [Peer] block whose PublicKey matches a recent
     handshake → that's the active iPhone's WG pubkey.
  2. Look up which `cloak-XXXXXXXX` peer name owns that WG pubkey
     (via /etc/wireguard/cloak-*.pub files).
  3. Rewrite rosenpass server.toml to use that peer name.
  4. Dedupe wg0.conf to one [Peer] block per unique PublicKey.
  5. Reload WG, restart rosenpass + psk-installer.
"""
import os
import re
import shutil
import subprocess
import datetime
import sys

WG_CONF = "/etc/wireguard/wg0.conf"
RP_CONF = "/etc/rosenpass/server.toml"
WG_DIR  = "/etc/wireguard"
RP_DIR  = "/etc/rosenpass"

def backup(path):
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.copy2(path, f"{path}.bak-{ts}")
    print(f"  backed up {path} -> {path}.bak-{ts}", file=sys.stderr)

def get_active_wg_pubkey():
    """Find the WG peer with the most recent (non-zero) handshake."""
    out = subprocess.check_output(
        ["wg", "show", "wg0", "latest-handshakes"], text=True
    )
    best_pk, best_ts = None, 0
    for line in out.strip().splitlines():
        parts = line.split()
        if len(parts) != 2: continue
        pk, ts = parts[0], int(parts[1])
        if ts > best_ts:
            best_ts = ts
            best_pk = pk
    return best_pk

def find_cloak_name_for_wg_pubkey(wg_pk):
    """Search /etc/wireguard/cloak-*.pub for a file containing wg_pk."""
    for fname in sorted(os.listdir(WG_DIR)):
        if not fname.startswith("cloak-") or not fname.endswith(".pub"):
            continue
        with open(os.path.join(WG_DIR, fname)) as f:
            content = f.read().strip()
        if content == wg_pk:
            return fname[:-4]  # strip ".pub"
    return None

def dedupe_wg_peers(wg_pk_to_keep):
    """Keep only ONE [Peer] block per unique PublicKey in wg0.conf."""
    with open(WG_CONF) as f:
        text = f.read()

    parts = re.split(r'(?=\[Peer\])', text)
    header = parts[0]
    blocks = parts[1:]

    seen, kept, dropped = set(), [], 0
    for blk in blocks:
        m = re.search(r'PublicKey\s*=\s*(\S+)', blk)
        if not m:
            kept.append(blk); continue
        pk = m.group(1)
        if pk in seen:
            dropped += 1
            print(f"  WG drop duplicate [Peer] for {pk[:16]}...", file=sys.stderr)
            continue
        seen.add(pk)
        kept.append(blk)

    if dropped == 0:
        return False
    backup(WG_CONF)
    with open(WG_CONF, 'w') as f:
        f.write(header + ''.join(kept))
    print(f"  WG: dropped {dropped} duplicate [Peer] block(s)", file=sys.stderr)
    return True

def realign_rosenpass(target_name):
    """Rewrite /etc/rosenpass/server.toml so the [[peers]] block uses
    the target peer name (matching the WG peer's filename). Leaves
    server.rosenpass-public references untouched."""
    target_key_file = f"{RP_DIR}/{target_name}.rosenpass-public"
    if not os.path.exists(target_key_file):
        print(f"  ERROR: {target_key_file} doesn't exist", file=sys.stderr)
        return False

    with open(RP_CONF) as f:
        text = f.read()

    parts = re.split(r'(?=\[\[peers\]\])', text)
    header = parts[0]
    blocks = parts[1:]

    # Replace each peer block with one referencing target_name
    new_block = (
        '[[peers]]\n'
        f'public_key = "{target_key_file}"\n'
        f'key_out = "/run/rosenpass/psk-{target_name}"\n'
        'protocol_version = "V03"\n'
    )
    # Just one peer block — collapse all of them to a single canonical entry
    if blocks and any(target_name in b for b in blocks):
        # Already pointing at target_name — but might still have stale extras
        if len(blocks) == 1 and target_name in blocks[0]:
            print(f"  RP: already canonicalized to {target_name}", file=sys.stderr)
            return False

    backup(RP_CONF)
    with open(RP_CONF, 'w') as f:
        f.write(header.rstrip() + '\n\n' + new_block)
    print(f"  RP: rewrote server.toml to single [[peers]] for {target_name}", file=sys.stderr)
    return True

def main():
    wg_pk = get_active_wg_pubkey()
    if not wg_pk:
        print("ERROR: no recently-active WG peer found — is the iPhone connected?", file=sys.stderr)
        sys.exit(1)
    print(f"Active iPhone WG pubkey: {wg_pk}", file=sys.stderr)

    target = find_cloak_name_for_wg_pubkey(wg_pk)
    if not target:
        print(f"ERROR: no cloak-*.pub file matches active WG pubkey {wg_pk}", file=sys.stderr)
        sys.exit(1)
    print(f"Target peer name: {target}", file=sys.stderr)

    changed_wg = dedupe_wg_peers(wg_pk)
    changed_rp = realign_rosenpass(target)

    if changed_wg or changed_rp:
        print("Reloading services...", file=sys.stderr)
        if changed_wg:
            subprocess.run(
                "wg syncconf wg0 <(wg-quick strip wg0)",
                shell=True, executable="/bin/bash", check=False
            )
        if changed_rp:
            subprocess.run(["systemctl", "restart", "cloak-rosenpass"], check=False)
            subprocess.run(["systemctl", "restart", "cloak-psk-installer"], check=False)
        print("Done.", file=sys.stderr)
    else:
        print("Nothing to change.", file=sys.stderr)

if __name__ == "__main__":
    main()
