# Hotfix — systemd start-limit wedges (cloak-rosenpass + cloak-psk-installer)

Runbook for the West Oregon outage of 2026-05-25.

---

## What happened

Two failures on `us-west-1`, same root cause:

1. **Provisioning errors** — the Android app showed `us-west-1` as
   unavailable when connecting/switching regions.
2. **Black tunnel** — once connected, the app showed the exit IP as
   "Unavailable — tap to retry": the tunnel was up but carried no traffic.

The box, DNS, TLS, and the central API were healthy throughout — both
failures were on-box service state.

## Root cause

`regionsvc` restarts `cloak-rosenpass` on **every** provision and revoke
(`server/api/internal/wg/wg.go` → `restartRosenpass`), with a bare
`systemctl restart`. systemd's default start-rate limit is 5 starts / 10s.

- A burst of connects + region switches trips the limit on
  **`cloak-rosenpass`** → it drops into a `start-limit-hit` failed state →
  every later provision 500s. (This is the provisioning failure.)
- **`cloak-psk-installer`** is declared `PartOf=cloak-rosenpass`, so it
  restarts in lockstep and trips the *same* limit. A wedged PSK installer
  is the worse failure: Rosenpass keeps minting post-quantum PSKs, but
  nothing applies them to `wg0`, so after a key rotation the server and
  client `wg0` keys diverge and **every tunnel silently goes black.** On
  2026-05-25 this unit was wedged from 23:29 the prior day.

A plain `systemctl restart` cannot clear a `start-limit-hit` state — only
`systemctl reset-failed` does. Neither the code nor the units did that.

## The fix (committed to the working tree)

1. `server/api/internal/wg/wg.go` — `restartRosenpass()` runs
   `systemctl reset-failed` before `systemctl restart`, so provisioning is
   **self-healing**.
2. `server/scripts/setup.sh` — the generated `cloak-rosenpass.service` and
   `cloak-psk-installer.service` both carry `StartLimitIntervalSec=0`, so
   the limit never trips on freshly-provisioned boxes. Existing boxes get
   the same via a drop-in below.

Only **`regionsvc`** needs redeploying (the binary carries the code fix).
The systemd drop-in is applied to every box regardless.

## Build artifact

`regionsvc`, cross-compiled linux/amd64, static, stripped, at:

    server/api/regionsvc

    sha256: 922115ef812cbef2de75b70bb421368a5baf6e9e32a5508d31f696dacb22bcaf

To rebuild it, from `server/api/`:

    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' \
        -o server/api/regionsvc ./cmd/regionsvc

The invariant that matters: every box ends up with the same hash as the
binary you deploy from.

---

## The 10 boxes

| id           | IP              | regionsvc                          |
|--------------|-----------------|------------------------------------|
| us-west-1    | 5.78.203.171    | central box — regionsvc on loopback |
| us-east-1    | 5.161.198.227   | rgn-us-east-1.latticevpn.ai        |
| us-central-1 | 207.148.1.253   | rgn-us-central-1.latticevpn.ai     |
| de1          | 91.98.65.98     | rgn-de1.latticevpn.ai              |
| fi1          | 204.168.252.70  | rgn-fi1.latticevpn.ai              |
| es1          | 65.20.99.121    | rgn-es1.latticevpn.ai              |
| mx1          | 216.238.95.21   | rgn-mx1.latticevpn.ai              |
| za1          | 139.84.248.50   | rgn-za1.latticevpn.ai              |
| in1          | 65.20.77.179    | rgn-in1.latticevpn.ai              |
| jp1          | 167.179.75.10   | rgn-jp1.latticevpn.ai              |

Commands assume SSH as **root**. Run from the repo root on your Mac so the
`server/api/regionsvc` path resolves. Restarting `regionsvc` is safe — it
is only the provisioning HTTP service and never touches `wg-quick@wg0`,
`cloak-rosenpass`, `cloak-psk-installer`, or any live tunnel.

---

## Step 0 — recover a wedged box now

If a box is currently misbehaving, clear both units' failed state
(`reset-failed` clears `start-limit-hit`; a plain restart cannot):

```bash
ssh root@<ip> 'for u in cloak-rosenpass cloak-psk-installer; do
    systemctl reset-failed $u; systemctl restart $u; done
  systemctl is-active cloak-rosenpass cloak-psk-installer wg-quick@wg0 regionsvc'
```

`cloak-psk-installer` is the one that blacks out tunnels — always check it,
not just `cloak-rosenpass`. (us-west-1 was already recovered by hand on
2026-05-25; reconnecting the client restored traffic.)

## Step 1 — canary: deploy to us-west-1 first

