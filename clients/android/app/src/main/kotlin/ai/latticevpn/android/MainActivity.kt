package ai.latticevpn.android

import ai.latticevpn.android.ui.LatticeApp
import ai.latticevpn.android.ui.LatticeViewModel
import ai.latticevpn.android.ui.theme.LatticeTheme
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen

/**
 * Single-activity host for the Phase A6 Compose UI.
 *
 * The activity owns everything that needs an `Activity` rather than a
 * `ViewModel`: the `VpnService.prepare` consent flow, the runtime
 * notification permission, and the launch-time auto-connect decision.
 * All other state lives in [LatticeViewModel] / `TunnelManager`.
 */
class MainActivity : ComponentActivity() {

    private val viewModel: LatticeViewModel by viewModels()

    /** Result of the system VPN-consent dialog; on approval, connect. */
    private val vpnConsent = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == RESULT_OK) viewModel.connect()
    }

    /** Foreground-service notification permission (Android 13+). */
    private val notificationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* best-effort — the tunnel still runs if the user declines */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Show the branded splash until the first frame is ready, then
        // hand off to Theme.Lattice (see Theme.Lattice.Starting).
        installSplashScreen()
        super.onCreate(savedInstanceState)

        requestNotificationPermissionIfNeeded()

        setContent {
            LatticeTheme {
                LatticeApp(vm = viewModel, onConnect = ::startTunnel)
            }
        }

        // Honor the auto-connect preference on a fresh launch — but only
        // once the customer is signed in and a config has been provisioned.
        if (savedInstanceState == null &&
            viewModel.isSignedIn() &&
            viewModel.autoConnectEnabled() &&
            viewModel.hasConfig()
        ) {
            startTunnel()
        }
    }

    /**
     * Bring the tunnel up. If Android has not yet granted this app the
     * VPN permission, [VpnService.prepare] returns a consent intent —
     * launch it and connect once the user approves; otherwise connect
     * straight away.
     */
    private fun startTunnel() {
        val consent = VpnService.prepare(this)
        if (consent != null) vpnConsent.launch(consent) else viewModel.connect()
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}
