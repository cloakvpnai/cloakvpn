package ai.latticevpn.android.vpn

import uniffi.rosenpassffi.RosenpassSession
import uniffi.rosenpassffi.StaticKeypair
import uniffi.rosenpassffi.StepResult
import uniffi.rosenpassffi.generateStaticKeypair
import uniffi.rosenpassffi.rosenpassVersion

/**
 * Bridge to the Rosenpass post-quantum key-exchange library.
 *
 * The heavy lifting is in `librosenpassffi.so` (Rust + liboqs),
 * cross-compiled by `Scripts/build-rosenpass-android.sh` and surfaced
 * to Kotlin through the uniffi-generated bindings in
 * `uniffi/rosenpassffi/rosenpassffi.kt`. uniffi loads the native
 * library lazily (via JNA) on the first call — no explicit
 * System.loadLibrary needed.
 *
 * This object exposes the three primitives the tunnel needs:
 *   - generateKeypair(): create this device's long-term Rosenpass
 *     static keypair (Classic McEliece + ML-KEM). Called once at
 *     first launch; the keypair is persisted in the App Group store.
 *   - libraryVersion(): the rosenpass crate revision, for diagnostics.
 *   - newSession(): start a Rosenpass handshake against a server,
 *     used by the PSK-rotation loop.
 *
 * The full rotation loop (UDP socket, message pump, re-keying timer)
 * lives in the tunnel manager — see Phase A5. This file deliberately
 * stays a thin, testable wrapper.
 *
 * THREADING NOTE: generateKeypair() materializes a ~524 KB Classic
 * McEliece public key. On macOS the equivalent call had to be moved
 * off the small cooperative-pool stack; on Android, callers should
 * run it on a Thread with an ample stack (see callers in Phase A5)
 * or simply on a normal background Thread (JVM background threads
 * default to a 512 KB-1 MB stack; if a StackOverflowError shows up,
 * bump it with Thread(null, runnable, name, 16L * 1024 * 1024)).
 */
object RosenpassBridge {

    /** rosenpass crate revision string — for the diagnostics screen. */
    fun libraryVersion(): String = rosenpassVersion()

    /**
     * Generate this device's long-term Rosenpass static keypair.
     * Heavy (post-quantum keygen) — call off the main thread.
     */
    fun generateKeypair(): StaticKeypair = generateStaticKeypair()

    /**
     * Open a new Rosenpass session as the initiator against a server.
     * The caller drives it: `initiate()` to get the first message,
     * then feed server replies through `handleMessage()` until a PSK
     * is derived; read it with `lastDerivedPsk()`.
     *
     * Keys are base64-decoded by the caller into raw bytes.
     */
    fun newSession(
        ourSecretKey: ByteArray,
        ourPublicKey: ByteArray,
        peerPublicKey: ByteArray
    ): RosenpassSession = RosenpassSession(ourSecretKey, ourPublicKey, peerPublicKey)
}

// Convenience aliases so the rest of the app can refer to the
// post-quantum types without importing the uniffi package path
// directly. (Kotlin typealiases must be top-level, not nested.)
typealias RosenpassKeypair = StaticKeypair
typealias RosenpassExchangeStep = StepResult
