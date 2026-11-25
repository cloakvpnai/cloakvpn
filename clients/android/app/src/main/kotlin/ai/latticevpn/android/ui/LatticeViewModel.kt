package ai.latticevpn.android.ui

import ai.latticevpn.android.billing.BillingManager
import ai.latticevpn.android.data.AccountClient
import ai.latticevpn.android.data.AccountException
import ai.latticevpn.android.data.AccountStatus
import ai.latticevpn.android.data.AccountStore
import ai.latticevpn.android.data.GooglePlayIapClient
import ai.latticevpn.android.data.IpAddressClient
import ai.latticevpn.android.data.LatticeRegion
import ai.latticevpn.android.data.RegionStore
import ai.latticevpn.android.vpn.TunnelState
import android.app.Activity
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
import ai.latticevpn.android.vpn.cnsa2.Cnsa2Backend
import ai.latticevpn.android.vpn.cnsa2.Cnsa2Config
import ai.latticevpn.android.vpn.cnsa2.Cnsa2Enroller
import ai.latticevpn.android.vpn.cnsa2.Cnsa2RenewalWorker
import ai.latticevpn.android.vpn.cnsa2.Cnsa2Provider
import ai.latticevpn.android.vpn.cnsa2.Cnsa2State
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

/** The top-level destinations in the UI. */
enum class Screen { SIGN_IN, PAYWALL, HOME, REGIONS, SETTINGS, ACCOUNT, LICENSES }

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
 * UI-facing state holder: the tunnel (always the CNSA 2.0 suite), the selected
 * region, the account, in-app navigation and app preferences.
 */
class LatticeViewModel(app: Application) : AndroidViewModel(app) {

    private val regions = RegionStore.get(app)
    private val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val ipClient = IpAddressClient()
    private val accountStore = AccountStore(app)
    private val accountClient = AccountClient(app)
    private val iapClient = GooglePlayIapClient()

    /** Play Billing client. Purchases are delivered to [onPlayPurchase]. */
    private val billing = BillingManager(app) { token, productId ->
        onPlayPurchase(token, productId)
    }

    // ---- The tunnel: TLS 1.3 with the CNSA 2.0 suite ------------------------

    private val cnsa2: Cnsa2Backend? = Cnsa2Provider.backend()
    private val cnsa2Enroller = Cnsa2Enroller(app, accountClient)
    private var cnsa2Config: Cnsa2Config? = if (cnsa2 != null) Cnsa2Config.load(app) else null

    /** True when this build has the engine. The device enrolls itself the first time it connects. */
    val cnsa2Available: Boolean = cnsa2 != null

    val cnsa2Detail: StateFlow<String?> = cnsa2?.detail ?: MutableStateFlow(null)

    /** Session time, data, latency and key changes for the globe panel. */
    val sessionStats: StateFlow<ai.latticevpn.android.vpn.cnsa2.Cnsa2Stats> = ai.latticevpn.android.cnsa2.LatticeTlsVpnService.stats

    init {
        // Keeps the daily renewal scheduled for a device that is already enrolled.
        if (cnsa2Available && Cnsa2Config.load(app) != null) Cnsa2RenewalWorker.schedule(app)
        // Keys and configurations left on the device by a WireGuard-based version are erased.
        regions.eraseLegacyTunnelData()
    }

    private val _cnsa2Enrolling = MutableStateFlow(false)
    val cnsa2Enrolling: StateFlow<Boolean> = _cnsa2Enrolling.asStateFlow()
    private val _cnsa2Error = MutableStateFlow<String?>(null)
    /** Why enrollment failed, if it did. Cleared on the next success. */
    val cnsa2Error: StateFlow<String?> = _cnsa2Error.asStateFlow()

