# Phase 3 — Zero-disruption rosenpass peer management (no restart)

Status: **design, grounded + de-risked** — ready to build behind a canary.
Author handoff: 2026-05-30. Target: thousands of simultaneously connected
devices per region box, long-held sessions, continuous signup/switch churn,
with **no fleet-wide handshake drops**.

---

## Problem

`cloak-rosenpass` runs `rosenpass exchange-config /etc/rosenpass/server.toml`,
which loads a fixed peer set at startup. Adding or removing a peer requires
**restarting the daemon**, and a restart drops **every** peer's in-flight key
exchange on that box (the code comment in `server/api/internal/wg/wg.go` admits
the ~2–5s interruption). At one test device this is invisible; at thousands of
devices with continuous provisioning/region-switching it means a busy box's
rosenpass is restarting often enough to keep interrupting everyone else's PQC
rotations. The idempotency guard only suppresses *no-op* restarts; legitimate
peer changes still bounce the daemon. This does not scale.

## Key finding — the fix needs no new daemon and no event-loop rewrite

rosenpass at our pinned rev (`b096cb1`, the same rev `clients/ios/RosenpassFFI`
builds) already has every primitive required:

1. **Live peer add, zero collateral.** `AppServer::add_peer(psk, pk, outfile,
   broker_peer, hostname, protocol_version, osk_domain_separator)`
   (`rosenpass/src/app_server.rs:1038`) operates on the *running* server: when
   the crypto server is already constructed it calls
   `srv.add_peer(...)` on the live `CryptoServer`
   (`app_server.rs:1054`) and pushes the `AppPeer` (incl. the `outfile` PSK
   path) onto the peer vec. Existing peers are independent state machines —
   adding one does not touch their sessions or the shared UDP socket.
2. **A management API already wired into the same mio event loop.** Unix-socket
   server under `rosenpass/src/api/` (`api/mio/manager.rs` `MioManager`,
   `api_handler.rs`), gated behind the `experiment_api` Cargo feature. Existing
   commands: `Ping`, `SupplyKeypair`, `AddListenSocket`, `AddPskBroker`. There
   is a clean request/response + message-type pattern to add a new command.
   The app server exposes `add_api_listener(UnixListener)` (`app_server.rs:1638`).
3. **One process, one port** already serves all peers: `event_loop()`
   (`app_server.rs:1077`) does UDP rx → `handle_msg` → on key derivation
   `osk(p)` → write the peer's `outfile` (the `psk-<peer>` file
   `cloak-psk-installer` watches), and `poll()` (`:1311`) drives
   retransmit/rekey timers.

So the whole "no-restart" capability is present; it is simply **not exposed as
an API command yet.**

## Integration approach (revised after reading the API framework)

rosenpass's built-in management API (`experiment_api`) turned out to be a
**zerocopy, fixed-layout binary protocol with SCM_RIGHTS file-descriptor
passing** (`SupplyKeypair` passes the keypair as FDs; messages are
`zerocopy::Ref` structs across `message_type.rs` / `payload.rs` /
`request_response.rs` / `request_ref.rs` / `response_ref.rs` / `server.rs`).
Extending it with `AddPeer` would mean ~7 interlocking Rust files **and**
teaching the Go `regionsvc` to speak binary FD-passing IPC — high effort, high
risk, ugly cross-language surface.

**Chosen approach instead: a thin custom daemon (`cloak-rpd`) that links the
rosenpass crate, owns the mio poll loop, and exposes a simple line-based control
socket.** It avoids the entire zerocopy/FD IPC framework while reusing the
proven crypto + event-loop primitives:
- Build an `AppServer` (load server keypair; bind the UDP `:9999` socket;
  optionally pre-load peers from `server.toml`).
- Register BOTH the UDP socket and a control `UnixListener`
  (`/run/rosenpass/control.sock`, root-only) in one `mio::Poll`.
- Drive the rosenpass loop with the public `AppServer::poll()`
  (`app_server.rs:1311`) / `handle_msg` / `osk` primitives (the same ones
  `event_loop_without_error_handling` uses, `app_server.rs:1116`), writing each
  peer's PSK to its `outfile` so `cloak-psk-installer` is unchanged.
- On a control line `ADD <peerName> <pubkeyPath>`, call
  `AppServer::add_peer(None, pk, Some(/run/rosenpass/psk-<peer>), None, None,
  V03, osk_sep)` — the existing zero-disruption add (`app_server.rs:1038`).
  `regionsvc` just writes one text line to the socket (trivial in Go).

This is a self-contained daemon we own, no rosenpass fork to maintain, and the
control plane is a one-line text protocol instead of binary FD IPC.

## Design

Run `cloak-rpd` (above) with the control socket enabled, and have `regionsvc`
write `ADD`/`REMOVE` lines to the socket instead of `systemctl restart`.

### 1. rosenpass patch (fork at `b096cb1`)
Mirror the `SupplyKeypair`/`AddListenSocket` command structure:
- `api/boilerplate/message_type.rs`: add `ADD_PEER_REQUEST` / `ADD_PEER_RESPONSE`
  type constants + `RequestMsgType::AddPeer` / `ResponseMsgType::AddPeer`.
- request/response structs: request carries the peer's rosenpass public key
  (passed as a file descriptor, like `SupplyKeypair` passes the keypair, or as
  a path the daemon reads), the `outfile` path (`/run/rosenpass/psk-<peer>`),
  `protocol_version = V03`, and the osk domain separator.
