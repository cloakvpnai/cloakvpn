package com.cloakvpn.app.vpn

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class TunnelState { DISCONNECTED, CONNECTING, CONNECTED, DISCONNECTING, ERROR }

/**
 * App-wide, process-scoped tunnel repository. Holds the parsed config and
 * delegates actual tunnel I/O to wireguard-android's GoBackend.
 *
 * In Phase 0 this is a thin skeleton. Connect with the real backend:
 *
 *     import com.wireguard.android.backend.GoBackend
 *     import com.wireguard.android.backend.Tunnel
 *     import com.wireguard.config.Config
 *
 *     private val backend by lazy { GoBackend(appCtx) }
 *     fun connect() {
 *         val wgConfig: Config = toWgConfig(state.config)
 *         backend.setState(tunnel, Tunnel.State.UP, wgConfig)
 *     }
 */
class TunnelRepository private constructor(private val appCtx: Context) {

    private val _state = MutableStateFlow(TunnelState.DISCONNECTED)
    val state: StateFlow<TunnelState> = _state.asStateFlow()

    private val _config = MutableStateFlow<CloakConfig?>(loadPersisted())
    val config: StateFlow<CloakConfig?> = _config.asStateFlow()

    fun importConfig(text: String) {
        val parsed = ConfigParser.parse(text)
        _config.value = parsed
        persist(parsed)
    }

    fun connect() {
        val cfg = _config.value ?: return
        _state.value = TunnelState.CONNECTING
        // Start the foreground service — required for API 34+.
        val intent = Intent(appCtx, CloakVpnService::class.java)
        ContextCompat.startForegroundService(appCtx, intent)

        // TODO: wire wireguard-android GoBackend:
        //   backend.setState(tunnel, Tunnel.State.UP, cfg.toWgConfig())
        // Then start Rosenpass loop:
        //   RosenpassBridge.start(cfg)
        _state.value = TunnelState.CONNECTED
    }

    fun disconnect() {
        _state.value = TunnelState.DISCONNECTING
        // TODO: backend.setState(tunnel, Tunnel.State.DOWN, null)
        // RosenpassBridge.stop()
        appCtx.stopService(Intent(appCtx, CloakVpnService::class.java))
        _state.value = TunnelState.DISCONNECTED
    }

    // MARK: - Simple persistence

    private fun persist(cfg: CloakConfig) {
        val p = appCtx.getSharedPreferences("cloak", Context.MODE_PRIVATE)
        p.edit().putString("config", cfg.serialize()).apply()
    }

    private fun loadPersisted(): CloakConfig? {
        val p = appCtx.getSharedPreferences("cloak", Context.MODE_PRIVATE)
        val raw = p.getString("config", null) ?: return null
        return runCatching { CloakConfig.deserialize(raw) }.getOrNull()
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