    /** Returns the gateway settings, enrolling the device first if it has no usable certificate. */
    private suspend fun ensureCnsa2Enrolled(): Cnsa2Config? {
        cnsa2Config?.takeIf { !cnsa2Enroller.needsEnrollment() }?.let { return it }
        val number = accountStore.accountNumber()
        if (number == null) {
            _cnsa2Error.value = "Sign in with your account number to connect."
            return null
        }
        if (_cnsa2Enrolling.value) return null
        _cnsa2Enrolling.value = true
        return try {
            cnsa2Enroller.enroll(number).also {
                cnsa2Config = it
                _cnsa2Error.value = null
                Cnsa2RenewalWorker.schedule(getApplication())
            }
        } catch (e: Exception) {
            _cnsa2Error.value = e.message ?: "Could not enroll this device."
            null
        } finally {
            _cnsa2Enrolling.value = false
        }
    }

    val tunnelState: StateFlow<TunnelState> =
        if (cnsa2 == null) MutableStateFlow(TunnelState.DISCONNECTED)
        else cnsa2.state.map { suite ->
            when (suite) {
                Cnsa2State.OFF -> TunnelState.DISCONNECTED
                Cnsa2State.CONNECTING, Cnsa2State.RECONNECTING -> TunnelState.CONNECTING
                Cnsa2State.CONNECTED -> TunnelState.CONNECTED
                Cnsa2State.FAILED -> TunnelState.ERROR
            }
        }.stateIn(viewModelScope, SharingStarted.Eagerly, TunnelState.DISCONNECTED)
    val selectedRegion: StateFlow<LatticeRegion?> get() = regions.selectedRegion
    /** Picking a region is immediate now; kept so the region list has one shape of state. */
    val regionSelectionInProgress: StateFlow<Boolean> = MutableStateFlow(false)
    val lastRegionError: StateFlow<String?> = MutableStateFlow(null)

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

    // ---- Lifecycle -------------------------------------------------------

    init {
        // Refresh the displayed public IP whenever the tunnel settles.
        // collect() replays the current value, so this also performs the
        // initial lookup on launch.
        viewModelScope.launch {
            tunnelState.collect { state ->
                when (state) {
                    TunnelState.CONNECTED -> scheduleIpRefresh(1500L)
                    TunnelState.DISCONNECTED, TunnelState.ERROR -> scheduleIpRefresh(0L)
                    TunnelState.CONNECTING, TunnelState.DISCONNECTING -> { /* transient */ }
                }
            }
        }
    }

    // ---- Actions ---------------------------------------------------------

    /** Pick [region]. A live tunnel moves to that region's gateway. */
    fun selectRegion(region: LatticeRegion, onComplete: (error: String?) -> Unit) {
        viewModelScope.launch {
            val wasUp = cnsa2 != null && cnsa2.state.value != Cnsa2State.OFF
            regions.select(region)
            onComplete(null)
            // A live tunnel moves to the new region's gateway.
            // The tunnel service changes gateway in place, so traffic stays held.
            if (wasUp) connect()
        }
    }

    fun connect() {
        val engine = cnsa2
        if (engine == null) {
            // The engine did not load on this device. Refuse; there is no other way to connect.
            _cnsa2Error.value = "This device cannot run the CNSA 2.0 tunnel."
            return
        }
        run {
            viewModelScope.launch {
                ensureCnsa2Enrolled() ?: return@launch
                // The gateway follows the selected region. Refreshing the list is best effort.
                accountStore.accountNumber()?.let { number -> runCatching { cnsa2Enroller.refreshGateways(number) } }
                val config = cnsa2Enroller.configFor(regions.selectedRegion.value?.id)
                if (config == null) {
                    _cnsa2Error.value = "That region has no CNSA 2.0 gateway yet. Pick another region."
                    return@launch
                }
                _cnsa2Error.value = null
                cnsa2Config = config
                // No region picked yet: show the one this connection goes through.
                if (regions.selectedRegion.value == null) {
                    cnsa2Enroller.regionIdOf(config)?.let { LatticeRegion.byId(it) }?.let { regions.select(it) }
                }
                engine.connect(getApplication(), config)
                // Renew ahead of expiry with the same key. The live tunnel keeps its current certificate.
                // The daily background job does the same when the app is not open.
                accountStore.accountNumber()?.let { number ->
                    runCatching { cnsa2Enroller.renewIfDue(number) }
                }
            }
        }
    }

