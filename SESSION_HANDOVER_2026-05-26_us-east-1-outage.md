# Session Handover — 2026-05-26 — us-east-1 outage + regionsvc hardening

Handoff for a fresh chat. Read this top to bottom before doing anything.

This session follows `SESSION_HANDOVER_2026-05-25_launch-hardening.md`.
It started as "continue from where I left off" — the next task per that
handover was the Google Play internal-testing upload — but turned into
a live-incident debug of us-east-1 plus one preventative code change.
The Play upload itself is **still not started**; it's where you pick
up tomorrow.

---

## TL;DR — where things stand

| Area | Status |
|------|--------|
| us-east-1 connectivity from Android | **DONE** — fixed; verified from the test phone |
| `regionsvc` env validation (`mustWGPubkey` / `mustEndpoint`) | **DONE** — committed (`06ef856`) and deployed to all 10 boxes |
| Fleet audit (other 9 regions for the same bug) | **DONE** — none affected; every box restarted cleanly under the new validator |
| **Google Play internal-testing upload** | **NOT STARTED** ← next task (unchanged from prior handover) |
| iOS app | Unchanged — still blocked on Apple org migration |

**Immediate next task: the Google Play internal-testing upload**, exactly
as the 2026-05-25 handover described. The Android app is code-complete,
the keystore is in place, and the build flow is documented there.

---

## What was accomplished today

### 1. us-east-1 was unreachable from the Android app — diagnosed and fixed

Symptom: the phone showed "Connection failed" the moment it tried to
connect to us-east-1. Other regions worked from the same APK.

Diagnosed by elimination across the full stack — confirmed DNS (`dig
+short rgn-us-east-1.latticevpn.ai` → `5.161.198.227` on both 9.9.9.9
and the box's own resolver), TLS (Caddy + `regionsvc /healthz` returned
`ok`), the firewall (`ufw status` on us-east-1 and de1 both allow
9999/udp), the rosenpass binary (sha256 matched de1's exactly:
`88c129ad13df183a14ff8705bb14f9b63825baeffe04d2023e64ff7dd2d10949`,
both from b096cb1), the systemd drop-ins (identical `[Unit]
StartLimitIntervalSec=0` on both boxes), and the FFI/protocol version
(ProtocolVersion::V03 on both sides, b096cb1 + `rosenpass 0.3.0-dev`).
Ruled out the API-side server-pubkey staleness theory by reading the
code: regionsvc reads `/etc/rosenpass/server.rosenpass-public` fresh
from disk on every provision (`wg.go:222`, `:324`) — no API-side cache.

The decisive test was tcpdump on `5.161.198.227:9999` during a phone
connect attempt: **zero packets arrived from the phone.** That meant
the phone wasn't even reaching the Rosenpass step — something earlier
in the connect path was blowing up. Comparing `/etc/cloakvpn/regionsvc.env`
on us-east-1 vs de1 surfaced it:

    us-east-1:  WG_SERVER_PUB=<<< this box's server.pub
    de1:        WG_SERVER_PUB=N0PEq52u5KbseJgBLesBDIpn5fo/tYmEnz+6SrwoUmM=

The literal template placeholder was committed to us-east-1's env
file at setup time and never substituted. regionsvc dutifully embedded
that string into every `ClientConfig.PeerPublicKey`; the phone's `wg`
setup errored on the unparseable key; the connect coroutine threw;
`TunnelState.ERROR` → "Connection failed". The 09:12-today `peer-*`
file on disk that initially looked broken was actually fine — the
rosenpass handshake never even fired because WG died first.

Immediate fix: `sed`'d the real `wg show wg0 public-key` value into
the env file on us-east-1, `systemctl restart regionsvc`, then `pm
clear` on the phone. Reconnect → online. Full runbook in
`docs/HOTFIX_regionsvc-pubkey-placeholder-2026-05-26.md`.

### 2. Durable hardening — regionsvc rejects placeholder env at startup

Committed (`06ef856`) to `server/api/cmd/regionsvc/main.go`: two new
validators wrap `mustEnv`.

- `mustWGPubkey(k)` reads the env var, base64-decodes it, asserts a
  32-byte result. Anything else → `log.Fatalf` with the offending
  value quoted in the message. Used for `WG_SERVER_PUB`.
- `mustEndpoint(k)` reads the env var, asserts `host:port` shape
  (last-colon split, IPv6-safe), and rejects values containing `<`,
  `>`, or `…` — the obvious template-placeholder shapes. Used for
  `WG_ENDPOINT`.

