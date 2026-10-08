# Patch: runtime peer REMOVE for `cloak-rpd` (rosenpass b096cb1)

STATUS: WIP spec — companion to `app_server_control.md`. Not yet compiled.
Apply alongside the `event_loop_with_control` patch via `apply_patch.sh`.

## Why

`cloak-rpd` could ADD peers at runtime but never REMOVE them. When a device is
revoked or switches regions, `regionsvc` (server/api/internal/wg/wg.go `Revoke`)
deletes the WireGuard peer and `/etc/wireguard/<peer>.pub`, but the peer stayed
resident in the live `AppServer` — so rosenpass kept completing handshakes and
writing `/run/rosenpass/psk-<peer>` for a peer nothing could apply. Because the
provision path was changed to never restart the daemon (commit `9f5e40c`,
always-ADD), the daemon almost never restarts, so these **orphaned PSKs
accumulate indefinitely** (observed fleet-wide: ~52 orphans, surfaced by the
`cloak_psk_orphaned_total` metric + `PskInstallerOrphan` alert).

This patch makes REMOVE the symmetric counterpart of ADD: idempotent, keyed by
peer name, zero disruption to other peers.

## 1. `PeerCtl` — control message type (in `rosenpass/src/app_server.rs`)

Define near the top of `app_server.rs` so both `event_loop_with_control` and the
`cloak-rpd` bin can name it (the bin imports `rosenpass::app_server::PeerCtl`):

```rust
/// Runtime peer-management commands carried from cloak-rpd's control socket
/// thread into the event loop. Both are idempotent (regionsvc sends ADD on
/// every provision, REMOVE on every revoke).
pub enum PeerCtl {
    Add { name: String, pubkey_path: std::path::PathBuf },
    Remove { name: String },
}
```

This replaces the old `Receiver<(String, PathBuf)>` add-only channel; the
`event_loop_with_control` signature becomes `Receiver<PeerCtl>` (see
`event_loop_with_control.rs.snippet`).

## 2. `AppServer::remove_peer_by_outfile` (in `rosenpass/src/app_server.rs`)

Add a method that removes a single peer at runtime, keyed by the peer's PSK
**outfile** path — the only stable handle `cloak-rpd` retained at add time
(`add_peer(..., Some(psk_dir/psk-<name>), ...)`):

```rust
/// Remove the peer whose key-output file equals `outfile`. Stops the peer from
/// responding to handshakes and from emitting further keys. No-op-safe: returns
/// Ok(()) if no such peer is registered. Zero disruption to other peers.
pub fn remove_peer_by_outfile(&mut self, outfile: &std::path::Path) -> anyhow::Result<()>;
```

### Recommended implementation (b096cb1)

`b096cb1` has no public peer-removal API, which is why this was originally
deferred. Two viable strategies — prefer **(A)** for correctness:

**(A) Tombstone (no reindexing) — recommended.**
Peers are referenced by `PeerPtr`/`AppPeerPtr` (Vec indices); a true `Vec`
removal would reindex and corrupt other peers' in-flight `PeerPtr`s. Instead add
an `active: bool` (default true) to the app-level peer record and:
1. Find the app peer whose `outfile == Some(outfile)`; if none, return `Ok(())`.
2. Set `active = false`, clear `current_endpoint`/`initial_endpoint`, and zero
   any cached session/handshake state for that peer.
3. In the event-loop dispatch, skip inactive peers: when `handle_msg` /
   `output_key` resolve a peer that is `!active`, drop the message and emit no
   key. (One guard in the `ReceivedMessage` and `DeleteKey`/`output_key` arms.)
The slot is reused on a later restart (preload rebuilds only live peers from the
on-disk registry, which `Revoke` has already pruned).

**(B) `swap_remove` — simpler, riskier.**
Physically remove the peer and the one swapped into its slot must have its
`PeerPtr` fixed up everywhere it is cached. Only safe because the control drain
runs at the top of the loop with no outstanding `PeerPtr` borrows — but any
future caching of `PeerPtr` across iterations breaks it. Document loudly if used.

Either way: after removing, `cloak-rpd` deletes the stale `psk-<name>` file (done
in the event-loop snippet, not here).

## 3. Verification gate (do NOT roll out before this passes)

Extends the existing two-endpoint spike (README "Remaining work" step 2):

1. Peer A live + rotating; `ADD` peer B over the socket; assert A never stalls
   and B reaches first key (unchanged — existing gate).
2. **NEW:** `REMOVE B` over the socket. Assert:
   - A keeps rotating uninterrupted (no stall, no rekey storm);
   - B's `psk-B` stops updating and the file is deleted;
   - a fresh InitHello from B is ignored (no key emitted) until a subsequent
     `ADD B` re-registers it;
   - `cloak_psk_orphaned_total` for the box returns to 0 after revokes.
3. Canary on us-east-1 under real traffic + soak: revoke/region-switch a device,
   confirm its `psk-*` disappears and no orphan accrues; verify zero rosenpass
   restarts and steady PQC for all other peers. Then fleet rollout.

## 4. Go side (already applied)

`server/api/internal/wg/wg.go`:
- `revokePeerLive(peerName, changed)` now sends `REMOVE <peerName>` to the
  control socket (idempotent), with the legacy restart fallback gated on
  `changed`.
- `Revoke()` calls it **unconditionally** (was gated on `server.toml` changing,
  which runtime peers never do — the root cause of the leak).