```bash
cd /path/to/cloak-vpn          # repo root
EXPECT=922115ef812cbef2de75b70bb421368a5baf6e9e32a5508d31f696dacb22bcaf

shasum -a 256 server/api/regionsvc        # must start with $EXPECT (macOS)

scp server/api/regionsvc root@5.78.203.171:/usr/local/bin/regionsvc.new

ssh root@5.78.203.171 "
  sha256sum /usr/local/bin/regionsvc.new | grep -q $EXPECT \
    || { echo 'SHA MISMATCH — aborting'; exit 1; }
  chmod +x /usr/local/bin/regionsvc.new
  cp -f /usr/local/bin/regionsvc /usr/local/bin/regionsvc.prev
  mv -f /usr/local/bin/regionsvc.new /usr/local/bin/regionsvc
  # drop-in: disable the start-rate limit on BOTH units
  for u in cloak-rosenpass cloak-psk-installer; do
    mkdir -p /etc/systemd/system/\$u.service.d
    printf '[Unit]\nStartLimitIntervalSec=0\n' > /etc/systemd/system/\$u.service.d/override.conf
  done
  systemctl daemon-reload
  systemctl restart regionsvc
  echo -n 'regionsvc: '; systemctl is-active regionsvc
  echo -n 'healthz:   '; curl -s http://127.0.0.1:8090/healthz
  for u in cloak-rosenpass cloak-psk-installer; do
    echo -n \"\$u limit: \"; systemctl show -p StartLimitIntervalUSec --value \$u
  done
"
```

Expected: `regionsvc: active`, `healthz: ok`, both limits `infinity`.

## Step 2 — roll out to the remaining 9 boxes

```bash
cd /path/to/cloak-vpn
EXPECT=922115ef812cbef2de75b70bb421368a5baf6e9e32a5508d31f696dacb22bcaf
BOXES="5.161.198.227 207.148.1.253 91.98.65.98 204.168.252.70 65.20.99.121 \
216.238.95.21 139.84.248.50 65.20.77.179 167.179.75.10"

for ip in $BOXES; do
  echo "=== $ip ==="
  scp server/api/regionsvc root@$ip:/usr/local/bin/regionsvc.new
  # ssh -n in a loop — without it ssh swallows stdin and the loop stops.
  ssh -n root@$ip "
    sha256sum /usr/local/bin/regionsvc.new | grep -q $EXPECT \
      || { echo '  SHA MISMATCH — skipped'; exit 1; }
    chmod +x /usr/local/bin/regionsvc.new
    cp -f /usr/local/bin/regionsvc /usr/local/bin/regionsvc.prev
    mv -f /usr/local/bin/regionsvc.new /usr/local/bin/regionsvc
    for u in cloak-rosenpass cloak-psk-installer; do
      mkdir -p /etc/systemd/system/\$u.service.d
      printf '[Unit]\nStartLimitIntervalSec=0\n' > /etc/systemd/system/\$u.service.d/override.conf
    done
    systemctl daemon-reload
    systemctl restart regionsvc
    echo -n '  regionsvc: '; systemctl is-active regionsvc
  "
done
```

## Step 3 — verify all 10

```bash
ssh root@5.78.203.171 'curl -s http://127.0.0.1:8090/healthz; \
  systemctl is-active regionsvc cloak-rosenpass cloak-psk-installer wg-quick@wg0 cloakvpn-api'

for h in us-east-1 us-central-1 de1 fi1 es1 mx1 za1 in1 jp1; do
  printf '%-14s ' "$h"; curl -s --max-time 8 https://rgn-$h.latticevpn.ai/healthz
done

# Both units, every box — each line should say infinity.
for ip in 5.78.203.171 5.161.198.227 207.148.1.253 91.98.65.98 204.168.252.70 \
          65.20.99.121 216.238.95.21 139.84.248.50 65.20.77.179 167.179.75.10; do
  ssh -n root@$ip "printf '%-16s ' $ip
    systemctl show -p StartLimitIntervalUSec --value cloak-rosenpass cloak-psk-installer | paste -sd' ' -"
done
```

## Rollback (per box)

```bash
ssh root@<ip> 'mv -f /usr/local/bin/regionsvc.prev /usr/local/bin/regionsvc \
  && systemctl restart regionsvc'
```

The systemd drop-ins are harmless; to remove them, delete
`/etc/systemd/system/cloak-rosenpass.service.d/override.conf` and the
`cloak-psk-installer` equivalent, then `systemctl daemon-reload`.

## After rollout — commit

```bash
git add server/api/internal/wg/wg.go server/scripts/setup.sh
git commit -m "regionsvc: self-healing rosenpass restart + StartLimitIntervalSec=0 on rosenpass & psk-installer"
```

`server/api/regionsvc` is a gitignored build artifact and is not committed.

---

## Open follow-up — `wg0` peer cruft on us-west-1

`wg show wg0` on us-west-1 lists ~22 peers, but only two are real client
devices (`10.99.0.4/32`, `10.99.0.5/32`). The other ~19 have
`allowed ips: (none)` — several with large historic transfer counts —
which means they once routed traffic and then lost their allowed-IPs.
That is the fingerprint of the IP-allocation race fixed in commits
`03a15d7` / `747d165`: before that fix, a duplicate IP assignment moved an
allowed-IP off the older peer, stranding it. The wreckage is now inert
(those peers route nothing and hold no IPs) but should be cleaned before
launch — see the handover's "remove test device rows" item. Audit and
prune deliberately; do not bulk-remove without checking each peer.
