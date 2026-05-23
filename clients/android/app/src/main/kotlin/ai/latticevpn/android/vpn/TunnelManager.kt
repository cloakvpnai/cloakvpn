package ai.latticevpn.android.vpn

import ai.latticevpn.android.data.AuthClient
import ai.latticevpn.android.data.LatticeRegion
import ai.latticevpn.android.data.ProvisioningClient
import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import com.wireguard.crypto.KeyPair
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Base64
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * App-wide orchestrator for region provisioning and post-quantum key
 * rotation — the Kotlin port of the iOS `TunnelManager`.
 *
 * Responsibilities (Phase A5):
 *
 *  - **Identity** — generate and persist the device's local Rosenpass
 *    static keypair and WireGuard keypair on first use. Both private
 *    keys are generated on-device and never leave it.
 *  - **Provisioning** — register the device as a peer against a Cloak
 *    region via [ProvisioningClient], import the returned config, and
 *    cache it per region so subsequent switches skip the server
 *    round-trip.
 *  - **Rosenpass rotation** — once the tunnel is up, drive a
 *    [RosenpassRotator] that performs the post-quantum handshake and
 *    feeds rotated PSKs into the tunnel.
 *
 * It drives the lower-level [TunnelRepository] (which owns the actual
 * `GoBackend` WireGuard tunnel) and never touches `GoBackend` directly.
 *
 * What is deliberately NOT ported from the iOS `TunnelManager`: the
 * wedge auto-reconnect layers and the placeholder-profile pre-creation
 * are iOS `NETunnelProviderManager` quirks with no Android analogue, and
 * public-IP display is UI work (Phase A6).
 *
 * Process-wide singleton — obtain via [get].
 */
class TunnelManager private constructor(appCtx: Context) {

    private val context = appCtx.applicationContext
    private val repository = TunnelRepository.get(context)
    private val keyStore = KeyStore(context)
    private val authClient = AuthClient(context)
    private val provisioningClient = ProvisioningClient(authClient)

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // ---- Published state -------------------------------------------------

    private val _selectedRegion = MutableStateFlow<LatticeRegion?>(null)
    /** The region the user last selected; survives app restarts. */
    val selectedRegion: StateFlow<LatticeRegion?> = _selectedRegion.asStateFlow()

    private val _regionSelectionInProgress = MutableStateFlow(false)
    /** True while a [selectRegion] call (provision + import) is in flight. */
    val regionSelectionInProgress: StateFlow<Boolean> = _regionSelectionInProgress.asStateFlow()

    private val _lastRegionError = MutableStateFlow<String?>(null)
    /** Last region-selection error, for surfacing to the user. */
    val lastRegionError: StateFlow<String?> = _lastRegionError.asStateFlow()

    private val _localRosenpassPublicKeyB64 = MutableStateFlow<String?>(null)
    /** Base64 of the device's local Rosenpass public key, once generated. */
    val localRosenpassPublicKeyB64: StateFlow<String?> = _localRosenpassPublicKeyB64.asStateFlow()

    private val _rosenpassStatus = MutableStateFlow<RosenpassStatus>(RosenpassStatus.Idle)
    /** Live status of the post-quantum rotation loop. */
    val rosenpassStatus: StateFlow<RosenpassStatus> = _rosenpassStatus.asStateFlow()

    /** The underlying WireGuard tunnel state. */
    val tunnelState: StateFlow<TunnelState> get() = repository.state

    /** The currently imported config, if any. */
    val tunnelConfig: StateFlow<LatticeConfig?> get() = repository.config

    // ---- Rosenpass rotator lifecycle ------------------------------------

    @Volatile
    private var rotator: RosenpassRotator? = null
    private var rotatorStatusJob: Job? = null
    private var rotatorWatchdogJob: Job? = null

    /** True while [recoverDeadTunnel] is running, to suppress re-entry. */
    @Volatile
    private var recoveryInProgress = false

    /**
     * Automatic recover→reconnect cycles performed with no intervening
     * healthy rotation. Bounds the loop when the fault is durable (e.g.
     * the concentrator is down) instead of bouncing the tunnel forever.
     * Reset to 0 on the first [RosenpassStatus.Established] after a start.
     */
    @Volatile
    private var recoveryAttempts = 0

