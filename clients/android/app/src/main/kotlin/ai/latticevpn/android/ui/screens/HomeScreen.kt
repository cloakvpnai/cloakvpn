package ai.latticevpn.android.ui.screens

import ai.latticevpn.android.data.LatticeRegion
import ai.latticevpn.android.ui.LatticeViewModel
import ai.latticevpn.android.ui.Screen
import ai.latticevpn.android.ui.components.ConnectControl
import ai.latticevpn.android.ui.components.LatticeMark
import ai.latticevpn.android.ui.theme.LatticeNavy
import ai.latticevpn.android.ui.theme.LatticeNavyElevated
import ai.latticevpn.android.vpn.RosenpassStatus
import ai.latticevpn.android.vpn.TunnelState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The connection home screen — Phase A6 redesign. A single circular
 * control drives connect / disconnect, with the selected location and
 * the live post-quantum status surfaced around it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    vm: LatticeViewModel,
    onConnect: () -> Unit,
) {
    val state by vm.tunnelState.collectAsState()
    val config by vm.tunnelConfig.collectAsState()
    val region by vm.selectedRegion.collectAsState()
    val rosenpass by vm.rosenpassStatus.collectAsState()

    val onControlTap: () -> Unit = {
        when (state) {
            TunnelState.CONNECTED, TunnelState.CONNECTING -> vm.disconnect()
            TunnelState.DISCONNECTING -> { /* already tearing down */ }
            TunnelState.DISCONNECTED, TunnelState.ERROR ->
                if (config == null) vm.navigateTo(Screen.REGIONS) else onConnect()
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        LatticeMark(Modifier.size(24.dp))
                        Spacer(Modifier.width(10.dp))
                        Text("Lattice VPN", fontWeight = FontWeight.SemiBold)
                    }
                },
                actions = {
                    IconButton(onClick = { vm.navigateTo(Screen.SETTINGS) }) {
                        Icon(Icons.Filled.Settings, contentDescription = "Settings")
                    }
                },
            )
        },
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .background(Brush.verticalGradient(listOf(LatticeNavyElevated, LatticeNavy)))
                .padding(padding),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.weight(0.55f))

                ConnectControl(state = state, onClick = onControlTap)

                Spacer(Modifier.height(28.dp))

                Text(
                    text = statusHeadline(state),
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 26.sp,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = statusSubtitle(state, config != null, region),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                )

                Spacer(Modifier.height(16.dp))

                PqcChip(state = state, rosenpass = rosenpass)

                Spacer(Modifier.weight(1f))

                LocationCard(
                    region = region,
                    customEndpoint = if (region == null) config?.endpoint else null,
                    onClick = { vm.navigateTo(Screen.REGIONS) },
                )

                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

/** The post-quantum status pill shown beneath the connect control. */
@Composable
private fun PqcChip(state: TunnelState, rosenpass: RosenpassStatus) {
    val active = state == TunnelState.CONNECTED &&
        (rosenpass is RosenpassStatus.Established)
    val dotColor =
        if (active) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.onSurfaceVariant

    Surface(
        shape = RoundedCornerShape(999.dp),
        color = MaterialTheme.colorScheme.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(8.dp)
                    .background(dotColor, CircleShape),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = pqcLine(state, rosenpass),
                color = MaterialTheme.colorScheme.onSurface,
                fontSize = 13.sp,
            )
        }
    }
}

/** The bottom card showing — and letting the user change — the location. */
@Composable
private fun LocationCard(
    region: LatticeRegion?,
    customEndpoint: String?,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = region?.countryFlag ?: "🌐", // globe fallback
                fontSize = 28.sp,
            )
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = "Location",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 12.sp,
                )
                Text(
                    text = region?.displayName
                        ?: customEndpoint?.let { "Custom server" }
                        ?: "Choose a location",
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                val detail = region?.endpointIP ?: customEndpoint
                if (detail != null) {
                    Text(
                        text = detail,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 12.sp,
                    )
                }
            }
            Spacer(Modifier.width(8.dp))
            Text(
                text = "Change",
                color = MaterialTheme.colorScheme.primary,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
            )
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
            )
        }
    }
}

// ---- Copy helpers ---------------------------------------------------------

private fun statusHeadline(state: TunnelState): String = when (state) {
    TunnelState.CONNECTED -> "Protected"
    TunnelState.CONNECTING -> "Connecting…"
    TunnelState.DISCONNECTING -> "Disconnecting…"
    TunnelState.ERROR -> "Connection failed"
    TunnelState.DISCONNECTED -> "Not connected"
}

private fun statusSubtitle(
    state: TunnelState,
    hasConfig: Boolean,
    region: LatticeRegion?,
): String = when (state) {
    TunnelState.CONNECTED -> region?.let { "Tunnel active · ${it.displayName}" }
        ?: "Secure tunnel active"
    TunnelState.CONNECTING -> "Establishing a secure tunnel"
    TunnelState.DISCONNECTING -> "Closing the tunnel"
    TunnelState.ERROR -> "Tap the shield to try again"
    TunnelState.DISCONNECTED ->
        if (!hasConfig) "Choose a location to get started" else "Tap the shield to connect"
}

private fun pqcLine(state: TunnelState, rosenpass: RosenpassStatus): String = when {
    state != TunnelState.CONNECTED -> "Post-quantum encryption ready"
    rosenpass is RosenpassStatus.Established ->
        "Post-quantum active · ${rosenpass.rotations} key rotations"
    rosenpass is RosenpassStatus.Handshaking -> "Post-quantum handshake…"
    rosenpass is RosenpassStatus.Connecting -> "Starting post-quantum channel…"
    rosenpass is RosenpassStatus.Error -> "Post-quantum: ${rosenpass.message}"
    else -> "Post-quantum encryption ready"
}
