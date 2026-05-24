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
     * The current Rosenpass-derived preshared key for the active server,
     * or null when there is no post-quantum PSK yet. Baked into the
     * WireGuard config by [buildWgConfig]; written by [applyPresharedKey].
     *
     * Persisted per server (keyed by the server's WireGuard public key)
     * and reloaded on launch and whenever a config is installed. This is
     * what lets a disconnect -> reconnect succeed: the server keeps the
     * PSK it last negotiated, so the client must reconnect with the SAME
     * key — WireGuard mixes the PSK into its handshake, so a mismatch
     * makes the handshake (and the whole tunnel) fail silently.
     */
    @Volatile
    private var currentPsk: ByteArray? = _config.value?.let { loadPsk(it.peerPublicKey) }

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
        // Load the PSK last negotiated with *this* server, so a connect
        // (including after switching regions) presents the key the server
        // still holds. Null when this server has never been connected to.
        currentPsk = loadPsk(cfg.peerPublicKey)
    }

    /**
     * Drop the imported config and every per-server PSK. Used on
     * sign-out so a different account's config can never linger. Does
     * not touch the device's own keypairs (those are hardware identity,
     * not account data).
     */
    fun clearConfig() {
        _config.value = null
        currentPsk = null
        val p = appCtx.getSharedPreferences("lattice", Context.MODE_PRIVATE)
        val editor = p.edit()
        editor.remove("config")
        for (key in p.all.keys) {
            if (key.startsWith("psk_")) editor.remove(key)
        }
        editor.apply()
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
        // The post-quantum PSK is deliberately KEPT (and stays persisted).
        // The server does not reset this peer's PSK on disconnect, so the
        // next connect must re-present the same key for the WireGuard
        // handshake to succeed; the Rosenpass rotator refreshes it once
        // the tunnel is back up.
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
        // Persist per server so a later reconnect re-presents this exact
        // key — the server keeps it until the next rotation.
        persistPsk(cfg.peerPublicKey, psk)
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

    /**
     * Record a PSK that has ALREADY been applied to the live tunnel out
     * of band — i.e. by the seamless [UapiPskApplicator], which updates
     * wireguard-go directly via `wgSetConfig` and never goes through
     * [applyPresharedKey].
     *
     * Without this, every seamless rotation leaves [currentPsk] and the
     * persisted per-server PSK stale: the next reconnect (or region
     * switch, or a later fallback bounce) rebuilds the config from the
     * wrong key, and the WireGuard handshake then desyncs against the
     * server, which still holds the rotated key. This keeps the persisted
     * record in lockstep with what is actually live on the tunnel. It
     * does NOT touch the tunnel — the key is already in effect.
     */
    fun recordRotatedPsk(psk: ByteArray) {
        require(psk.size == 32) { "PresharedKey must be 32 bytes, got ${psk.size}" }
        currentPsk = psk
        _config.value?.let { persistPsk(it.peerPublicKey, psk) }
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
            // The account-number API assigns an IPv4 address only, so
            // addressV6 is often empty — emit just the addresses we have
            // rather than a trailing-comma "Address" the parser rejects.
            val addresses = listOf(cfg.addressV4, cfg.addressV6)
                .filter { it.isNotBlank() }
                .joinToString(", ")
            appendLine("Address = $addresses")
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

    // ---- Per-server PSK persistence ------------------------------------
    //
    // The Rosenpass PSK is stored per server (keyed by the server's
    // WireGuard public key) so that disconnect -> reconnect — and region
    // switches — re-present the exact key the server still holds. Without
    // this the client reconnects with no PSK while the server keeps the
    // last one, the WireGuard handshake fails on the PSK mismatch, and
    // the tunnel deadlocks (Rosenpass can't recover — its handshake rides
    // inside the dead tunnel).

    private fun pskKey(serverPublicKey: String): String =
        "psk_" + serverPublicKey.filter { it.isLetterOrDigit() }

    private fun persistPsk(serverPublicKey: String, psk: ByteArray) {
        appCtx.getSharedPreferences("lattice", Context.MODE_PRIVATE)
            .edit()
            .putString(pskKey(serverPublicKey), Base64.getEncoder().encodeToString(psk))
            .apply()
    }

    /** The last PSK negotiated with [serverPublicKey], or null if none. */
    private fun loadPsk(serverPublicKey: String): ByteArray? {
        val raw = appCtx.getSharedPreferences("lattice", Context.MODE_PRIVATE)
            .getString(pskKey(serverPublicKey), null) ?: return null
        return runCatching { Base64.getDecoder().decode(raw) }
            .getOrNull()
            ?.takeIf { it.size == 32 }
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
