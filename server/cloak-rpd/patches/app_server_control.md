# Patch: `AppServer::event_loop_with_control` (rosenpass b096cb1)

STATUS: WIP spec — to be applied to `rosenpass/src/app_server.rs` in the build
harness, then compiled. Not yet verified.

The new method is a near-verbatim copy of `event_loop_without_error_handling`
(`app_server.rs:1116`) with exactly one addition: at the **top of each loop
iteration**, drain the control channel and call `self.add_peer(...)` for each
queued `AddPeer`. Everything else (UDP rx/tx, retransmit timers via `poll()`,
`output_key` → `psk-<peer>` file, endpoint learning) is unchanged, so we inherit
all of rosenpass's battle-tested loop behaviour.

`ControlMsg` is defined in the `cloak-rpd` bin; to avoid a crate-level type
dependency, the method is generic over a closure, OR `ControlMsg` is moved into
the crate. Simplest: make the method take `Receiver<(String, PathBuf)>` (name,
pubkey_path) and build the peer inline. Sketch:

```rust
/// Like [Self::event_loop] but also services a runtime peer-add channel.
/// Each queued (name, pubkey_path) is added with add_peer — zero disruption
/// to existing peers. Wrap with the same retry/backoff as event_loop().
pub fn event_loop_with_control(
    &mut self,
    ctrl_rx: std::sync::mpsc::Receiver<(String, std::path::PathBuf)>,
) -> anyhow::Result<()> {
    // (reuse the event_loop() retry wrapper around this inner loop)
    let (mut rx, mut tx) = (MsgBuf::zero(), MsgBuf::zero());
    macro_rules! tx_maybe_with { /* identical to the original */ }

    loop {
        // --- NEW: drain runtime peer-add requests before polling ---
        while let Ok((name, pubkey_path)) = ctrl_rx.try_recv() {
            match SPk::load(&pubkey_path) {
                Ok(pk) => {
                    let out = std::path::Path::new("/run/rosenpass")
                        .join(format!("psk-{name}"));
                    if let Err(e) = self.add_peer(
                        None, pk, Some(out), None, None,
                        ProtocolVersion::V03,
                        OskDomainSeparator::default(),
                    ) {
                        log::warn!("cloak-rpd add_peer {name} failed: {e:?}");
                    }
                }
                Err(e) => log::warn!("cloak-rpd load {pubkey_path:?} failed: {e:?}"),
            }
        }

        // --- unchanged from event_loop_without_error_handling from here ---
        let poll_result = self.poll(&mut *rx)?;
        // ... identical match on (have_crypto, poll_result) ...
    }
}
```

Notes / verification gate:
- The mio `Waker` (token `0xC0FFEE`, created in `main`) is what makes
  `self.poll()` return promptly when a command is queued during an idle wait;
  the unknown token is a no-op in `try_recv_from_mio_token`
  (`app_server.rs:1548`), so no dispatch changes are required.
- `add_peer`'s idempotency: a re-ADD of an already-present peer should be a
  no-op. Confirm `CryptoServer::add_peer` behaviour on duplicate pubkey at
  b096cb1; if it errors or duplicates, gate the call on a name set kept here.
- MUST PASS before any prod box: the two-endpoint spike (peer A live + rotating,
  ADD peer B over the socket, assert A never stalls and B reaches first key).