    init {
        // Restore the last-selected region so the picker highlights it
        // on relaunch. Cheap — a single SharedPreferences string read.
        prefs.getString(KEY_SELECTED_REGION, null)?.let { id ->
            _selectedRegion.value = LatticeRegion.byId(id)
        }
        // Publish the cached local Rosenpass public key if one exists.
        // The McEliece public key file is ~700 KB, so read it off the
        // main thread.
        scope.launch {
            if (keyStore.hasLocalKeypair()) {
                runCatching { withContext(Dispatchers.IO) { keyStore.loadLocalKeypair() } }
                    .onSuccess { _localRosenpassPublicKeyB64.value = it.publicB64 }
            }
        }
        // Watch the tunnel state and start/stop the Rosenpass rotator on
        // transitions. `collect` serializes these calls, so start/stop
        // never overlap.
        scope.launch {
            repository.state.collect { state ->
                when (state) {
                    TunnelState.CONNECTED -> startRotatorIfNeeded()
                    TunnelState.DISCONNECTED, TunnelState.ERROR -> stopRotator()
                    TunnelState.CONNECTING, TunnelState.DISCONNECTING -> { /* transient */ }
                }
            }
        }
    }

    // ---- Identity -------------------------------------------------------

    /**
     * Ensure the device has a local Rosenpass static keypair. Idempotent:
     * if one already exists it is loaded and its public key published;
     * otherwise a fresh one is generated (post-quantum keygen — done on a
     * large-stack worker thread) and persisted.
     */
    suspend fun ensureLocalKeypair() = withContext(Dispatchers.IO) {
        if (keyStore.hasLocalKeypair()) {
            try {
                _localRosenpassPublicKeyB64.value = keyStore.loadLocalKeypair().publicB64
                return@withContext
            } catch (e: Exception) {
                Log.w(TAG, "local Rosenpass keypair unreadable, regenerating: ${e.message}")
                keyStore.clearLocalKeypair()
            }
        }
        generateAndPersistLocalKeypair()
    }

    private suspend fun generateAndPersistLocalKeypair() {
        // generateStaticKeypair materializes a ~524 KB Classic McEliece
        // public key and needs an ample stack — see RosenpassBridge.kt.
        val kp = onLargeStack { RosenpassBridge.generateKeypair() }
        val secretB64 = Base64.getEncoder().encodeToString(kp.secretKey)
        val publicB64 = Base64.getEncoder().encodeToString(kp.publicKey)
        keyStore.saveLocalKeypair(secretB64, publicB64)
        _localRosenpassPublicKeyB64.value = publicB64
        Log.i(TAG, "generated local Rosenpass keypair (pk=${kp.publicKey.size} B)")
    }

    /**
     * Ensure the device has a local WireGuard keypair. Idempotent. The
     * Curve25519 keygen is cheap, so no large stack is needed.
     */
    suspend fun ensureLocalWgKeypair() {
        if (keyStore.hasLocalWgKeypair()) return
        val pair = withContext(Dispatchers.Default) {
            val kp = KeyPair()
            kp.privateKey.toBase64() to kp.publicKey.toBase64()
        }
        keyStore.saveLocalWgKeypair(secretB64 = pair.first, publicB64 = pair.second)
        Log.i(TAG, "generated local WireGuard keypair")
    }

    // ---- Region selection / provisioning --------------------------------

    /**
     * Customer-facing region selection. Provisions the device against
     * [region] (or reuses a cached config), imports the result, and
     * persists the choice. If the tunnel was already up against a
     * different region it is bounced onto the new one.
     *
     * Idempotent and safe to re-tap: the server derives the peer name
     * from the Rosenpass pubkey hash, so re-selecting re-registers the
     * same peer.
     */
    suspend fun selectRegion(region: LatticeRegion) {
        if (_regionSelectionInProgress.value) return
        _regionSelectionInProgress.value = true
        _lastRegionError.value = null
        try {
            val wasActive = repository.state.value.let {
                it == TunnelState.CONNECTED || it == TunnelState.CONNECTING
            }
            val switching = _selectedRegion.value?.id != region.id

            // Fast path — region already provisioned this install.
            val cached = loadCachedConfig(region.id)
            if (cached != null) {
                try {
                    importConfig(cached)
                    setSelectedRegion(region)
                    Log.i(TAG, "selectRegion(${region.id}): cache hit")
                    reconnectIfWasActive(wasActive, switching)
                    return
                } catch (e: Exception) {
                    Log.w(TAG, "cached config for ${region.id} bad (${e.message}); re-provisioning")
                    clearCachedConfig(region.id)
                }
            }

            // Full provision.
            Log.i(TAG, "selectRegion(${region.id}): provisioning via ${region.serverURL}")
            val configText = provisionConfig(region)
            importConfig(configText)
            setSelectedRegion(region)
            saveCachedConfig(region.id, configText)
            reconnectIfWasActive(wasActive, switching)
        } catch (e: Exception) {
            val msg = e.message ?: e.javaClass.simpleName
            Log.e(TAG, "selectRegion(${region.id}) failed: $msg")
            _lastRegionError.value = "${region.displayName}: $msg"
        } finally {
            _regionSelectionInProgress.value = false
        }
    }

