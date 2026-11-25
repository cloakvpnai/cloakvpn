package ai.latticevpn.android.ui.screens

import ai.latticevpn.android.data.LatticeRegion
import ai.latticevpn.android.ui.IpState
import ai.latticevpn.android.ui.LatticeViewModel
import ai.latticevpn.android.ui.Screen
import ai.latticevpn.android.ui.components.ConnectControl
import ai.latticevpn.android.ui.components.LatticeLogo
import ai.latticevpn.android.ui.theme.LatticeAmber
import ai.latticevpn.android.ui.theme.LatticeNavy
import ai.latticevpn.android.ui.theme.LatticeNavyElevated
import ai.latticevpn.android.vpn.TunnelState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The connection home screen — Phase A6, with the Lattice logo and a
 * live "Your IP address" panel that shows the user's real address
 * before connecting and the before → after change once the tunnel is up.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    vm: LatticeViewModel,
    onConnect: () -> Unit,
) {
    val state by vm.tunnelState.collectAsState()
    val region by vm.selectedRegion.collectAsState()
    val ipState by vm.publicIp.collectAsState()
    val realIp by vm.realIp.collectAsState()
    val cnsa2Detail by vm.cnsa2Detail.collectAsState()
    val cnsa2Error by vm.cnsa2Error.collectAsState()

    val onControlTap: () -> Unit = {
        when (state) {
            TunnelState.CONNECTED, TunnelState.CONNECTING -> vm.disconnect()
            TunnelState.DISCONNECTING -> { /* already tearing down */ }
            TunnelState.DISCONNECTED, TunnelState.ERROR -> onConnect()
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        LatticeLogo(Modifier.size(26.dp))
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
            // Centered when it fits; scrolls on very short screens.
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp, vertical = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                LatticeLogo(Modifier.size(54.dp))
                Spacer(Modifier.height(16.dp))

                ConnectControl(state = state, onClick = onControlTap)

                Spacer(Modifier.height(20.dp))

                Text(
                    text = statusHeadline(state),
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 25.sp,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = cnsa2Error?.takeIf { state == TunnelState.DISCONNECTED } ?: cnsa2Subtitle(state, cnsa2Detail),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                )

                Spacer(Modifier.height(14.dp))
                SuiteChip(state = state)

                Spacer(Modifier.height(22.dp))

                IpCard(
                    publicIp = ipState,
                    realIp = realIp,
                    connected = state == TunnelState.CONNECTED,
                    regionName = region?.displayName,
                    onRetry = { vm.refreshPublicIp() },
                )
                Spacer(Modifier.height(10.dp))
                LocationCard(
                    region = region,
                    hasConfig = false,
                    onClick = { vm.navigateTo(Screen.REGIONS) },
                )
            }
        }
    }
}

/** The pill beneath the connect control that names the suite protecting the tunnel. */
@Composable
private fun SuiteChip(state: TunnelState) {
    val active = state == TunnelState.CONNECTED
    val dotColor =
        if (active) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.onSurfaceVariant

    Surface(
        shape = RoundedCornerShape(999.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(8.dp).background(dotColor, CircleShape))
            Spacer(Modifier.width(8.dp))
            Text(
                text = cnsa2Line(state),
                color = MaterialTheme.colorScheme.onSurface,
                fontSize = 12.sp,
                maxLines = 1,
                softWrap = false,
            )
        }
    }
}

/**
 * The "IP address" panel. Disconnected, it shows the user's real IP.
 * Connected, it shows both — the real IP and the server's exit IP — each
 * on its own labelled row, so the change is plain to see. Tap re-checks.
 */
@Composable
private fun IpCard(
    publicIp: IpState,
    realIp: String?,
    connected: Boolean,
    regionName: String?,
    onRetry: () -> Unit,
) {
    val statusColor = if (connected) MaterialTheme.colorScheme.primary else LatticeAmber
    val statusLabel = if (connected) "Protected" else "Unprotected"

    // The real IP: explicitly remembered, or — when the tunnel is down —
    // the current reading, which is itself the real IP.
    val realIpText: String? = realIp
        ?: (publicIp as? IpState.Known)?.ip?.takeIf { !connected }

    Surface(
        onClick = onRetry,
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "IP ADDRESS",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.sp,
                )
                Surface(
                    shape = RoundedCornerShape(999.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant,
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.size(8.dp).background(statusColor, CircleShape))
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = statusLabel,
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
            }

            Spacer(Modifier.height(12.dp))

            // Always shown: the user's real IP.
            IpRow(
                label = "Your real IP",
                value = realIpText ?: "Checking…",
                valueColor = MaterialTheme.colorScheme.onSurface,
            )

            // Shown once connected: the server's exit IP.
            if (connected) {
                Spacer(Modifier.height(10.dp))
                val serverValue = when (publicIp) {
                    is IpState.Known -> publicIp.ip
                    is IpState.Loading -> "Securing…"
                    is IpState.Unavailable -> "Unavailable. Tap to retry."
                }
                IpRow(
                    label = "Server IP" + (regionName?.let { " · $it" } ?: ""),
                    value = serverValue,
                    valueColor = MaterialTheme.colorScheme.primary,
                    valueBold = true,
                )
            }

            Spacer(Modifier.height(10.dp))
            Text(
                text = if (connected) {
                    "Sites you visit now see the server IP. Your real IP is hidden."
                } else {
                    "Every site you visit currently sees this address."
                },
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 12.sp,
            )
        }
    }
}

/** A label-left / value-right line used inside [IpCard]. */
@Composable
private fun IpRow(
    label: String,
    value: String,
    valueColor: Color,
    valueBold: Boolean = false,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Both sides are weighted so a long label ("Server IP · <region>")
        // and a long value ("Unavailable. Tap to retry.") each stay
        // inside their own half and wrap downward instead of overrunning
        // the row and bleeding into the line below.
        Text(
            text = label,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 13.sp,
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = value,
            color = valueColor,
            fontSize = 16.sp,
            fontWeight = if (valueBold) FontWeight.Bold else FontWeight.SemiBold,
            textAlign = TextAlign.End,
            modifier = Modifier.weight(1f),
        )
    }
}

/** The bottom card showing — and letting the user change — the location. */
@Composable
private fun LocationCard(
    region: LatticeRegion?,
    hasConfig: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text = region?.countryFlag ?: "🌐", fontSize = 28.sp)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = "Location",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 12.sp,
                )
                Text(
                    text = region?.displayName
                        ?: if (hasConfig) "Custom server" else "Choose a location",
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                )
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

/** The app offers one suite only, so connected means that suite is in use. */
private fun cnsa2Line(state: TunnelState): String =
    if (state == TunnelState.CONNECTED) "CNSA 2.0 · active · ML-KEM-1024 · ML-DSA-87"
    else "CNSA 2.0 · ML-KEM-1024 · ML-DSA-87"

private fun cnsa2Subtitle(state: TunnelState, detail: String?): String = when (state) {
    TunnelState.CONNECTED -> "Connected to the CNSA 2.0 gateway"
    TunnelState.CONNECTING -> "Connecting. Traffic waits for the tunnel."
    TunnelState.DISCONNECTING -> "Disconnecting"
    TunnelState.ERROR -> detail ?: "Could not connect"
    TunnelState.DISCONNECTED -> "Tap the shield to connect with CNSA 2.0"
}

