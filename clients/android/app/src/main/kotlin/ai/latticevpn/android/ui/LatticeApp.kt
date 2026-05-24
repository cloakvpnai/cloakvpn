package ai.latticevpn.android.ui

import ai.latticevpn.android.ui.screens.AccountScreen
import ai.latticevpn.android.ui.screens.HomeScreen
import ai.latticevpn.android.ui.screens.RegionPickerScreen
import ai.latticevpn.android.ui.screens.SettingsScreen
import ai.latticevpn.android.ui.screens.SignInScreen
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue

/**
 * Phase A6 app root. Hosts the three top-level destinations and
 * cross-fades between them. All real navigation state lives in
 * [LatticeViewModel.screen]; each sub-screen installs its own
 * `BackHandler` to return Home.
 *
 * @param onConnect raised when the user asks to bring the tunnel up.
 *   Handled by the activity because `VpnService.prepare` may need to
 *   show the system VPN-consent dialog.
 */
@Composable
fun LatticeApp(
    vm: LatticeViewModel,
    onConnect: () -> Unit,
) {
    val screen by vm.screen.collectAsState()

    Crossfade(targetState = screen, animationSpec = tween(220), label = "screen") { target ->
        when (target) {
            Screen.SIGN_IN -> SignInScreen(vm = vm)
            Screen.HOME -> HomeScreen(vm = vm, onConnect = onConnect)
            Screen.REGIONS -> RegionPickerScreen(vm = vm)
            Screen.SETTINGS -> SettingsScreen(vm = vm)
            Screen.ACCOUNT -> AccountScreen(vm = vm)
        }
    }
}
