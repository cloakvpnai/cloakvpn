//! RosenpassFFI — minimal Swift-facing API around `rosenpass::protocol`.
//!
//! Design notes:
//!
//! - This crate exposes ONLY the operations the iOS main-app needs to do a
//!   Rosenpass key-exchange against the Cloak concentrator. We deliberately
//!   do NOT re-export the full crypto-server state machine — Swift gets a
//!   small, opaque handle and a few methods.
//!
//! - Memory: persistent state per session is ~1 MB (one Classic-McEliece
//!   public key for self + server, plus libsodium runtime). This runs in
//!   the MAIN APP, where we have GB of headroom — NEVER inside the
//!   NetworkExtension (which is capped at 50 MiB on iOS 15+).
//!
//! - Threading: all calls are blocking and short (KEM operations are
//!   measured in tens-of-ms even for McEliece). Swift should call from a
//!   background DispatchQueue, not the main actor.
//!
//! - Error handling: anything that can fail returns `Result<T, FfiError>`.
//!   uniffi maps `FfiError` to a throwing Swift method so callers see a
//!   typed `RosenpassError` enum on the Swift side.

use thiserror::Error;
use std::sync::Mutex;

uniffi::setup_scaffolding!();

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------

#[derive(Debug, Error, uniffi::Error)]
pub enum FfiError {
    /// Wraps any internal rosenpass error — keeps the Swift surface flat
    /// and avoids leaking the upstream Rust error hierarchy across the FFI.
    #[error("rosenpass: {0}")]
    Rosenpass(String),

    /// Returned by methods called before the server has been initialized
    /// or after it has been freed.
    #[error("invalid server state: {0}")]
    InvalidState(String),

    /// Anything else (panic guard, type conversion, etc.).
    #[error("internal: {0}")]
    Internal(String),
}

// NOTE: we deliberately do NOT add `impl<E: Display> From<E> for FfiError`
// because Rust's orphan rules make that conflict with stdlib's
// `impl<T> From<T> for T`. Instead, at call sites use:
//     .map_err(|e| FfiError::Rosenpass(e.to_string()))?
// or implement `From<SpecificType>` for FfiError on a per-error-type basis.

// ---------------------------------------------------------------------------
// Keypair generation (one-shot, runs at first install / account creation)
// ---------------------------------------------------------------------------

/// A Rosenpass static keypair (Classic McEliece-460896).
///
/// Public key is ~524 KB. Secret key is ~13.6 KB. Generation peaks at
/// ~2-4 MB working set; do this ONCE in the main app at first install
/// and persist the bytes to the iOS keychain — never regenerate inside
/// the NetworkExtension.
#[derive(uniffi::Record)]
pub struct StaticKeypair {
    pub public_key:  Vec<u8>,
    pub secret_key:  Vec<u8>,
}

/// Generate a fresh static keypair. Expensive (~2-4 MB peak); call exactly
/// once per device install and persist the result.
#[uniffi::export]
pub fn generate_static_keypair() -> Result<StaticKeypair, FfiError> {
    // TODO(day-2): wire to rosenpass-ciphers `StaticKem.keygen`.
    //
    // The Rust stub here will be replaced with a call into
    // `rosenpass::protocol::basic_types::{SSk, SPk}` plus
    // `rosenpass_ciphers::StaticKem.keygen(...)` once we've validated the
    // cross-compile end-to-end with the actual rosenpass dependency
    // wired in. For now this returns an empty buffer so the FFI surface
    // shape can be exercised from Swift.
    Err(FfiError::Internal("not yet implemented".into()))
}

// ---------------------------------------------------------------------------
// Key-exchange session
// ---------------------------------------------------------------------------

/// One Rosenpass key-exchange session against a single peer (the Cloak
/// concentrator). The Swift side holds an `Arc<RosenpassSession>` and
/// calls `step` in a loop until a PSK is produced.
#[derive(uniffi::Object)]
pub struct RosenpassSession {
    inner: Mutex<SessionState>,
}

struct SessionState {
    // Placeholder — will hold the rosenpass::protocol::CryptoServer
    // and PeerPtr once we wire the real implementation.
    initialized: bool,
}

#[uniffi::export]
impl RosenpassSession {
    /// Construct a new session.
    ///
    /// `our_secret_key` / `our_public_key`: bytes from a previously-saved
    ///   `StaticKeypair`.
    /// `peer_public_key`: the concentrator's static Rosenpass public key
    ///   (~524 KB; fetched from the Cloak API at account-provision time).
    #[uniffi::constructor]
    pub fn new(
        _our_secret_key: Vec<u8>,
        _our_public_key: Vec<u8>,
        _peer_public_key: Vec<u8>,
    ) -> Result<std::sync::Arc<Self>, FfiError> {
        // TODO(day-2): instantiate CryptoServer + add_peer.
        Ok(std::sync::Arc::new(RosenpassSession {
            inner: Mutex::new(SessionState { initialized: true }),
        }))
    }

    /// Drive the protocol forward by one step. Returns either:
    ///
    /// - `StepResult::SendMessage(bytes)` — the Swift side should UDP-send
    ///   these bytes to the concentrator's Rosenpass listener
    ///   (`<region>.cloakvpn.ai:9999`) and then call `handle_message` with
    ///   whatever comes back.
    /// - `StepResult::DerivedPsk(bytes)` — the 32-byte symmetric key the
    ///   Swift app should hand to the NE via `sendProviderMessage` so the
    ///   NE can update WireGuardKit's PSK.
    /// - `StepResult::Idle` — nothing to do; sleep until the next
    ///   `psk_rotation_seconds` boundary (default 120s) and call `step`
    ///   again.
    pub fn step(&self) -> Result<StepResult, FfiError> {
        let state = self.inner.lock().map_err(|e| FfiError::Internal(e.to_string()))?;
        if !state.initialized {
            return Err(FfiError::InvalidState("session not initialized".into()));
        }
        Ok(StepResult::Idle)
    }

    /// Feed an incoming Rosenpass UDP packet (received by the Swift app's
    /// UDP socket) into the state machine.
    pub fn handle_message(&self, _bytes: Vec<u8>) -> Result<(), FfiError> {
        let state = self.inner.lock().map_err(|e| FfiError::Internal(e.to_string()))?;
        if !state.initialized {
            return Err(FfiError::InvalidState("session not initialized".into()));
        }
        Ok(())
    }
}

#[derive(uniffi::Enum)]
pub enum StepResult {
    /// Swift should UDP-send these bytes to the Rosenpass server.
    SendMessage { bytes: Vec<u8> },
    /// A fresh 32-byte PSK has been derived; push it to the NE.
    DerivedPsk { psk: Vec<u8> },
    /// No work to do; sleep until next rotation.
    Idle,
}

// ---------------------------------------------------------------------------
// Smoke test — proves the FFI surface compiles + links from Swift
// ---------------------------------------------------------------------------

/// Returns the rosenpass crate version + a feature-flags string. Used by
/// the Cloak iOS app's About screen and as the very-first FFI smoke test
/// during app development to confirm the static lib is linked correctly.
#[uniffi::export]
pub fn rosenpass_version() -> String {
    // We deliberately don't read `env!("CARGO_PKG_VERSION")` of THIS crate
    // (which is just the FFI shim) — we want to surface the upstream
    // rosenpass version that's actually doing the crypto.
    //
    // TODO(day-2): when we wire the real dep, switch to:
    //   format!("rosenpass {}", rosenpass::VERSION)
    "rosenpass-ffi v0.1.0 (rosenpass not yet linked)".to_string()
}
