package ai.latticevpn.android.vpn

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.rosenpassffi.StepResult
import java.util.Base64
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.coroutines.coroutineContext
import kotlin.math.min

/** Failures internal to the Rosenpass rotation loop. */
class RosenpassException(message: String) : Exception(message)

/** Live state of the post-quantum key exchange, for the status UI. */
sealed class RosenpassStatus {
    /** Loop not running. */
    data object Idle : RosenpassStatus()

    /** Loop started, first handshake not yet attempted. */
    data object Connecting : RosenpassStatus()

    /** A handshake is in flight. */
    data object Handshaking : RosenpassStatus()

    /** At least one PSK has been derived; [rotations] completed so far. */
    data class Established(val rotations: Int) : RosenpassStatus()

    /** The most recent handshake failed; the loop is backing off to retry. */
    data class Error(val message: String) : RosenpassStatus()

    /** Human-readable form for the diagnostics / status UI (Phase A6). */
    val description: String
        get() = when (this) {
            Idle -> "PQC: idle"
            Connecting -> "PQC: connecting"
            Handshaking -> "PQC: handshaking…"
            is Established -> "PQC: $rotations rotation${if (rotations == 1) "" else "s"} ✓"
            is Error -> "PQC: $message"
        }
}

/**
 * Drives the periodic Rosenpass post-quantum key exchange against the
 * Cloak concentrator's Rosenpass listener — the Kotlin port of the iOS
 * `RosenpassBridge` rotation loop (and its in-extension twin
 * `RosenpassDriver`).
 *
 * For each rotation cycle it:
 *   1. constructs a fresh `RosenpassSession` from the device's static
 *      keypair and the server's public key;
 *   2. runs the Rosenpass V03 handshake over UDP via [RosenpassTransport]
 *      — `initiate()` then feed each reply through `handleMessage()`;
 *   3. surfaces the derived 32-byte PSK to [PskApplicator];
 *   4. sleeps until the next rotation deadline (default 120 s);
 *   5. on failure, backs off exponentially (capped at 60 s) and retries.
 *
 * Unlike iOS — which had to split the crypto state machine (host app)
 * from the UDP transport (network extension) across a process boundary
 * — Android has no such split. The whole loop runs in-process inside the
 * app, kept alive by the WireGuard foreground `VpnService`. So this
 * single class fuses what iOS spread across `RosenpassBridge` and
 * `RosenpassDriver`, and there is no App-Group status file: [status] is
 * a plain [StateFlow] the UI can collect directly.
 *
 * Threading: the Rosenpass FFI reconstructs Classic McEliece / ML-KEM
 * key material and is both CPU- and stack-hungry. All FFI + blocking UDP
 * work runs on a dedicated single thread with a large stack — the
 * Android analogue of the iOS `Task.detached(priority: .userInitiated)`.
 *
 * Single-use: after [stop] the instance is dead. Create a fresh
 * [RosenpassRotator] for the next tunnel session.
 */
