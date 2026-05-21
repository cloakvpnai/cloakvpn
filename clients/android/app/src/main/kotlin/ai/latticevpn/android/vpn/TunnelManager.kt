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
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
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
        // (status-forwarding job cancelled, executor released) before a
        // fresh one is created.
        if (rotator != null) stopRotator()
        val cfg = repository.config.value ?: return
        if (!cfg.pqEnabled) {
            Log.i(TAG, "config has no rosenpass section — skipping PQC rotation")
            return
        }

        // Heavy key reads (the McEliece blobs are ~700 KB) off the main
        // thread.
        val keyMaterial: Pair<KeyStore.Keypair, String> = try {
            withContext(Dispatchers.IO) {
                keyStore.loadLocalKeypair() to keyStore.loadServerPublicKey()
            }
        } catch (e: Exception) {
            Log.e(TAG, "cannot start Rosenpass — key material missing: ${e.message}")
            _rosenpassStatus.value = RosenpassStatus.Error("PQC keys unavailable")
            return
        }
        val rpKeys = keyMaterial.first
        val serverPub = keyMaterial.second

        val endpoint = parseEndpoint(cfg.rpEndpoint)
        if (endpoint == null) {
            Log.e(TAG, "cannot start Rosenpass — bad endpoint '${cfg.rpEndpoint}'")
            _rosenpassStatus.value = RosenpassStatus.Error("bad rosenpass endpoint")
            return
        }

        val r = RosenpassRotator(
            clientSecretKeyB64 = rpKeys.secretB64,
            clientPublicKeyB64 = rpKeys.publicB64,
            serverPublicKeyB64 = serverPub,
            serverHost = endpoint.first,
            serverPort = endpoint.second,
            rotationSeconds = cfg.pskRotationSeconds,
            // Seamless in-place rotation via the custom libwg-go's
            // wgSetConfig; automatically falls back to a tunnel
            // reconfigure if that native library is not present.
            applicator = UapiPskApplicator(
                peerPublicKeyB64 = cfg.peerPublicKey,
                fallback = ReconfiguringPskApplicator(repository),
            ),
        )
        rotator = r
        r.start()
        rotatorStatusJob = scope.launch {
            r.status.collect { _rosenpassStatus.value = it }
        }
        Log.i(TAG, "Rosenpass rotator started (rotation=${cfg.pskRotationSeconds}s)")
    }

    private fun stopRotator() {
        rotatorStatusJob?.cancel()
        rotatorStatusJob = null
        rotator?.let {
            it.stop()
            Log.i(TAG, "Rosenpass rotator stopped")
        }
        rotator = null
        _rosenpassStatus.value = RosenpassStatus.Idle
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

        /** How long to wait for the tunnel to settle DOWN during a region switch. */
        private const val SETTLE_TIMEOUT_MS = 8_000L

        private const val LARGE_STACK_BYTES = 16L * 1024 * 1024
    }
}