The reason these matter: the failure mode that hit us-east-1 is
invisible to a service-level alarm — `cloak-rosenpass`, `regionsvc`,
`wg-quick@wg0`, and `cloakvpn-api` were all active, `/healthz` was
`ok`, provision responses were 200. Only the *contents* of one field
were wrong, and only end-user devices saw it. The new validators
elevate this category of bug to "service refuses to start at boot,
journal names the bad env var." That same line in `journalctl -u
regionsvc` would have ended the debug in under a minute.

### 3. Fleet rollout + audit, one shot

Cross-compiled `regionsvc` (`linux/amd64`,
`sha256=84fcd665698f2693d7ae871ad4b6eaa7f24b04fdbd538c9eb3741e58b9febec7`)
and pushed to all 10 boxes via the standard
`scp → sha256-verify → mv → systemctl restart` loop. Every box came
back active — which, because of the new validator, *is* the audit. If
any other box had a placeholder env value, that box's `systemctl
is-active regionsvc` would have been `failed` and the journal would
have pointed at the bad var. None did. us-east-1 was the only one.

### 4. SSH access to the Vultr boxes — sorted

Tonight's debug surfaced that `~/.ssh/cloakvpn_ed25519` works for the
Vultr concentrators too, not just the four Hetzner boxes the prior
handover's `~/.ssh/config` block covered. Suggested config extension:

    Host 207.148.1.253 65.20.99.121 216.238.95.21 139.84.248.50 65.20.77.179 167.179.75.10
        User root
        IdentityFile ~/.ssh/cloakvpn_ed25519
        IdentitiesOnly yes

Not committed (it's a per-machine config), but worth adding to
`~/.ssh/config` on the Mac so future deploys don't need `-i` everywhere.

---

## Next steps

### IMMEDIATE — Google Play internal-testing upload

Unchanged from the prior handover. The Android app is code-complete,
built, and tested on the user's phone (sign-in, 10-region picker,
connect, region switching, PQC rotation, self-heal path, plus the
us-east-1 fix verified tonight). Release signing:
`clients/android/lattice-release.jks`, password in
`clients/android/secrets.properties` (gitignored). Build with
`./gradlew :app:assembleRelease` from `clients/android/`, then upload
the AAB to the Play Console internal testing track.

### iOS — still blocked on Apple

Unchanged. Apple Developer individual→organization migration in flight.

### Followups carried over

- **Rosenpass restart-per-provision (scaling).** Still true. The
  systemd start-limit wedge is solved, but restart-per-provision is
  itself a concurrent-load concern under heavy use.
- **Device limit is soft on downgrade.** Still true. Pro→Basic does
  not immediately prune devices; the eviction loop absorbs it on the
  next new-device provision.
- **Provisioning self-check** suggested in the Tokyo postmortem
  (regionsvc runs a synthetic handshake against every newly-added
  peer before returning `200`). Still open. Would have caught
  tonight's bug at deploy time, and the Tokyo bug too.

---

## Known issues / things to watch

- `~3` ghost device rows from earlier reinstalls are likely still on
  the user's account on us-west-1. They self-correct on the next
  provision via the eviction loop.
- The new self-heal escalation in `TunnelManager.kt` from the prior
  handover has now *almost* been exercised — the phone did re-provision
  cleanly after `pm clear` tonight, but the fully-automatic
  "key-desynced device recovers without user intervention" path
  wasn't triggered by this incident because the bug was earlier in
  the stack. That path is still untested in the wild.

---

## Gotchas hit today (so the next chat doesn't repeat them)

- **rosenpass version string is misleading.** Both `0.3.0-dev` and a
  hypothetical incompatible build would print the same `--version`
  output, because that string comes from the Cargo.toml package
  version field, not the git rev. Use `sha256sum /usr/local/bin/rosenpass`
  to compare across boxes; the version string alone proves nothing.
- **Don't trust "rosenpass restarted cleanly" to mean handshakes work.**
  The wg.go `restartRosenpass` always succeeds as long as the unit
  file is loadable. None of the deeper crypto-config errors surface
  there. The new `mustWGPubkey` is the *first* on-box check that
  actually rejects garbage at startup.
- **tcpdump silence at the on-box port is decisive.** If the phone
  reports "Connection failed" and the box sees zero UDP packets on
  9999, the failure is BEFORE the Rosenpass step — i.e. WG setup or
  earlier. The Tokyo-style "handshake arrives, silently rejected"
  shape requires tcpdump to see *some* packets.
- **`pm clear` doesn't help if the bug is server-side.** Tonight's
  decisive triage step was: `pm clear`, fresh sign-in, retry. Still
  failed → bug is not on the phone. That single test eliminated half
  the search space.
- **Multi-line shell paste with embedded "now do X on the phone"
  comments is a trap.** Several diagnostic captures came back empty
  because the whole block ran without the manual step in between.
  Discrete commands paste-by-paste is more reliable than one big block
  with comments.

---

## Reference

- Detailed runbook for tonight's bug:
  `docs/HOTFIX_regionsvc-pubkey-placeholder-2026-05-26.md`.
- `cloakvpn-api` runs on **us-west-1 (`5.78.203.171`)**, behind Caddy at
  `https://api.latticevpn.ai`. Binary `/usr/local/bin/cloakvpn-api`; env
  `/etc/cloakvpn/api.env`; SQLite DB `/var/lib/cloakvpn/cloakvpn.db`.
- `regionsvc` runs on every concentrator with env at
  `/etc/cloakvpn/regionsvc.env`. **Two env vars are now validated at
  startup: `WG_SERVER_PUB` must be a 32-byte base64 WG pubkey;
  `WG_ENDPOINT` must be `host:port` and free of placeholder characters.**
- Build artifact for tonight's `regionsvc`:
  `sha256=84fcd665698f2693d7ae871ad4b6eaa7f24b04fdbd538c9eb3741e58b9febec7`.
- The 10 regions and their IPs are listed in
  `SESSION_HANDOVER_2026-05-25_multiregion-launch.md`.
- Secrets live only in `/etc/cloakvpn/*.env` on the boxes and the user's
  password manager — never in the repo, never in a handover doc.

### Commits made this session (newest first)

```
06ef856   regionsvc: fail-fast on placeholder WG_SERVER_PUB / malformed WG_ENDPOINT
```

`git push` to back up to GitHub.
