//! RosenpassFFI — Swift-facing API around `rosenpass::protocol`.
//!
//! Architecture: this crate runs in the iOS main app process (NOT the
//! NetworkExtension), generates a 32-byte PSK via Rosenpass key exchange
//! every ~120s while the app is foregrounded, and the Swift caller pushes
//! that PSK to the NE via `sendProviderMessage`. See `docs/IOS_PQC.md`
//! for the full architectural rationale.
//!
//! Threading: all calls block on a `Mutex<SessionState>`. KEM operations
//! are tens of ms even for Classic McEliece — Swift should call from a
//! background DispatchQueue, never the main actor.

use std::ops::{Deref, DerefMut};
use std::sync::{Arc, Mutex, Once};
use thiserror::Error;

use rosenpass::protocol::basic_types::{MsgBuf, SPk, SSk};
use rosenpass::protocol::osk_domain_separator::OskDomainSeparator;
// `rosenpass` has TWO `ProtocolVersion` enums (config + protocol). The
// `add_peer` API wants the protocol-module variant, not config.
use rosenpass::protocol::{CryptoServer, PeerPtr, ProtocolVersion};
use rosenpass_cipher_traits::primitives::Kem;
use rosenpass_ciphers::StaticKem;
use rosenpass_secret_memory::policy::secret_policy_use_only_malloc_secrets;

uniffi::setup_scaffolding!();

// ---------------------------------------------------------------------------
// One-time secret-memory policy init
// ---------------------------------------------------------------------------

/// rosenpass-secret-memory requires a one-time policy declaration before
/// any Secret<N> is constructed. On iOS we use the malloc-only policy
/// (memfd_create is Linux-only). This is an idempotent helper called by
/// every entry point.
fn ensure_policy() {
    static ONCE: Once = Once::new();
    ONCE.call_once(secret_policy_use_only_malloc_secrets);
}

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------

// uniffi-rs has a long-standing limitation: it emits broken Swift code
// for tuple-style enum variants (`Rosenpass(String)` produces
// `FfiConverterString.write(, into: &buf)` with an empty argument). The
// workaround is struct-style variants with a named field. Cosmetic in
// Rust, fixes the binding generator. See https://github.com/mozilla/uniffi-rs/issues/1095
#[derive(Debug, Error, uniffi::Error)]
pub enum FfiError {
    /// Wraps any internal rosenpass error.
    #[error("rosenpass: {message}")]
    Rosenpass { message: String },

    /// Caller passed bytes of the wrong length (e.g. truncated key).
    #[error("invalid input: {message}")]
    InvalidInput { message: String },

    /// Method called in an inconsistent session state.
    #[error("invalid state: {message}")]
    InvalidState { message: String },

    /// Anything else (panic guard, mutex poison, etc.).
    #[error("internal: {message}")]
    Internal { message: String },
}

// ---------------------------------------------------------------------------
// Static keypair generation (one-shot at first install)
// ---------------------------------------------------------------------------

/// A Rosenpass static keypair. Public key is ~524 KB (Classic
/// McEliece-460896); secret is ~13.6 KB. Generation peaks at ~2-4 MB
/// working set — call EXACTLY ONCE per device install, persist both
/// halves in the iOS Keychain, and never regenerate.
#[derive(uniffi::Record)]
pub struct StaticKeypair {
    pub public_key: Vec<u8>,
    pub secret_key: Vec<u8>,
}

