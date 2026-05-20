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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.StringReader

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

    /** The wireguard-android backend. Created lazily on first use. */
    private val backend: Backend by lazy { GoBackend(appCtx) }

    /** Our single tunnel instance — name + state-change callback. */
    private val tunnel = LatticeTunnel { backendState ->
        _state.value = when (backendState) {
            Tunnel.State.UP   -> TunnelState.CONNECTED
            Tunnel.State.DOWN -> TunnelState.DISCONNECTED
            else              -> _state.value   // TOGGLE — transient
        }
    }

    // MARK: - Config

    fun importConfig(text: String) {
        val parsed = ConfigParser.parse(text)
        _config.value = parsed
        persist(parsed)
    }

    // MARK: - Tunnel control

    fun connect() {
        val cfg = _config.value ?: return
        if (_state.value == TunnelState.CONNECTED || _state.value == TunnelState.CONNECTING) return
        _state.value = TunnelState.CONNECTING
        scope.launch {
            try {
                val wgConfig = withContext(Dispatchers.Default) { buildWgConfig(cfg) }
                withContext(Dispatchers.IO) {
                    backend.setState(tunnel, Tunnel.State.UP, wgConfig)
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
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    backend.setState(tunnel, Tunnel.State.DOWN, null)
                }
            } catch (_: Exception) {
                // Best-effort — treat a failed teardown as down anyway.
            }
            _state.value = TunnelState.DISCONNECTED
        }
    }

    // MARK: - LatticeConfig -> wireguard Config

    /**
     * Translate our [LatticeConfig] into a wireguard-android [Config]
     * by emitting a wg-quick-format block and parsing it. Using the
     * parser (rather than the Interface/Peer builders) means the
     * library does all the address / endpoint / CIDR validation.
     *
     * PresharedKey is intentionally omitted here — the rosenpass
     * post-quantum PSK is applied dynamically in Phase A5, not baked
     * into the static config.
     */
    private fun buildWgConfig(cfg: LatticeConfig): Config {
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