class RosenpassRotator(
    private val clientSecretKeyB64: String,
    private val clientPublicKeyB64: String,
    private val serverPublicKeyB64: String,
    private val serverHost: String,
    private val serverPort: Int,
    rotationSeconds: Int,
    private val applicator: PskApplicator,
) {

    // Floor the rotation interval: tighter cycles risk overlapping
    // handshakes without materially improving forward secrecy. Mirrors
    // the iOS `max(rotationSeconds, 30)`.
    private val rotationSeconds: Int = rotationSeconds.coerceAtLeast(MIN_ROTATION_SEC)

    private val _status = MutableStateFlow<RosenpassStatus>(RosenpassStatus.Idle)
    val status: StateFlow<RosenpassStatus> = _status.asStateFlow()

    // Dedicated large-stack thread for the Rosenpass FFI + blocking UDP.
    private val ffiExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(null, runnable, "rosenpass-rotator", FFI_STACK_BYTES)
        }
    private val ffiDispatcher = ffiExecutor.asCoroutineDispatcher()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var loopJob: Job? = null

    /** True while the rotation loop is running. */
    fun isRunning(): Boolean = loopJob?.isActive == true

    /**
     * Start the rotation loop. Idempotent — a second call while already
     * running is a no-op. Decodes the supplied keys up front; on a
     * decode failure the loop is not started and [status] becomes
     * [RosenpassStatus.Error].
     */
    fun start() {
        if (isRunning()) return

        val clientSecret: ByteArray
        val clientPublic: ByteArray
        val serverPublic: ByteArray
        try {
            clientSecret = Base64.getDecoder().decode(clientSecretKeyB64.trim())
            clientPublic = Base64.getDecoder().decode(clientPublicKeyB64.trim())
            serverPublic = Base64.getDecoder().decode(serverPublicKeyB64.trim())
        } catch (e: IllegalArgumentException) {
            _status.value = RosenpassStatus.Error("invalid base64 in keys")
            Log.e(TAG, "key decode failed: ${e.message}")
            return
        }

        _status.value = RosenpassStatus.Connecting
        loopJob = scope.launch {
            runLoop(clientSecret, clientPublic, serverPublic)
        }
    }

    /**
     * Cancel the loop and release the FFI thread. Safe to call multiple
     * times. The instance must not be reused afterwards.
     */
    fun stop() {
        loopJob?.cancel()
        loopJob = null
        ffiExecutor.shutdown()
        _status.value = RosenpassStatus.Idle
    }

    // -----------------------------------------------------------------
    // Rotation loop
    // -----------------------------------------------------------------

    private suspend fun runLoop(
        clientSecret: ByteArray,
        clientPublic: ByteArray,
        serverPublic: ByteArray,
    ) {
        var rotations = 0
        var consecutiveFailures = 0

        while (coroutineContext.isActive) {
            _status.value = RosenpassStatus.Handshaking
            try {
                val psk = withContext(ffiDispatcher) {
                    singleHandshake(clientSecret, clientPublic, serverPublic)
                }
                rotations += 1
                consecutiveFailures = 0
                _status.value = RosenpassStatus.Established(rotations)
                Log.i(TAG, "rotation #$rotations succeeded (${psk.size}-byte PSK)")

                // Apply the PSK. A failure here (e.g. the tunnel dropped
                // mid-cycle) is logged but NOT treated as a handshake
                // failure — the next rotation will derive and apply a
                // fresh PSK anyway.
                try {
                    applicator.apply(psk)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.e(TAG, "PSK apply failed: ${e.message}")
                }

                delay(rotationSeconds * 1000L)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                consecutiveFailures += 1
                val msg = e.message ?: e.javaClass.simpleName
                Log.e(TAG, "handshake failed ($consecutiveFailures consecutive): $msg")
                _status.value = RosenpassStatus.Error(msg)
                // Exponential backoff, capped at 60 s — matches the iOS
                // RosenpassDriver: min(60, 1 << min(failures, 6)).
                val backoff = min(MAX_BACKOFF_SEC, 1 shl min(consecutiveFailures, 6))
                delay(backoff * 1000L)
            }
        }
    }

    /**
     * One round-trip of the Rosenpass V03 protocol:
     *   tx InitHello → rx RespHello → tx InitConf → done.
     *
     * V03 surfaces the PSK as `SendMessage(InitConf)` rather than
     * `DerivedPsk`: the InitConf bytes MUST be sent for the responder to
     * commit, so the FFI returns them as an outbound message and stashes
     * the PSK. After sending we fetch it via `lastDerivedPsk()`. Dropping
     * InitConf here would leave the server's WireGuard with no PSK
     * installed — the exact bug the iOS comments document at length.
     *
     * A fresh transport (and therefore a fresh ephemeral UDP source port
     * and empty receive buffer) is used per handshake so a stale
     * datagram from a previous cycle cannot be mistaken for this
     * session's reply.
     *
     * Runs on [ffiDispatcher]; all calls here are blocking.
     */
    private suspend fun singleHandshake(
        clientSecret: ByteArray,
        clientPublic: ByteArray,
        serverPublic: ByteArray,
    ): ByteArray {
        val transport = RosenpassTransport(serverHost, serverPort)
        val session = RosenpassBridge.newSession(clientSecret, clientPublic, serverPublic)
        try {
            transport.connect()
            transport.send(session.initiate())

            // Up to 6 iterations: covers V03's 1.5-RTT pattern plus a few
            // server-side retransmits under packet loss.
            repeat(MAX_MESSAGES) {
                coroutineContext.ensureActive()
                val inbound = transport.receive(RECEIVE_TIMEOUT_SEC)
                when (val result = session.handleMessage(inbound)) {
                    is StepResult.SendMessage -> {
                        transport.send(result.bytes)
                        // The PSK may have been derived during the same
                        // handle_message call that produced these bytes
                        // (the RespHello that requires us to emit
                        // InitConf). Fetch it from the session stash.
                        val psk = session.lastDerivedPsk()
                        if (psk != null && psk.size == 32) return psk
                    }
                    is StepResult.DerivedPsk -> {
                        if (result.psk.size != 32) {
                            throw RosenpassException("PSK length ${result.psk.size} != 32")
                        }
                        return result.psk
                    }
                    StepResult.Idle -> {
                        val psk = session.lastDerivedPsk()
                        if (psk != null && psk.size == 32) return psk
                    }
                }
            }
            throw RosenpassException("handshake exceeded message budget")
        } finally {
            transport.close()
            runCatching { session.close() }
        }
    }

    companion object {
        private const val TAG = "RosenpassRotator"

        /** Lower bound on the rotation interval. */
        private const val MIN_ROTATION_SEC = 30

        /** Max inbound messages tolerated per handshake. */
        private const val MAX_MESSAGES = 6

        /** Per-message inbound UDP timeout. */
        private const val RECEIVE_TIMEOUT_SEC = 8

        /** Backoff ceiling between failed handshakes. */
        private const val MAX_BACKOFF_SEC = 60

        // 16 MiB — the Rosenpass FFI guidance in RosenpassBridge.kt: post-
        // quantum key material overruns the default JVM background-thread
        // stack, so give the worker thread plenty of headroom.
        private const val FFI_STACK_BYTES = 16L * 1024 * 1024
    }
}