    /**
     * Background pre-provision of the most-likely region so a later tap
     * is a local cache hit. Failures are silent (logged only). Mirrors
     * the iOS `warmUpPreferredRegion`.
     */
    suspend fun warmUpPreferredRegion() {
        val target = _selectedRegion.value
            ?: LatticeRegion.byId("us-west-1")
            ?: LatticeRegion.all.firstOrNull()
            ?: return
        if (loadCachedConfig(target.id) != null) return
        try {
            val configText = provisionConfig(target)
            saveCachedConfig(target.id, configText)
            Log.i(TAG, "warmUp(${target.id}): cached")
        } catch (e: Exception) {
            Log.w(TAG, "warmUp(${target.id}) failed silently: ${e.message}")
        }
    }

    /**
     * Provision (or idempotently re-register) the device against
     * [region] and return the raw config block. Ensures both keypairs
     * exist first; only public keys are sent to the server.
     */
    private suspend fun provisionConfig(region: LatticeRegion): String {
        ensureLocalKeypair()
        ensureLocalWgKeypair()
        val keys = withContext(Dispatchers.IO) {
            keyStore.loadLocalKeypair() to keyStore.loadLocalWgKeypair()
        }
        return provisioningClient.provision(
            serverBase = region.serverURL,
            wgPubkeyB64 = keys.second.publicB64,
            rosenpassPubkeyB64 = keys.first.publicB64,
            peerName = null, // server derives a name from the rp pubkey hash
        )
    }

    /**
     * Parse a raw config block, fill in the device's WireGuard private
     * key (server configs omit it), persist the server's Rosenpass
     * public key, and hand the result to [TunnelRepository].
     */
    suspend fun importConfig(text: String) = withContext(Dispatchers.IO) {
        var cfg = ConfigParser.parse(text)

        // cloak-api-server omits private_key — the device holds its own
        // WireGuard secret. Fill it in. Legacy pasted configs that carry
        // a private_key keep it untouched.
        if (cfg.wgPrivateKey.isEmpty()) {
            val wg = try {
                keyStore.loadLocalWgKeypair()
            } catch (e: Exception) {
                throw IllegalStateException(
                    "config has no private_key and no local WireGuard keypair: ${e.message}"
                )
            }
            cfg = cfg.copy(wgPrivateKey = wg.secretB64)
        }

        // Persist the server's Rosenpass public key (or clear a stale one
        // when importing a non-PQ config) before the config goes live.
        if (cfg.pqEnabled) {
            if (cfg.serverRPPublicKeyB64.isEmpty()) {
                throw IllegalStateException("PQ enabled but server_public_key_b64 is empty")
            }
            keyStore.saveServerPublicKey(cfg.serverRPPublicKeyB64)
        } else {
            keyStore.clearServerPublicKey()
        }

        repository.applyConfig(cfg)
    }

    /**
     * If the tunnel was active and the user switched to a different
     * region, bounce the tunnel onto the freshly imported config —
     * `GoBackend` does not pick up a new config mid-flight.
     */
    private suspend fun reconnectIfWasActive(wasActive: Boolean, switching: Boolean) {
        if (!wasActive || !switching) return
        Log.i(TAG, "region switched while connected — bouncing tunnel")
        disconnect()
        // Poll until the tunnel has actually settled DOWN before
        // reconnecting, so the new connect does not race the teardown.
        val deadline = System.currentTimeMillis() + SETTLE_TIMEOUT_MS
        while (System.currentTimeMillis() < deadline &&
            repository.state.value != TunnelState.DISCONNECTED
        ) {
            delay(200)
        }
        delay(500) // brief beat for the VpnService to fully release
        connect()
    }

