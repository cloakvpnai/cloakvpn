import Foundation

/// Stub for the Rosenpass PQC key-exchange bridge.
///
/// Production implementation plan:
///   1. Build the Rust `rosenpass` crate for iOS targets:
///        rustup target add aarch64-apple-ios aarch64-apple-ios-sim
///        cargo build --target aarch64-apple-ios --release --features ffi
///   2. Wrap the static libs in an XCFramework via `xcodebuild -create-xcframework`.
///   3. Expose two `extern "C"` functions:
///        rosenpass_init(...)   // sets up long-term keys and peer spec
///        rosenpass_exchange()  // runs one handshake round; returns a 32-byte PSK
///   4. Import the XCFramework into this package; this stub reads the PSK and
///      writes it to the shared App Group container so the PacketTunnelProvider
///      extension can call `wg set <iface> peer <pub> preshared-key <psk>`.
///
/// For the Phase 0 prototype, you can SKIP the on-device Rosenpass and run it
/// as a sidecar on the server only — the WireGuard tunnel will still be PQC-
/// protected via the PSK *on the server side* (the classical handshake is
/// mixed with the PQC PSK). This is weaker than full end-to-end PQC but is
/// a valid first step. Keep a visible "PQC: server-only (Phase 0)" indicator
/// in the UI until the FFI bridge lands.

enum RosenpassBridge {
    /// Returns the current 32-byte PSK as hex, or nil if not yet established.
    static func currentPSK(for peerPublicKey: String) -> String? {
        // Phase 0: return nil; server maintains the PSK.
        return nil
    }

    /// Start the local Rosenpass handshake loop. No-op in Phase 0.
    static func start(
        clientSecretKeyB64: String,
        clientPublicKeyB64: String,
        serverPublicKeyB64: String,
        serverEndpoint: String,
        rotationSeconds: Int
    ) {
        // TODO: FFI into rosenpass-rs built for aarch64-apple-ios.
        NSLog("[RosenpassBridge] Phase 0 stub — no on-device PQC handshake.")
    }

    /// Stop the handshake loop and zero keys in memory.
    static func stop() {
        NSLog("[RosenpassBridge] stop (stub)")
    }
}
