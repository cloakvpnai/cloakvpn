package ai.latticevpn.android.vpn

import android.content.Context
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
import java.net.SocketTimeoutException
import java.util.Base64
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.coroutines.coroutineContext
import kotlin.math.min
import kotlin.random.Random

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
    private val context: Context,
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

    private val _consecutiveFailures = MutableStateFlow(0)
    /**
     * Handshake attempts that have failed back-to-back (0 while healthy).
     * [TunnelManager] watches this: because the Rosenpass handshake UDP
     * travels *inside* the WireGuard tunnel, a sustained run of failures
     * means the tunnel itself has stopped passing traffic — the cue to
     * tear it down and recover (see `TunnelManager.recoverDeadTunnel`).
     */
    val consecutiveFailures: StateFlow<Int> = _consecutiveFailures.asStateFlow()

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

        while (coroutineContext.isActive) {
            _status.value = RosenpassStatus.Handshaking
            try {
                val psk = withContext(ffiDispatcher) {
                    singleHandshake(clientSecret, clientPublic, serverPublic)
                }
                rotations += 1
                _consecutiveFailures.value = 0
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

                delay(nextRotationDelayMs())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val fails = _consecutiveFailures.value + 1
                _consecutiveFailures.value = fails
                val msg = e.message ?: e.javaClass.simpleName
                Log.e(TAG, "handshake failed ($fails consecutive): $msg")
                // Initial convergence: while NO exchange has ever landed on
                // this run, a failed attempt is an expected part of bringing
                // the tunnel up (first packet lost, responder briefly busy).
                // Keep showing "Handshaking" instead of flashing an error at
                // the user — the Android analogue of the iOS NE
                // convergence-grace (2026-05-29). Failures still count
                // toward _consecutiveFailures, so the TunnelManager
                // watchdog's recovery semantics are unchanged.
                _status.value =
                    if (rotations == 0) RosenpassStatus.Handshaking
                    else RosenpassStatus.Error(msg)
                // Exponential backoff, capped at 60 s — matches the iOS
                // RosenpassDriver: min(60, 1 << min(failures, 6)).
                val backoff = min(MAX_BACKOFF_SEC, 1 shl min(fails, 6))
                delay(backoff * 1000L)
            }
        }
    }

    /**
     * Delay before the next rotation, jittered uniformly by ±[ROTATION_JITTER]
     * around the configured interval. A FIXED interval phase-locks with
     * WireGuard's own ~120 s rekey and the tunnel desyncs after a few
     * cycles; randomising every interval keeps the two from ever staying
     * aligned. The mean is unchanged, so the ~2-minute cadence holds.
     */
    private fun nextRotationDelayMs(): Long {
        val base = rotationSeconds * 1000L
        val spread = base * ROTATION_JITTER
        val jittered = base + ((Random.nextDouble() * 2.0 - 1.0) * spread).toLong()
        return jittered.coerceAtLeast(MIN_ROTATION_SEC * 1000L)
    }

    /**
     * One round-trip of the Rosenpass V03 protocol:
     *   tx InitHello → rx RespHello → tx InitConf → (rx EmptyData ack).
     *
     * V03 surfaces the PSK as `SendMessage(InitConf)` rather than
     * `DerivedPsk`: the InitConf bytes MUST be sent for the responder to
     * commit, so the FFI returns them as an outbound message and stashes
     * the PSK, which we fetch via `lastDerivedPsk()`.
     *
     * ## Why this is in two phases
     *
     * The responder commits the post-quantum key only when it *receives*
     * our InitConf. The pre-2026-05-24 code returned the PSK the instant
     * it *sent* InitConf once — so a single dropped datagram left the
     * client holding a key the server never installed. That silent
     * client/server PSK desync is invisible until the next WireGuard
     * rekey (~120 s), which then fails on the PSK mismatch and deadlocks
     * the tunnel — the "rotation #2 deadlock" symptom. And because the
     * Rosenpass handshake rides inside the tunnel, it cannot recover.
     *
     * Phase 1 drives the handshake until the PSK is derived. Phase 2 then
     * retransmits InitConf a few times (best-effort) so the odds of every
     * copy being lost are negligible; the responder treats duplicates
     * idempotently. Any residual desync is caught by the TunnelManager
     * watchdog, which tears the tunnel down and re-keys from the outside.
     *
     * A fresh transport (and therefore a fresh ephemeral UDP source port
     * and empty receive buffer) is used per handshake so a stale datagram
     * from a previous cycle cannot be mistaken for this session's reply.
     *
     * Runs on [ffiDispatcher]; all calls here are blocking.
     */
    private suspend fun singleHandshake(
        clientSecret: ByteArray,
        clientPublic: ByteArray,
        serverPublic: ByteArray,
    ): ByteArray {
        val transport = RosenpassTransport(context, serverHost, serverPort)
        val session = RosenpassBridge.newSession(clientSecret, clientPublic, serverPublic)
        try {
            transport.connect()
            var lastOutbound: ByteArray = session.initiate()
            transport.send(lastOutbound)

            // ---- Phase 1 — drive the handshake until the PSK is derived.
            // Up to MAX_MESSAGES inbound messages: covers V03's 1.5-RTT
            // pattern plus a few server-side retransmits under packet loss.
            //
            // RETRANSMIT-WITHIN-THE-EXCHANGE (2026-06-11): the wait for each
            // inbound message is sliced into RETRANSMIT_INTERVAL_SEC windows;
            // every quiet slice retransmits the last outbound message
            // (InitHello or InitConf) until HANDSHAKE_DEADLINE_SEC. The
            // previous code sent each message exactly ONCE and then blocked
            // 8 s — so a single lost UDP datagram failed the whole attempt
            // (8 s + backoff), which users saw as "PQC timed out" on every
            // fresh Play-store connect and as multi-minute rotation stalls
            // (us-west-1 journal, peer-7bc7a25d3e97). Stock rosenpass
            // retransmits inside the exchange for exactly this reason; the
            // responder treats duplicates idempotently.
            var psk: ByteArray? = null
            var initConf: ByteArray? = null
            var inboundHandled = 0
            var retransmits = 0
            val deadlineNanos =
                System.nanoTime() + HANDSHAKE_DEADLINE_SEC * 1_000_000_000L
            while (inboundHandled < MAX_MESSAGES) {
                coroutineContext.ensureActive()
                val inbound = try {
                    transport.receive(RETRANSMIT_INTERVAL_SEC)
                } catch (e: RosenpassTransportException) {
                    if (e.cause !is SocketTimeoutException) throw e
                    if (System.nanoTime() >= deadlineNanos) {
                        throw RosenpassTransportException(
                            "handshake timed out after ${HANDSHAKE_DEADLINE_SEC}s " +
                                "($retransmits retransmits)",
                        )
                    }
                    retransmits += 1
                    transport.send(lastOutbound)
                    continue
                }
                inboundHandled += 1
                when (val result = session.handleMessage(inbound)) {
                    is StepResult.SendMessage -> {
                        transport.send(result.bytes)
                        lastOutbound = result.bytes
                        // The PSK may have been derived during the same
                        // handle_message call that produced these bytes
                        // (the RespHello that requires us to emit
                        // InitConf). Fetch it from the session stash.
                        val derived = session.lastDerivedPsk()
                        if (derived != null && derived.size == 32) {
                            psk = derived
                            initConf = result.bytes
                            break
                        }
                    }
                    is StepResult.DerivedPsk -> {
                        if (result.psk.size != 32) {
                            throw RosenpassException("PSK length ${result.psk.size} != 32")
                        }
                        return result.psk
                    }
                    StepResult.Idle -> {
                        val derived = session.lastDerivedPsk()
                        if (derived != null && derived.size == 32) return derived
                    }
                }
            }
            val derivedPsk = psk ?: throw RosenpassException("handshake exceeded message budget")

            // ---- Phase 2 — harden InitConf delivery (best-effort).
            // We already hold a valid PSK, so nothing here may fail the
            // rotation: every step is wrapped so a transient socket error
            // is swallowed. The Rosenpass FFI exposes no unambiguous
            // delivery ack, so instead of parsing replies we simply
            // retransmit InitConf. A short wait between sends both paces
            // the retransmits and lets us process any reply — a
            // retransmitted RespHello makes the session re-emit InitConf;
            // an EmptyData ack is harmless to feed in and ignore.
            var lastInitConf: ByteArray = initConf ?: return derivedPsk
            for (i in 0 until INITCONF_RETRANSMITS) {
                coroutineContext.ensureActive()
                val reply = try {
                    transport.receive(INITCONF_ACK_TIMEOUT_SEC)
                } catch (e: Exception) {
                    null
                }
                if (reply != null) {
                    val step = try {
                        session.handleMessage(reply)
                    } catch (e: Exception) {
                        null
                    }
                    if (step is StepResult.SendMessage) lastInitConf = step.bytes
                }
                try {
                    transport.send(lastInitConf)
                } catch (e: Exception) {
                    Log.w(TAG, "InitConf retransmit ${i + 1} failed: ${e.message}")
                }
            }
            return derivedPsk
        } finally {
            transport.close()
            runCatching { session.close() }
        }
    }

    companion object {
        private const val TAG = "RosenpassRotator"

        /** Lower bound on the rotation interval. */
        private const val MIN_ROTATION_SEC = 30

        /**
         * Fractional jitter applied to every rotation interval (±8%).
         * A FIXED interval phase-locks with WireGuard's own ~120 s rekey
         * (REKEY_AFTER_TIME): once the periods align they stay aligned and
         * every PSK swap lands on a rekey handshake — the "~3 good cycles
         * then the tunnel desyncs" failure. We still jitter to keep the
         * rotation's phase moving relative to the rekey, but at ±8% (was
         * ±25%) so the cadence reads as a steady ~2 min like iOS instead of
         * visibly wandering 1.5–2.5 min. ±8% (≈110–130 s) is ample to avoid
         * a stable lock with the 120 s rekey while looking regular.
         */
        private const val ROTATION_JITTER = 0.08

        /** Max inbound messages tolerated per handshake. */
        private const val MAX_MESSAGES = 6

        /**
         * Quiet-wait slice between retransmits of the last outbound
         * handshake message. 2 s comfortably covers the RTT to any region
         * plus the responder's PQC compute, while recovering from a lost
         * datagram ~4x faster than the previous single-send 8 s wait.
         */
        private const val RETRANSMIT_INTERVAL_SEC = 2

        /** Overall per-attempt budget for phase 1 (was a single 8 s wait
         *  per message with no retransmission). */
        private const val HANDSHAKE_DEADLINE_SEC = 12L

        /**
         * Best-effort InitConf retransmits after the first send — the
         * mitigation for the dropped-InitConf PSK desync. Three extra
         * copies make total loss negligible without materially slowing
         * the rotation.
         */
        private const val INITCONF_RETRANSMITS = 3

        /** Short per-retransmit wait for an InitConf reply/ack. */
        private const val INITCONF_ACK_TIMEOUT_SEC = 1

        /** Backoff ceiling between failed handshakes. */
        private const val MAX_BACKOFF_SEC = 60

        // 16 MiB — the Rosenpass FFI guidance in RosenpassBridge.kt: post-
        // quantum key material overruns the default JVM background-thread
        // stack, so give the worker thread plenty of headroom.
        private const val FFI_STACK_BYTES = 16L * 1024 * 1024
    }
}