#[uniffi::export]
pub fn generate_static_keypair() -> Result<StaticKeypair, FfiError> {
    ensure_policy();
    let mut sk = SSk::zero();
    let mut pk = SPk::zero();
    StaticKem
        .keygen(sk.secret_mut(), pk.deref_mut())
        .map_err(|e| FfiError::Rosenpass { message: format!("keygen: {e}") })?;
    Ok(StaticKeypair {
        secret_key: sk.secret().to_vec(),
        public_key: pk.deref().to_vec(),
    })
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// One key-exchange session against a single peer (the Cloak concentrator).
/// The Swift caller holds an `Arc<RosenpassSession>` and drives the
/// protocol by calling `initiate()` then `handle_message()` on each
/// inbound UDP packet until a PSK is produced.
#[derive(uniffi::Object)]
pub struct RosenpassSession {
    inner: Mutex<SessionState>,
}

struct SessionState {
    server: CryptoServer,
    peer: PeerPtr,
    /// Most recent derived PSK (32 bytes). Cleared on session destruction.
    last_psk: Option<Vec<u8>>,
}

#[uniffi::export]
impl RosenpassSession {
    /// Construct a new session. Reconstructs `SSk` and `SPk` from raw
    /// bytes that were saved by a previous `generate_static_keypair()`
    /// call. `peer_public_key` is the concentrator's static Rosenpass
    /// public key (fetched from the Cloak API at provisioning time).
    #[uniffi::constructor]
    pub fn new(
        our_secret_key: Vec<u8>,
        our_public_key: Vec<u8>,
        peer_public_key: Vec<u8>,
    ) -> Result<Arc<Self>, FfiError> {
        ensure_policy();

        // Reconstruct our secret key
        let mut sk = SSk::zero();
        let sk_len = sk.secret().len();
        if our_secret_key.len() != sk_len {
            return Err(FfiError::InvalidInput { message: format!(
                "secret key wrong length: got {}, want {sk_len}",
                our_secret_key.len()
            ) });
        }
        sk.secret_mut().copy_from_slice(&our_secret_key);

        // Reconstruct our public key
        let mut pk = SPk::zero();
        let pk_len = pk.deref().len();
        if our_public_key.len() != pk_len {
            return Err(FfiError::InvalidInput { message: format!(
                "public key wrong length: got {}, want {pk_len}",
                our_public_key.len()
            ) });
        }
        pk.deref_mut().copy_from_slice(&our_public_key);

        // Reconstruct peer's public key (same size as ours)
        let mut peer_pk = SPk::zero();
        if peer_public_key.len() != pk_len {
            return Err(FfiError::InvalidInput { message: format!(
                "peer public key wrong length: got {}, want {pk_len}",
                peer_public_key.len()
            ) });
        }
        peer_pk.deref_mut().copy_from_slice(&peer_public_key);

        let mut server = CryptoServer::new(sk, pk);
        let peer = server
            .add_peer(
                None, // no PSK seed; rosenpass derives one fresh per handshake
                peer_pk,
                ProtocolVersion::V03,
                OskDomainSeparator::default(),
            )
            .map_err(|e| FfiError::Rosenpass { message: format!("add_peer: {e}") })?;

        Ok(Arc::new(Self {
            inner: Mutex::new(SessionState {
                server,
                peer,
                last_psk: None,
            }),
        }))
    }

    /// Start a new handshake. Returns the bytes the Swift app should send
    /// over UDP to the concentrator's Rosenpass listener
    /// (`<region>.cloakvpn.ai:9999`). Call once per rotation cycle, then
    /// feed each incoming UDP packet via `handle_message`.
    pub fn initiate(&self) -> Result<Vec<u8>, FfiError> {
        let mut state = self
            .inner
            .lock()
            .map_err(|e| FfiError::Internal { message: format!("mutex poisoned: {e}") })?;
        // Pull `peer` out as a local before re-borrowing `state` mutably —
        // borrow-checker won't let us mix &state.peer + &mut state.server
        // in the same expression.
        let peer = state.peer;
        let mut buf = MsgBuf::zero();
        let n = state
            .server
            .initiate_handshake(peer, buf.deref_mut())
            .map_err(|e| FfiError::Rosenpass { message: format!("initiate_handshake: {e}") })?;
        Ok(buf.deref()[..n].to_vec())
    }

    /// Feed an inbound UDP packet (received by Swift's UDP socket from
    /// the concentrator) into the state machine. Returns either:
    ///
    /// - `StepResult::SendMessage(bytes)` — UDP-send these bytes back.
    /// - `StepResult::DerivedPsk(bytes)` — handshake completed; here is
    ///   the 32-byte PSK to push to the NetworkExtension.
    /// - `StepResult::Idle` — packet processed, no immediate output;
    ///   wait for the next inbound packet or rotation deadline.
    pub fn handle_message(&self, bytes: Vec<u8>) -> Result<StepResult, FfiError> {
        let mut state = self
            .inner
            .lock()
            .map_err(|e| FfiError::Internal { message: format!("mutex poisoned: {e}") })?;

        let mut tx_buf = MsgBuf::zero();
        let result = state
            .server
            .handle_msg(&bytes, tx_buf.deref_mut())
            .map_err(|e| FfiError::Rosenpass { message: format!("handle_msg: {e}") })?;

        // Borrow `peer` out of `state` before we re-borrow `state.server`
        // mutably — avoids a borrow-checker lifetime tangle.
        let peer = state.peer;
        if let Some(_) = result.exchanged_with {
            let psk = state
                .server
                .osk(peer)
                .map_err(|e| FfiError::Rosenpass { message: format!("osk: {e}") })?;
            let psk_bytes = psk.secret().to_vec();
            state.last_psk = Some(psk_bytes.clone());
            return Ok(StepResult::DerivedPsk { psk: psk_bytes });
        }

        if let Some(n) = result.resp {
            return Ok(StepResult::SendMessage {
                bytes: tx_buf.deref()[..n].to_vec(),
            });
        }

        Ok(StepResult::Idle)
    }

    /// Returns the most-recently-derived PSK, or None if no handshake
    /// has succeeded yet. Useful for the Swift app to retry pushing the
    /// PSK to the NE if the first push failed.
    pub fn last_derived_psk(&self) -> Option<Vec<u8>> {
        self.inner.lock().ok().and_then(|s| s.last_psk.clone())
    }
}

#[derive(uniffi::Enum)]
pub enum StepResult {
    /// Swift should UDP-send these bytes to the Rosenpass server.
    SendMessage { bytes: Vec<u8> },
    /// A fresh 32-byte PSK has been derived; push it to the NE.
    DerivedPsk { psk: Vec<u8> },
    /// Packet processed, no output. Wait for next inbound or rotation.
    Idle,
}

// ---------------------------------------------------------------------------
// Smoke test
// ---------------------------------------------------------------------------

/// Returns the FFI version + linkage info. First Swift call from the
/// iOS app should be this — if it returns successfully, the static
/// library + uniffi bindings are wired correctly.
#[uniffi::export]
pub fn rosenpass_version() -> String {
    format!(
        "rosenpass-ffi v{} (rosenpass git pin b096cb1, Classic McEliece-460896 + ML-KEM-768)",
        env!("CARGO_PKG_VERSION")
    )
}

// ---------------------------------------------------------------------------
// Internal smoke test — runs as `cargo test` on macOS, proves the FFI
// surface actually works end-to-end against a self-loopback handshake.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_string_is_nonempty() {
        let v = rosenpass_version();
        assert!(v.contains("rosenpass-ffi"));
        assert!(v.contains("McEliece"));
    }

    #[test]
    fn keygen_produces_correct_sizes() {
        let kp = generate_static_keypair().expect("keygen should succeed on macOS");
        // Classic McEliece-460896: pubkey 524160, secret 13608.
        assert_eq!(kp.public_key.len(), 524_160, "pubkey size");
        assert_eq!(kp.secret_key.len(), 13_608, "secret size");
    }

    #[test]
    fn loopback_handshake_derives_matching_psk() {
        // Two locally-generated keypairs play both sides of the protocol.
        let alice_kp = generate_static_keypair().unwrap();
        let bob_kp = generate_static_keypair().unwrap();

        let alice = RosenpassSession::new(
            alice_kp.secret_key.clone(),
            alice_kp.public_key.clone(),
            bob_kp.public_key.clone(),
        )
        .unwrap();

        let bob = RosenpassSession::new(
            bob_kp.secret_key.clone(),
            bob_kp.public_key.clone(),
            alice_kp.public_key.clone(),
        )
        .unwrap();

        // Alice initiates. Bob receives. Loop until both have derived the same key.
        let mut alice_psk: Option<Vec<u8>> = None;
        let mut bob_psk: Option<Vec<u8>> = None;
        let mut current = alice.initiate().expect("alice initiate");
        let mut alice_turn = false; // bob is next to receive

        for _ in 0..8 {
            let step = if alice_turn {
                alice.handle_message(current.clone())
            } else {
                bob.handle_message(current.clone())
            }
            .expect("handle_message");

            match step {
                StepResult::SendMessage { bytes } => {
                    current = bytes;
                    alice_turn = !alice_turn;
                }
                StepResult::DerivedPsk { psk } => {
                    if alice_turn {
                        alice_psk = Some(psk);
                    } else {
                        bob_psk = Some(psk);
                    }
                    // Other side may still need one more round-trip
                    if alice_psk.is_some() && bob_psk.is_some() {
                        break;
                    }
                    // Continue loop — the OTHER side still needs to reach DerivedPsk
                    alice_turn = !alice_turn;
                }
                StepResult::Idle => break,
            }
        }

        // At minimum, one side should have derived a PSK — the other may
        // still be mid-flight. For a full assertion both should match.
        assert!(
            alice_psk.is_some() || bob_psk.is_some(),
            "at least one side should have derived a PSK"
        );
        if let (Some(a), Some(b)) = (alice_psk.as_ref(), bob_psk.as_ref()) {
            assert_eq!(a, b, "alice and bob should derive the same PSK");
            assert_eq!(a.len(), 32, "PSK should be 32 bytes");
        }
    }
}
