package com.cloakvpn.app.vpn

/**
 * JNI bridge to the Rosenpass post-quantum key-exchange daemon.
 *
 * Build steps:
 *   1. Install `cargo-ndk`:
 *        cargo install cargo-ndk
 *        rustup target add aarch64-linux-android x86_64-linux-android
 *   2. From the rosenpass source tree, build a JNI-compatible cdylib:
 *        cargo ndk -t arm64-v8a -t x86_64 \
 *          -o clients/android/app/src/main/jniLibs \
 *          build --release --features ffi
 *   3. Expose `Java_com_cloakvpn_app_vpn_RosenpassBridge_nativeStart` etc.
 *      from the FFI crate.
 *
 * Until the FFI crate lands, `start()` and `stop()` are no-ops. Tunnel still
 * works; PQC is enforced server-side via Rosenpass there (the WireGuard
 * handshake is still PSK-mixed).
 */
object RosenpassBridge {
    // init { System.loadLibrary("rosenpass") }

    fun start(cfg: CloakConfig) {
        // nativeStart(
        //     cfg.clientRPSecretKeyB64,
        //     cfg.clientRPPublicKeyB64,
        //     cfg.serverRPPublicKeyB64,
        //     cfg.rpEndpoint,
        //     cfg.pskRotationSeconds
        // )
    }

    fun stop() {
        // nativeStop()
    }

    /** Returns the current 32-byte PSK as hex, or null if not established. */
    fun currentPsk(peerPublicKey: String): String? = null

    // external fun nativeStart(
    //     clientSecretB64: String,
    //     clientPublicB64: String,
    //     serverPublicB64: String,
    //     serverEndpoint: String,
    //     rotationSeconds: Int
    // ): Int
    // external fun nativeStop(): Int
}