    // ---- Tunnel control -------------------------------------------------

    /** Bring the tunnel up against the imported config. */
    fun connect() = repository.connect()

    /** Tear the tunnel down. The Rosenpass rotator stops with it. */
    fun disconnect() = repository.disconnect()

    // ---- Rosenpass rotator ----------------------------------------------

    private suspend fun startRotatorIfNeeded() {
        if (rotator?.isRunning() == true) return
        // A prior rotator that is no longer running must be torn down
        // (status + watchdog jobs cancelled, executor released) before a
        // fresh one is created.
        if (rotator != null) stopRotator()
        val cfg = repository.config.value ?: return
        if (!cfg.pqEnabled) {
            Log.i(TAG, "config has no rosenpass section — skipping PQC rotation")
            return
        }

        // Live mid-session PSK rotation is gated behind LIVE_ROTATION_ENABLED
        // (currently OFF — see that constant). OFF: one handshake per
        // connection (SESSION_PSK_LIFETIME_SEC), no watchdog — the
        // proven-stable mode. ON: re-key every cfg.pskRotationSeconds with
        // the desync watchdog active. The handshake hardening, seamless-path
        // PSK persistence and watchdog/recovery code all stay compiled in
        // either way; only this gate changes behaviour.
        val rotationSeconds =
            if (LIVE_ROTATION_ENABLED) cfg.pskRotationSeconds else SESSION_PSK_LIFETIME_SEC
        val r = buildRotator(rotationSeconds) ?: return
        rotator = r
        r.start()
        rotatorStatusJob = scope.launch {
            r.status.collect { st ->
                _rosenpassStatus.value = st
                // A healthy rotation means whatever was wrong is resolved
                // — refill the recovery budget.
                if (st is RosenpassStatus.Established) recoveryAttempts = 0
            }
        }
        // The desync watchdog only makes sense while rotation is live —
        // with one handshake per connection there is nothing to recover.
        if (LIVE_ROTATION_ENABLED) {
            rotatorWatchdogJob = scope.launch {
                r.consecutiveFailures.collect { fails ->
                    if (fails >= DESYNC_FAILURE_THRESHOLD) triggerRecovery()
                }
            }
        }
        Log.i(TAG, "Rosenpass rotator started (rotation=${rotationSeconds}s, " +
            "live rotation ${if (LIVE_ROTATION_ENABLED) "ENABLED" else "disabled"})")
    }

    private fun stopRotator() {
        rotatorStatusJob?.cancel()
        rotatorStatusJob = null
        rotatorWatchdogJob?.cancel()
        rotatorWatchdogJob = null
        rotator?.let {
            it.stop()
            Log.i(TAG, "Rosenpass rotator stopped")
        }
        rotator = null
        _rosenpassStatus.value = RosenpassStatus.Idle
    }

    /**
     * Construct a [RosenpassRotator] from the active config + stored key
     * material, or null if anything required is missing (the reason is
     * logged and surfaced on [rosenpassStatus]).
     *
     * [rotationSeconds] is the interval between handshakes — the live
     * rotation cadence for the steady-state rotator, or
     * [SESSION_PSK_LIFETIME_SEC] for the one-shot recovery handshake.
     */
    private suspend fun buildRotator(rotationSeconds: Int): RosenpassRotator? {
        val cfg = repository.config.value ?: return null
        if (!cfg.pqEnabled) return null

        // Heavy key reads (the McEliece blobs are ~700 KB) off the main thread.
        val keyMaterial: Pair<KeyStore.Keypair, String> = try {
            withContext(Dispatchers.IO) {
                keyStore.loadLocalKeypair() to keyStore.loadServerPublicKey()
            }
        } catch (e: Exception) {
            Log.e(TAG, "cannot start Rosenpass — key material missing: ${e.message}")
            _rosenpassStatus.value = RosenpassStatus.Error("PQC keys unavailable")
            return null
        }

        val endpoint = parseEndpoint(cfg.rpEndpoint)
        if (endpoint == null) {
            Log.e(TAG, "cannot start Rosenpass — bad endpoint '${cfg.rpEndpoint}'")
            _rosenpassStatus.value = RosenpassStatus.Error("bad rosenpass endpoint")
            return null
        }

        return RosenpassRotator(
            context = context,
            clientSecretKeyB64 = keyMaterial.first.secretB64,
            clientPublicKeyB64 = keyMaterial.first.publicB64,
            serverPublicKeyB64 = keyMaterial.second,
            serverHost = endpoint.first,
            serverPort = endpoint.second,
            rotationSeconds = rotationSeconds,
            // Seamless in-place apply via the custom libwg-go's wgSetConfig;
            // falls back to a tunnel reconfigure if that library is absent.
            applicator = UapiPskApplicator(
                peerPublicKeyB64 = cfg.peerPublicKey,
                repository = repository,
                fallback = ReconfiguringPskApplicator(repository),
            ),
        )
    }

