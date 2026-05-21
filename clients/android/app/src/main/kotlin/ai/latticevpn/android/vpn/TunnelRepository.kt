package ai.latticevpn.android.vpn

import android.annotation.SuppressLint
import android.content.Context
import com.wireguard.android.backend.Backend
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.StringReader
import java.util.Base64

enum class TunnelState { DISCONNECTED, CONNECTING, CONNECTED, DISCONNECTING, ERROR }

/**
 * App-wide, process-scoped tunnel repository. Holds the parsed config
 * and drives the actual tunnel through wireguard-android's [GoBackend].
 *
 * Architecture:
 *   - GoBackend wraps the Go userspace WireGuard implementation and
 *     owns its own VpnService (com.wireguard.android.backend.GoBackend
 *     $VpnService), which the library's AndroidManifest declares — so
 *     we don't declare a VpnService ourselves.
 *   - [LatticeTunnel] is our [Tunnel] implementation: a named tunnel
 *     whose onStateChange callback mirrors the backend's state into
 *     our [state] StateFlow for the Compose UI.
 *   - backend.setState(tunnel, UP, config) blocks (network + VpnService
 *     bring-up), so connect/disconnect run on Dispatchers.IO.
 *
 * Post-quantum: the WireGuard handshake here is the classical layer.
 * Rosenpass PSK rotation (mixing a post-quantum-derived preshared key
 * into the tunnel) is wired in Phase A5 via RosenpassBridge — the
 * tunnel is fully functional without it; the server still enforces
 * PQC posture.
 */
class TunnelRepository private constructor(private val appCtx: Context) {

    private val _state = MutableStateFlow(TunnelState.DISCONNECTED)
    val state: StateFlow<TunnelState> = _state.asStateFlow()

    private val _config = MutableStateFlow<LatticeConfig?>(loadPersisted())
    val config: StateFlow<LatticeConfig?> = _config.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /**
     * Serializes every tunnel state transition (connect / disconnect /
     * PSK reconfigure). `GoBackend` is not internally synchronized, and
     * with the Rosenpass rotator now also driving reconfigures, two
     * `setState` calls could otherwise interleave and corrupt its state.
     */
    private val tunnelMutex = Mutex()

    /** The wireguard-android backend. Created lazily on first use. */
    private val backend: Backend by lazy { GoBackend(appCtx) }

    /**
     * The current Rosenpass-derived preshared key, or null when the
     * tunnel is running with no post-quantum PSK yet. Baked into the
     * WireGuard config by [buildWgConfig]; written by [applyPresharedKey].
     */
    @Volatile
    private var currentPsk: ByteArray? = null

    /**
     * True only while [applyPresharedKey] is bouncing the tunnel to apply
     * a rotated PSK. Used to swallow the transient DOWN that GoBackend
     * emits mid-reconfigure so the UI does not flicker every rotation.
     */
    @Volatile
    private var reconfiguring = false

    /** Our single tunnel instance — name + state-change callback. */
    private val tunnel = LatticeTunnel { backendState ->
        // GoBackend has no live-reconfigure path: applying a rotated PSK
        // bounces the tunnel DOWN then UP. Swallow that transient DOWN so
        // observers don't see a spurious disconnect every rotation.
        if (reconfiguring && backendState == Tunnel.State.DOWN) {
            return@LatticeTunnel
        }
        _state.value = when (backendState) {
            Tunnel.State.UP   -> TunnelState.CONNECTED
            Tunnel.State.DOWN -> TunnelState.DISCONNECTED
            else              -> _state.value   // TOGGLE — transient
        }
    }

    // MARK: - Config

    /** Parse and install a raw INI config block (the manual-paste path). */
    fun importConfig(text: String) {
        applyConfig(ConfigParser.parse(text))
    }

    /**
     * Install a pre-parsed config. Used by [TunnelManager], which fills
     * in the device's locally generated WireGuard private key (and
     * persists the server's Rosenpass public key) before handing the
     * config over.
     */
    fun applyConfig(cfg: LatticeConfig) {
        _config.value = cfg
        persist(cfg)
    }

    // MARK: - Tunnel control

    fun connect() {
        val cfg = _config.value ?: return
        if (_state.value == TunnelState.CONNECTED || _state.value == TunnelState.CONNECTING) return
        _state.value = TunnelState.CONNECTING
        scope.launch {
            try {
                val wgConfig = withContext(Dispatchers.Default) { buildWgConfig(cfg) }
                tunnelMutex.withLock {
                    withContext(Dispatchers.IO) {
                        backend.setState(tunnel, Tunnel.State.UP, wgConfig)
                    }
                }
                _state.value = TunnelState.CONNECTED
            } catch (e: Exception) {
                _state.value = TunnelState.ERROR
            }
        }
    }

    fun disconnect() {
        if (_state.value == TunnelState.DISCONNECTED) return
        _state.value = TunnelState.DISCONNECTING
        // Drop the post-quantum PSK: the next connect starts a fresh
        // Rosenpass session, and the server resets this peer's PSK too.
        currentPsk = null
        scope.launch {
            try {
                tunnelMutex.withLock {
                    withContext(Dispatchers.IO) {
                        backend.setState(tunnel, Tunnel.State.DOWN, null)
                    }
                }
            } catch (_: Exception) {
                // Best-effort — treat a failed teardown as down anyway.
            }
            _state.value = TunnelState.DISCONNECTED
        }
    }

