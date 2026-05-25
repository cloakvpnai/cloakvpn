package ai.latticevpn.android.ui

import ai.latticevpn.android.data.AccountClient
import ai.latticevpn.android.data.AccountException
import ai.latticevpn.android.data.AccountStatus
import ai.latticevpn.android.data.AccountStore
import ai.latticevpn.android.data.IpAddressClient
import ai.latticevpn.android.data.LatticeRegion
import ai.latticevpn.android.vpn.RosenpassStatus
import ai.latticevpn.android.vpn.TunnelManager
import ai.latticevpn.android.vpn.TunnelState
import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** The top-level destinations in the UI. */
enum class Screen { SIGN_IN, HOME, REGIONS, SETTINGS, ACCOUNT }

/** State of the public-IP lookup shown on the home screen. */
sealed class IpState {
    data object Loading : IpState()
    data class Known(val ip: String) : IpState()
    data object Unavailable : IpState()
}

/** State of the subscription lookup shown on the Account screen. */
sealed class AccountUiState {
    data object Loading : AccountUiState()
    data class Loaded(val status: AccountStatus) : AccountUiState()
    data class Failed(val message: String) : AccountUiState()
}

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
    private val ipClient = IpAddressClient()
    private val accountStore = AccountStore(app)
    private val accountClient = AccountClient(app)

    // ---- Tunnel / region state — delegated straight from TunnelManager ----

    val tunnelState: StateFlow<TunnelState> get() = tm.tunnelState
    val tunnelConfig get() = tm.tunnelConfig
    val selectedRegion: StateFlow<LatticeRegion?> get() = tm.selectedRegion
    val regionSelectionInProgress: StateFlow<Boolean> get() = tm.regionSelectionInProgress
    val lastRegionError: StateFlow<String?> get() = tm.lastRegionError
    val rosenpassStatus: StateFlow<RosenpassStatus> get() = tm.rosenpassStatus
    val localRosenpassPublicKeyB64: StateFlow<String?> get() = tm.localRosenpassPublicKeyB64

    // ---- Public IP -------------------------------------------------------

    private val _publicIp = MutableStateFlow<IpState>(IpState.Loading)
    /** Current public IP — the real address when off, the server's when on. */
    val publicIp: StateFlow<IpState> = _publicIp.asStateFlow()
    private var ipJob: Job? = null

    private val _realIp = MutableStateFlow<String?>(null)
    /** The user's real (VPN-off) IP, kept so the home screen can show the
     *  before/after once the tunnel is up. */
    val realIp: StateFlow<String?> = _realIp.asStateFlow()

    // ---- Navigation ------------------------------------------------------

    // Land on sign-in until a validated account number is stored.
    private val _screen = MutableStateFlow(
        if (accountStore.isSignedIn()) Screen.HOME else Screen.SIGN_IN,
    )
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
        // Refresh the displayed public IP whenever the tunnel settles.
        // collect() replays the current value, so this also performs the
        // initial lookup on launch.
        viewModelScope.launch {
            tm.tunnelState.collect { state ->
                when (state) {
                    TunnelState.CONNECTED -> scheduleIpRefresh(1500L)
                    TunnelState.DISCONNECTED, TunnelState.ERROR -> scheduleIpRefresh(0L)
                    TunnelState.CONNECTING, TunnelState.DISCONNECTING -> { /* transient */ }
                }
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

    // ---- Public IP -------------------------------------------------------

    /** Re-run the public-IP lookup, optionally after a [delayMs] settle wait. */
    private fun scheduleIpRefresh(delayMs: Long) {
        ipJob?.cancel()
        ipJob = viewModelScope.launch {
            if (delayMs > 0L) delay(delayMs)
            _publicIp.value = IpState.Loading
            // A freshly-connected tunnel can take several seconds to
            // start carrying traffic, so retry a few times before
            // reporting the lookup as unavailable.
            repeat(IP_LOOKUP_ATTEMPTS) { attempt ->
                try {
                    val ip = ipClient.fetchPublicIp()
                    _publicIp.value = IpState.Known(ip)
                    // A lookup made while the tunnel is down sees the
                    // user's real, exposed IP — remember it.
                    if (tm.tunnelState.value == TunnelState.DISCONNECTED) {
                        _realIp.value = ip
                    }
                    return@launch
                } catch (e: Exception) {
                    if (attempt == IP_LOOKUP_ATTEMPTS - 1) {
                        _publicIp.value = IpState.Unavailable
                    } else {
                        delay(IP_LOOKUP_RETRY_MS)
                    }
                }
            }
        }
    }

    /** User-triggered retry of the public-IP lookup. */
    fun refreshPublicIp() = scheduleIpRefresh(0L)

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

    // ---- Account: sign-in, sign-out, subscription status -----------------

    /** True once a validated account number is stored. */
    fun isSignedIn(): Boolean = accountStore.isSignedIn()

    /** The stored account number (canonical hyphenated form), or null. */
    fun accountNumber(): String? = accountStore.accountNumber()

    private val _signInBusy = MutableStateFlow(false)
    /** True while a [signIn] validation round-trip is in flight. */
    val signInBusy: StateFlow<Boolean> = _signInBusy.asStateFlow()

    /**
     * Validate [accountNumber] against the server and, on success, store
     * it and move to Home. [onResult] is invoked with null on success or
     * a user-facing message on failure. The number is persisted only
     * once the server has recognized it.
     */
    fun signIn(accountNumber: String, onResult: (error: String?) -> Unit) {
        if (_signInBusy.value) return
        _signInBusy.value = true
        viewModelScope.launch {
            val error: String? = try {
                accountClient.fetchAccount(accountNumber) // 401 ⇒ unknown number
                accountStore.save(accountNumber)
                null
            } catch (e: AccountException) {
                e.message
            } catch (e: Exception) {
                e.message ?: "Sign-in failed. Please try again."
            }
            _signInBusy.value = false
            if (error == null) {
                _screen.value = Screen.HOME
                // Signed in — generate the device identity keys and
                // pre-provision in the background so the first connect is quick.
                viewModelScope.launch {
                    runCatching {
                        tm.ensureLocalKeypair()
                        tm.ensureLocalWgKeypair()
                        tm.warmUpPreferredRegion()
                    }
                }
            }
            onResult(error)
        }
    }

    /** Forget the account number, wipe the subscription's tunnel state, return to sign-in. */
    fun signOut() {
        tm.signOutCleanup()
        accountStore.clear()
        _accountState.value = AccountUiState.Loading
        _screen.value = Screen.SIGN_IN
    }

    private val _accountState = MutableStateFlow<AccountUiState>(AccountUiState.Loading)
    /** Subscription status for the Account screen. */
    val accountState: StateFlow<AccountUiState> = _accountState.asStateFlow()

    /** (Re)load the subscription status from the server. */
    fun refreshAccountStatus() {
        val number = accountStore.accountNumber() ?: return
        _accountState.value = AccountUiState.Loading
        viewModelScope.launch {
            _accountState.value = try {
                AccountUiState.Loaded(accountClient.fetchAccount(number))
            } catch (e: Exception) {
                AccountUiState.Failed(e.message ?: "Couldn't load your account.")
            }
        }
    }

    /**
     * Release a device slot, then refresh the status. [onResult] gets
     * null on success or a user-facing message on failure.
     */
    fun removeDevice(deviceId: Long, onResult: (error: String?) -> Unit) {
        val number = accountStore.accountNumber() ?: return
        viewModelScope.launch {
            val error: String? = try {
                accountClient.revokeDevice(number, deviceId)
                null
            } catch (e: Exception) {
                e.message ?: "Couldn't remove the device."
            }
            if (error == null) refreshAccountStatus()
            onResult(error)
        }
    }

    companion object {
        private const val PREFS = "lattice"
        private const val KEY_AUTO_CONNECT = "pref_auto_connect"

        /** Public-IP lookup: attempts and the wait between them, to ride
         *  out the few seconds a freshly-connected tunnel needs to settle. */
        private const val IP_LOOKUP_ATTEMPTS = 4
        private const val IP_LOOKUP_RETRY_MS = 2_500L
    }
}
