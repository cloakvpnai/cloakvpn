# Hotfix — `WG_SERVER_PUB` placeholder in `regionsvc.env`

Runbook for the Virginia outage of 2026-05-26.

---

## What happened

A single failure on `us-east-1`:

- **Every Android connect to us-east-1 ended in "Connection failed"** —
  the central API returned `200 OK`, regionsvc returned a `ClientConfig`,
  the on-box rosenpass + regionsvc + wg0 services were all healthy, but
  the phone's tunnel never came up. UDP tcpdump on `:9999` showed zero
  packets from the phone, even though DNS for `rgn-us-east-1.latticevpn.ai`
  resolved correctly to `5.161.198.227`.

Other regions (de1 confirmed, others presumed) connected from the same
APK on the same phone without issue. So the bug was specifically on
us-east-1's on-box state.

## Root cause

`/etc/cloakvpn/regionsvc.env` on us-east-1 carried the **literal
placeholder string** from the deploy template:

```
WG_SERVER_PUB=<<< this box's server.pub
```

Whoever set up us-east-1 saw the comment in `docs/DEPLOY_MULTIREGION.md`
("cat /etc/wireguard/server.pub on that box") and committed the env
file without substituting the actual value.

regionsvc happily started — `mustEnv("WG_SERVER_PUB")` only checks for
non-empty — and then handed that literal string back inside every
`ClientConfig.PeerPublicKey`. The phone got a `wg` config whose peer
public key was the literal text `<<< this box's server.pub`. WG setup
errored before the Rosenpass UDP handshake ever fired — which is why
tcpdump on `:9999` saw nothing.

The on-box rosenpass log was misleading too: it showed `peer-*` peers
being added on each provision (the file *was* written to disk), and the
service restarted cleanly, but no peer ever produced an `output-key ...
exchanged` line. That was because the phone, blocked by the broken WG
layer, never reached the rosenpass step.

## The fix

**Immediate** (us-east-1, applied 2026-05-26 ~10:00 UTC):

```bash
ssh 5.161.198.227 '
  SERVER_PUB=$(wg show wg0 public-key)
  cp /etc/cloakvpn/regionsvc.env /etc/cloakvpn/regionsvc.env.bak.$(date +%Y%m%d-%H%M%S)
  sed -i "s|^WG_SERVER_PUB=.*|WG_SERVER_PUB=$SERVER_PUB|" /etc/cloakvpn/regionsvc.env
  systemctl restart regionsvc
'
```

Phone-side, after the env fix:

```bash
adb shell pm clear ai.latticevpn.android
# sign in, tap us-east-1, connect — verified working
```

**Durable** (committed to the working tree, deployed fleet-wide):
`server/api/cmd/regionsvc/main.go` now validates the env on startup
through `mustWGPubkey` and `mustEndpoint`. `mustWGPubkey` base64-decodes
the value and asserts a 32-byte result — a real WireGuard public key.
`mustEndpoint` asserts `host:port` shape and rejects values containing
`<`, `>`, or `…`. Either failure produces a `log.Fatalf` with the
offending value quoted in the message; regionsvc refuses to start
rather than serving garbage. The IPv6-safe last-colon split also lives
in this file (`lastColonSplit`).

## Build artifact

`regionsvc`, cross-compiled `linux/amd64`, at:

    server/api/regionsvc

    sha256: 84fcd665698f2693d7ae871ad4b6eaa7f24b04fdbd538c9eb3741e58b9febec7

Rebuild from `server/api/`:

    GOOS=linux GOARCH=amd64 go build -o regionsvc ./cmd/regionsvc/

## Fleet rollout (2026-05-26)

Deployed to all 10 boxes via the standard scp + sha-verify + restart
loop. Every box returned `systemctl is-active regionsvc == active`,
which — because of the new validators — is *also* the audit: any other
box with a placeholder env value would have refused to start. None
did. us-east-1 really was the only one.

## Why no alarm fired

The bug was at the layer between "service is healthy" and "customer
can actually connect":

- `cloak-rosenpass`, `regionsvc`, `wg-quick@wg0`, `cloakvpn-api` all
  reported active. ✓
- `regionsvc /healthz` returned `ok`. ✓
- Provision responses were 200 with a well-formed ClientConfig body. ✓
- Only the *contents* of one field of the ClientConfig were wrong, in
  a way that only end-user devices would hit.

The new `mustWGPubkey` validator closes that hole by elevating the bug
from "silently corrupts every provision" to "service refuses to start
and journal says exactly which env var is bad."

## Followups noted

- The provisioning self-check the 2026-05-25 Tokyo postmortem suggested
  (regionsvc runs one synthetic handshake against every newly-added peer
  before returning `200`) would have caught this at deploy time. Still
  open.
- `REGION_INTERNAL_SECRET` could use a minimum-length check the same
  way. Not done in this patch; not part of the bug at hand.