    // ---- Desync recovery ------------------------------------------------

    /**
     * Launch [recoverDeadTunnel] unless a recovery is already running or
     * the recovery budget for this connection is spent.
     */
    private fun triggerRecovery() {
        if (recoveryInProgress) return
        if (recoveryAttempts >= MAX_AUTO_RECOVERIES) {
            Log.e(TAG, "post-quantum auto-recovery budget spent ($recoveryAttempts) — " +
                "leaving the tunnel for a manual reconnect")
            return
        }
        recoveryInProgress = true
        scope.launch {
            try {
                recoverDeadTunnel()
            } catch (e: Exception) {
                Log.e(TAG, "tunnel recovery failed: ${e.message}")
            } finally {
                recoveryInProgress = false
            }
        }
    }

    /**
     * Repair a tunnel that a post-quantum PSK desync has deadlocked.
     *
     * A desync is unrecoverable from *inside* the tunnel: the Rosenpass
     * handshake rides within it, so once the tunnel is black the handshake
     * that would fix it cannot get out. The escape is to tear the tunnel
     * down first — with it down, the very same handshake travels over the
     * plain internet straight to the concentrator's public Rosenpass
     * listener. That re-keys both ends (the server installs the derived
     * PSK on its `wg0` exactly as in steady state), after which a normal
     * reconnect comes up with client and server agreed again.
     */
    private suspend fun recoverDeadTunnel() {
        recoveryAttempts += 1
        Log.w(TAG, "post-quantum desync suspected — recovering tunnel (attempt $recoveryAttempts)")

        stopRotator()
        disconnect()
        awaitTunnelState(TunnelState.DISCONNECTED, SETTLE_TIMEOUT_MS)
        delay(500) // brief beat for the VpnService to fully release
        _rosenpassStatus.value = RosenpassStatus.Error("recovering tunnel…")

        // One Rosenpass handshake with the tunnel DOWN. Its PSK apply
        // finds no live tunnel and so just records + persists the key
        // (TunnelRepository.applyPresharedKey); the connect() below then
        // bakes it into the fresh tunnel.
        val recoveryRotator = buildRotator(SESSION_PSK_LIFETIME_SEC)
        if (recoveryRotator != null) {
            recoveryRotator.start()
            val ok = awaitFirstRotation(recoveryRotator, RECOVERY_HANDSHAKE_TIMEOUT_MS)
            recoveryRotator.stop()
            if (ok) {
                Log.i(TAG, "recovery handshake complete — fresh PSK in place")
            } else {
                Log.e(TAG, "recovery handshake did not complete in time")
            }
        }

        // Reconnect. The CONNECTED transition restarts the steady-state
        // rotator (and its watchdog) via the tunnel-state collector.
        connect()
    }

    /** Suspend until the rotator reports its first successful rotation, or [timeoutMs] elapses. */
    private suspend fun awaitFirstRotation(r: RosenpassRotator, timeoutMs: Long): Boolean =
        withTimeoutOrNull(timeoutMs) {
            r.status.first { it is RosenpassStatus.Established }
            true
        } ?: false

    /** Suspend until the tunnel reaches [target], or [timeoutMs] elapses. */
    private suspend fun awaitTunnelState(target: TunnelState, timeoutMs: Long) {
        withTimeoutOrNull(timeoutMs) {
            repository.state.first { it == target }
        }
    }

    // ---- Internals ------------------------------------------------------