- `api/api_handler.rs`: an `add_peer` handler that reads the pubkey and calls
  `self.app_server_mut().add_peer(None, pk, Some(outfile), None, None, V03,
  osk_sep)` — the method already exists at `app_server.rs:1038`. Return ok/err
  in the response (mirror `supply_keypair_response_status`).

Build with `--features experiment_api` for `x86_64-unknown-linux-gnu`/`-musl`.
(We already cross-compile this exact rev for `aarch64-apple-ios`, so the
toolchain and rev are known-good.)

### 2. Daemon runtime
Boot `cloak-rosenpass` so it (a) loads existing peers from `server.toml` at
startup (cold-start / crash / upgrade recovery — unchanged), and (b) opens the
management Unix socket, e.g. `/run/rosenpass/control.sock` (root-only perms).
It then **never restarts for a peer change again.**

### 3. regionsvc change (`server/api/internal/wg/wg.go`)
- Replace `restartRosenpass()` on the provision path with a tiny Unix-socket
  client that sends `AddPeer(peerName, pubkeyPath, /run/rosenpass/psk-<peer>)`.
  No daemon restart.
- Keep appending the `[[peers]]` block to `server.toml` — it remains the
  persistent registry the daemon reloads on a genuine restart/upgrade. (Belt
  and suspenders: live add via socket + durable record on disk.)
- Revoke: keep removing the `[[peers]]` block + key files from disk (so a future
  restart doesn't reload it). Runtime removal from the live server is deferred
  (see below) — acceptable because a stale peer is already documented as
  harmless and one device only ever uses one region at a time.

### 4. cloak-psk-installer — unchanged
The daemon still writes `psk-<peer>` via each peer's `outfile`; the installer
keeps mapping it to the WG peer exactly as today.

### Peer removal (the one gap)
`CryptoServer` has no clean `remove_peer` at `b096cb1`. Options, in order of
preference: (a) live with it — peers are tombstoned on disk and actually drop
on the next daemon restart/upgrade (rare, and a lingering peer is harmless);
(b) add a `RemovePeer` command later if/when upstream gains peer removal, or
implement it in the fork (more invasive — peer vec compaction + PeerPtr
stability). Removal is NOT on the hot path, so ship add-only first.

## Implementation map (concrete — verified against b096cb1 source)

`AppServer` (`rosenpass/src/app_server.rs`) exposes everything needed as **public
fields**, so the control socket integrates as a first-class mio source rather
than fighting the IO core:
- `pub mio_poll: mio::Poll`, `pub mio_token_dispenser: MioTokenDispenser`,
  `pub io_source_index: HashMap<mio::Token, AppServerIoSource>` — register the
  control `UnixListener` here with its own token.
- `pub sockets: Vec<mio::net::UdpSocket>`, `pub crypto_site`, `pub peers` — the
  loop already drives these.
- `add_peer(...)` (`:1038`) — the zero-disruption add.
- `event_loop_without_error_handling` (`:1116`) is the loop to extend; `poll()`
  (`:1311`) returns finite `Sleep` timeouts whenever peers are active, and
  `UNENDING` only when idle.

Plan: add `AppServerIoSource::Control` + register a control `UnixListener`; in
`try_recv`/the loop, on a control-token event accept the connection, read a line
`ADD <peerName> <pubkeyPath>` (or `REMOVE`), and call `add_peer(None, pk,
Some(/run/rosenpass/psk-<peer>), None, None, V03, osk_sep)`. A mio `Waker`
registered on `mio_poll` lets the (rare) idle-with-no-peers case wake promptly;
in production peers are always active so the loop already wakes every few
seconds. Ship as a small patch to the rosenpass crate + a `cloak-rpd` binary
target that calls the new control-enabled loop.

Validation gate before any prod box: a local **two-endpoint test** — peer A in a
live, rotating session; `ADD` peer B over the socket; assert A's rotations never
stall and B reaches first key — run under the Docker amd64 image.

## Rollout (canary → fleet)
1. **Build spike**: build patched rosenpass + `experiment_api` for linux/amd64;
   stand it up locally; with peer A holding a live session, `AddPeer(B)` over
   the socket and confirm A is undisturbed and B completes a handshake.
2. **Canary one box** (recommend `us-east-1`, the current problem child):
   deploy patched binary, enable the control socket, point its `regionsvc` at
   the socket, leave the rest of the fleet on the old path. Verify under real
   connects + switches that rosenpass never restarts and existing peers stay up.
3. **Fleet rollout** with the same backup/sha-verify/restart/active-check
   pattern as `scripts/deploy_regionsvc_fix_20260529.sh`, one box at a time.
4. Add monitoring: alert on any `cloak-rosenpass` restart (should approach zero)
   and track PQC rotation success rate per box.

## Risks / notes
- `experiment_api` is an **experimental** rosenpass feature — using it in prod
  means tracking an experimental surface. Strongly recommend opening an upstream
  issue/PR for the `AddPeer` command so it's maintained, not just forked.
- This touches the **security-critical** crypto daemon — the patch needs a
  proper review and the canary must run long enough to trust it before fleet.
- Fork maintenance: pin the fork at `b096cb1` + our patch; bump intentionally.

## Concrete next step
Set up a Rust + linux/amd64 build environment (Mac with the linux target +
cross linker, or a disposable Linux builder), build the patched rosenpass, and
run the spike in step 1. That proves no-disruption add end-to-end before any
production box is touched.
