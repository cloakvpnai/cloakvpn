package ai.latticevpn.android.ui

import ai.latticevpn.android.data.LatticeRegion
import ai.latticevpn.android.vpn.RosenpassStatus
import ai.latticevpn.android.vpn.TunnelManager
import ai.latticevpn.android.vpn.TunnelState
import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** The three top-level destinations in the A6 UI. */
enum class Screen { HOME, REGIONS, SETTINGS }

/**
 * UI-facing state holder for Phase A6.
 *
 * Almost all real state already lives in the process-wide
 * [TunnelManager] (Phase A5) — this view model is a thin Compose-shaped
 * layer over it. It adds three things the manager has no opinion on:
 * in-app navigation, app-local preferences (auto-connect), and a
 * coroutine scope for firing the manager's `suspend` actions.
 */
class LatticeViewModel(app: Application) : AndroidViewModel(app) {

    private val tm = TunnelManager.get(app)
    private val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ---- Tunnel / region state — delegated straight from TunnelManager ----

    val tunnelState: StateFlow<TunnelState> get() = tm.tunnelState
    val tunnelConfig get() = tm.tunnelConfig
    val selectedRegion: StateFlow<LatticeRegion?> get() = tm.selectedRegion
    val regionSelectionInProgress: StateFlow<Boolean> get() = tm.regionSelectionInProgress
    val lastRegionError: StateFlow<String?> get() = tm.lastRegionError
    val rosenpassStatus: StateFlow<RosenpassStatus> get() = tm.rosenpassStatus
    val localRosenpassPublicKeyB64: StateFlow<String?> get() = tm.localRosenpassPublicKeyB64

    // ---- Navigation ------------------------------------------------------

    private val _screen = MutableStateFlow(Screen.HOME)
    val screen: StateFlow<Screen> = _screen.asStateFlow()

    fun navigateTo(target: Screen) { _screen.value = target }
    fun navigateHome() { _screen.value = Screen.HOME }

    // ---- App preferences -------------------------------------------------

    private val _autoConnect = MutableStateFlow(prefs.getBoolean(KEY_AUTO_CONNECT, false))
    /** Whether the tunnel should be brought up automatically on app launch. */
    val autoConnect: StateFlow<Boolean> = _autoConnect.asStateFlow()

    fun setAutoConnect(enabled: Boolean) {
        _autoConnect.value = enabled
        prefs.edit().putBoolean(KEY_AUTO_CONNECT, enabled).apply()
    }

    /** Synchronous read for the launch-time auto-connect decision. */
    fun autoConnectEnabled(): Boolean = _autoConnect.value

    /** True once a config has been imported (region-provisioned or pasted). */
    fun hasConfig(): Boolean = tm.tunnelConfig.value != null

    // ---- Manual config import (Settings → Advanced) ----------------------

    private val _importError = MutableStateFlow<String?>(null)
    val importError: StateFlow<String?> = _importError.asStateFlow()

    fun clearImportError() { _importError.value = null }

    // ---- Lifecycle -------------------------------------------------------

    init {
        // Warm-up: generate the device identity keypairs and pre-provision
        // the preferred region in the background so the first region tap is
        // a local cache hit. All failures are swallowed — this is purely an
        // optimization and the user-driven path re-runs every step anyway.
        viewModelScope.launch {
            runCatching {
                tm.ensureLocalKeypair()
                tm.ensureLocalWgKeypair()
                tm.warmUpPreferredRegion()
            }
        }
    }

    // ---- Actions ---------------------------------------------------------

    /**
     * Provision (or switch to) [region] and, on success, return to Home.
     * [TunnelManager.selectRegion] never throws — it records any failure
     * in [lastRegionError] — so the completion is keyed off that flow.
     */
    fun selectRegion(region: LatticeRegion, onComplete: (error: String?) -> Unit) {
        viewModelScope.launch {
            tm.selectRegion(region)
            onComplete(tm.lastRegionError.value)
        }
    }

    fun connect() = tm.connect()

    fun disconnect() = tm.disconnect()

    /** Parse and apply a manually pasted config block. */
    fun importConfig(text: String, onSuccess: () -> Unit) {
        viewModelScope.launch {
            try {
                tm.importConfig(text)
                _importError.value = null
                onSuccess()
            } catch (e: Exception) {
                _importError.value = e.message ?: "That config could not be parsed."
            }
        }
    }

    companion object {
        private const val PREFS = "lattice"
        private const val KEY_AUTO_CONNECT = "pref_auto_connect"
    }
}