    fun disconnect() {
        if (cnsa2 != null && cnsa2.state.value != Cnsa2State.OFF) cnsa2.disconnect(getApplication())
    }

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
                    if (tunnelState.value == TunnelState.DISCONNECTED) {
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
            if (error == null) _screen.value = Screen.HOME
            onResult(error)
        }
    }

    /** Forget the account number, wipe the subscription's tunnel state, return to sign-in. */
    fun signOut() {
        // Give up this device's CNSA 2.0 identity, so a signed-out phone cannot keep using the service.
        if (cnsa2 != null) {
            disconnect()
            _cnsa2Error.value = null
            cnsa2Config = null
            androidx.work.WorkManager.getInstance(getApplication()).cancelUniqueWork(Cnsa2RenewalWorker.WORK_NAME)
            accountStore.accountNumber()?.let { number -> viewModelScope.launch { cnsa2Enroller.forget(number) } }
        }
        regions.clear()
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

    // ---- In-app purchase (Google Play Billing) ---------------------------

    /** Subscription plans loaded from Play; empty until billing connects. */
    val plans: StateFlow<List<BillingManager.SubPlan>> get() = billing.plans

    /** True once the billing client is connected and plans are loaded. */
    val billingReady: StateFlow<Boolean> get() = billing.ready

    /** A Play-side billing error (connection / purchase-flow), or null. */
    val billingError: StateFlow<String?> get() = billing.error
    fun clearBillingError() = billing.clearError()

    private val _purchaseBusy = MutableStateFlow(false)
    /** True while a purchase is being verified server-side. */
    val purchaseBusy: StateFlow<Boolean> = _purchaseBusy.asStateFlow()

    private val _purchaseError = MutableStateFlow<String?>(null)
    /** A server-side verification error after a purchase, or null. */
    val purchaseError: StateFlow<String?> = _purchaseError.asStateFlow()
    fun clearPurchaseError() { _purchaseError.value = null }

    /** Connect to Play and load plans — call when the paywall appears. */
    fun startBilling() = billing.start()

    /** Open the Play purchase sheet for [plan]. */
    fun launchPurchase(activity: Activity, plan: BillingManager.SubPlan) {
        _purchaseError.value = null
        billing.launchPurchase(activity, plan)
    }

    /**
     * "Restore purchases": re-deliver a subscription this Google account
     * already owns. Found purchases flow through [onPlayPurchase] just like a
     * fresh one; if none are owned, surface a gentle message.
     */
    fun restorePurchases() {
        _purchaseError.value = null
        _purchaseBusy.value = true
        billing.restorePurchases { found ->
            if (!found) {
                _purchaseBusy.value = false
                _purchaseError.value =
                    "No Google Play subscription was found for this account."
            }
            // When found, onPlayPurchase drives the rest (and clears busy).
        }
    }

    /**
     * Play confirmed a purchase. Verify the token server-side, which mints or
     * re-issues the account number, then store it and move to Home — signing
     * the customer in without them typing anything.
     */
    private fun onPlayPurchase(purchaseToken: String, productId: String) {
        _purchaseBusy.value = true
        viewModelScope.launch {
            try {
                // Restore=true whenever we don't already hold a number, so the
                // server re-issues one for a reinstall / new device.
                val restore = !accountStore.isSignedIn()
                val result = iapClient.verify(purchaseToken, restore = restore)
                val number = result.accountNumber ?: accountStore.accountNumber()
                if (number.isNullOrEmpty()) {
                    _purchaseError.value =
                        "Your purchase was confirmed but we couldn't issue an account number. " +
                            "Try Restore purchases, or contact support."
                } else {
                    accountStore.save(number)
                    _screen.value = Screen.HOME
                }
            } catch (e: AccountException) {
                _purchaseError.value = e.message
            } catch (e: Exception) {
                _purchaseError.value = e.message ?: "Couldn't confirm your purchase."
            } finally {
                _purchaseBusy.value = false
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        billing.dispose()
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
