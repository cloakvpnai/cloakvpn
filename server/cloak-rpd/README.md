# cloak-rpd — zero-disruption rosenpass peer management

**Status: WIP / first draft. NOT compiled, NOT verified, NOT deployed.**
Tracking issue: Phase 3 of `docs/ROSENPASS_NO_RESTART_PEER_MGMT.md`.

## Why
Today `cloak-rosenpass` must be **restarted** to pick up a new peer, and every
restart drops *all* peers' in-flight key exchanges on that box. At thousands of
devices with continuous provisioning/region-switching that means recurring
fleet-wide PQC interruptions. `cloak-rpd` runs the rosenpass responder in one
process on one UDP port and adds peers **at runtime** over a unix control
socket — no restart, no disruption to existing peers.

## How it works
- Links the rosenpass crate (pinned `b096cb1`, same rev as `RosenpassFFI`).
- Builds an `AppServer` (server keypair + UDP listen), optionally pre-loading
  peers from a directory of `*.rosenpass-public` files (cold-start recovery).
- Runs the rosenpass event loop, extended with a control channel
  (`event_loop_with_control`, see `patches/app_server_control.md`).
- A control thread reads `ADD <peerName> <pubkeyPath>` lines from
  `/run/rosenpass/control.sock` and calls `AppServer::add_peer` — zero
  disruption. A mio `Waker` wakes the loop promptly.
- Derived PSKs are written to `/run/rosenpass/psk-<peer>` exactly as today, so
  `cloak-psk-installer` is unchanged.

## regionsvc integration (not yet done)
Replace `restartRosenpass()` in `server/api/internal/wg/wg.go` with a one-line
write to the control socket on provision:
`ADD <peerName> /etc/rosenpass/<peerName>.rosenpass-public`. Keep appending the
`[[peers]]` block / writing the pubkey file to disk as the persistent registry
the daemon reloads on a (rare) restart.

## Files
- `build.sh` — reproducible Docker `linux/amd64` build harness.
- `src/main.rs` — the daemon (first draft).
- `patches/app_server_control.md` — the `AppServer::event_loop_with_control`
  patch spec.

## Remaining work (in order)
1. Finalize + apply the `event_loop_with_control` patch; get `cargo build
   --features experiment_api --bin cloak-rpd` green (iterate in Docker).
2. **Local two-endpoint spike** — peer A live + rotating; `ADD` peer B over the
   socket; assert A never stalls and B reaches first key. THIS IS THE GATE.
3. systemd unit + packaging; `regionsvc` control-socket client.
4. Canary on us-east-1 under real traffic + soak; verify zero rosenpass
   restarts and steady PQC; then fleet rollout (per the design doc).