    /** Split a `host:port` endpoint. Returns null if malformed. */
    private fun parseEndpoint(endpoint: String): Pair<String, Int>? {
        val trimmed = endpoint.trim()
        val idx = trimmed.lastIndexOf(':')
        if (idx <= 0 || idx == trimmed.length - 1) return null
        val host = trimmed.substring(0, idx).trim()
        val port = trimmed.substring(idx + 1).trim().toIntOrNull() ?: return null
        if (host.isEmpty() || port !in 1..65535) return null
        return host to port
    }

    private fun setSelectedRegion(region: LatticeRegion) {
        _selectedRegion.value = region
        prefs.edit().putString(KEY_SELECTED_REGION, region.id).apply()
    }

    private fun loadCachedConfig(regionId: String): String? =
        prefs.getString(KEY_PROVISIONED_PREFIX + regionId, null)

    private fun saveCachedConfig(regionId: String, text: String) {
        prefs.edit().putString(KEY_PROVISIONED_PREFIX + regionId, text).apply()
    }

    private fun clearCachedConfig(regionId: String) {
        prefs.edit().remove(KEY_PROVISIONED_PREFIX + regionId).apply()
    }

    /**
     * Run [block] on a fresh daemon thread with a 16 MiB stack and
     * suspend until it completes. The Android analogue of the iOS
     * `Task.detached` used for post-quantum keygen.
     */
    private suspend fun <T> onLargeStack(block: () -> T): T =
        suspendCancellableCoroutine { cont ->
            val worker = Thread(null, {
                try {
                    cont.resume(block())
                } catch (t: Throwable) {
                    cont.resumeWithException(t)
                }
            }, "lattice-keygen", LARGE_STACK_BYTES)
            worker.isDaemon = true
            worker.start()
        }

    companion object {
        @SuppressLint("StaticFieldLeak") // holds only the application context
        @Volatile
        private var instance: TunnelManager? = null

        fun get(ctx: Context): TunnelManager =
            instance ?: synchronized(this) {
                instance ?: TunnelManager(ctx.applicationContext).also { instance = it }
            }

        private const val TAG = "TunnelManager"
        private const val PREFS_NAME = "lattice"
        private const val KEY_SELECTED_REGION = "selected_region_id"
        private const val KEY_PROVISIONED_PREFIX = "provisioned_config_"

        /**
         * Master switch for mid-session post-quantum PSK rotation.
         *
         * OFF (current): one Rosenpass handshake per connection — the
         * proven-stable mode. The key is still post-quantum; it simply is
         * not re-keyed mid-session, and the desync watchdog is dormant.
         *
         * ON: re-key every `cfg.pskRotationSeconds` with the watchdog
         * active. Enabled now that the Rosenpass handshake runs OUTSIDE
         * the WireGuard tunnel (RosenpassTransport binds its socket to the
         * underlying network) — a rotation no longer depends on tunnel
         * health, so it cannot deadlock and a desync self-heals on the
         * next cycle. See SESSION_HANDOVER_2026-05-23_pqc-rotation.md.
         */
        private const val LIVE_ROTATION_ENABLED = true

        /**
         * Rotation interval used both for the one-shot recovery rotator
         * and, while [LIVE_ROTATION_ENABLED] is false, for the steady
         * rotator — large enough that it performs exactly one handshake
         * per connection and then idles. 24 h exceeds any real session.
         */
        private const val SESSION_PSK_LIFETIME_SEC = 24 * 60 * 60

        /** How long to wait for the tunnel to settle DOWN during a region switch or recovery. */
        private const val SETTLE_TIMEOUT_MS = 8_000L

        /**
         * Consecutive Rosenpass handshake failures that trip the desync
         * watchdog. A black tunnel fails *every* handshake (the Rosenpass
         * UDP rides inside it), so a run this long is conclusive while
         * still tolerating isolated transient losses.
         */
        private const val DESYNC_FAILURE_THRESHOLD = 4

        /**
         * Cap on automatic recover→reconnect cycles per connection with no
         * intervening healthy rotation — stops an endless bounce loop when
         * the fault is durable (e.g. the concentrator is down).
         */
        private const val MAX_AUTO_RECOVERIES = 3

        /** How long the recovery handshake gets to complete before reconnecting anyway. */
        private const val RECOVERY_HANDSHAKE_TIMEOUT_MS = 60_000L

        private const val LARGE_STACK_BYTES = 16L * 1024 * 1024
    }
}