    /**
     * Apply a freshly rotated 32-byte Rosenpass PSK to the tunnel.
     *
     * The PSK is recorded so it is baked into the config on the next
     * connect. If the tunnel is currently up, it is re-established with
     * the new key.
     *
     * `GoBackend` exposes no in-place reconfigure. Worse, calling
     * `setState(UP)` directly on a running tunnel is unsafe: it tears the
     * old `VpnService` down and starts a new one, and the old service's
     * asynchronous `onDestroy` can then race and kill the freshly
     * re-established tunnel. So this does an explicit clean DOWN, waits
     * out the settle window for the old `VpnService` to be fully
     * destroyed, then a clean UP. [reconfiguring] hides the transient
     * DOWN from observers so the UI stays "connected" across the ~1-2 s
     * reconnect. See [PskApplicator] for the seamless (no-bounce)
     * upgrade path.
     */
    suspend fun applyPresharedKey(psk: ByteArray) {
        require(psk.size == 32) { "PresharedKey must be 32 bytes, got ${psk.size}" }
        currentPsk = psk
        val cfg = _config.value ?: return
        // Not up yet — the PSK is recorded and will be applied at connect.
        if (_state.value != TunnelState.CONNECTED) return
        tunnelMutex.withLock {
            reconfiguring = true
            try {
                withContext(Dispatchers.IO) {
                    backend.setState(tunnel, Tunnel.State.DOWN, null)
                }
                // Let the old VpnService finish onDestroy before the new
                // one starts — otherwise its teardown races the new UP.
                delay(RECONFIGURE_SETTLE_MS)
                withContext(Dispatchers.IO) {
                    backend.setState(tunnel, Tunnel.State.UP, buildWgConfig(cfg))
                }
            } finally {
                reconfiguring = false
                // Re-sync the published state with the backend's reality
                // in case the bounce ended somewhere unexpected.
                _state.value = when (backend.getState(tunnel)) {
                    Tunnel.State.UP -> TunnelState.CONNECTED
                    else            -> TunnelState.DISCONNECTED
                }
            }
        }
    }

    // MARK: - LatticeConfig -> wireguard Config

    /**
     * Translate our [LatticeConfig] into a wireguard-android [Config]
     * by emitting a wg-quick-format block and parsing it. Using the
     * parser (rather than the Interface/Peer builders) means the
     * library does all the address / endpoint / CIDR validation.
     *
     * When a Rosenpass-derived [currentPsk] is present it is emitted as
     * the peer's PresharedKey, so a (re)connect brings the tunnel up
     * already post-quantum-protected. [applyPresharedKey] rebuilds via
     * this method to rotate the PSK on a live tunnel.
     */
    private fun buildWgConfig(cfg: LatticeConfig): Config {
        val psk = currentPsk
        val wgQuick = buildString {
            appendLine("[Interface]")
            appendLine("PrivateKey = ${cfg.wgPrivateKey}")
            appendLine("Address = ${cfg.addressV4}, ${cfg.addressV6}")
            if (cfg.dns.isNotEmpty()) {
                appendLine("DNS = ${cfg.dns.joinToString(", ")}")
            }
            appendLine()
            appendLine("[Peer]")
            appendLine("PublicKey = ${cfg.peerPublicKey}")
            if (psk != null) {
                appendLine("PresharedKey = ${Base64.getEncoder().encodeToString(psk)}")
            }
            appendLine("Endpoint = ${cfg.endpoint}")
            appendLine("AllowedIPs = ${cfg.allowedIPs.joinToString(", ")}")
            appendLine("PersistentKeepalive = ${cfg.persistentKeepalive}")
        }
        return BufferedReader(StringReader(wgQuick)).use { Config.parse(it) }
    }

    // MARK: - Persistence

    private fun persist(cfg: LatticeConfig) {
        val p = appCtx.getSharedPreferences("lattice", Context.MODE_PRIVATE)
        p.edit().putString("config", cfg.serialize()).apply()
    }

    private fun loadPersisted(): LatticeConfig? {
        val p = appCtx.getSharedPreferences("lattice", Context.MODE_PRIVATE)
        val raw = p.getString("config", null) ?: return null
        return runCatching { LatticeConfig.deserialize(raw) }.getOrNull()
    }

    companion object {
        /**
         * Settle delay between the DOWN and UP halves of a PSK
         * reconfigure — long enough for the old VpnService's onDestroy
         * to run so it cannot race the new tunnel. onDestroy after
         * stopSelf is typically well under 100 ms; this is generous.
         */
        private const val RECONFIGURE_SETTLE_MS = 1_200L

        @SuppressLint("StaticFieldLeak")
        @Volatile private var instance: TunnelRepository? = null
        fun get(ctx: Context): TunnelRepository =
            instance ?: synchronized(this) {
                instance ?: TunnelRepository(ctx.applicationContext).also { instance = it }
            }
    }
}

/**
 * Our [Tunnel] — a named tunnel the backend drives. The name must
 * satisfy Tunnel.NAME_PATTERN (lowercase alphanumeric). The
 * [onState] lambda forwards backend state changes to the repository.
 */
private class LatticeTunnel(
    private val onState: (Tunnel.State) -> Unit
) : Tunnel {
    override fun getName(): String = "lattice"
    override fun onStateChange(newState: Tunnel.State) = onState(newState)
}
