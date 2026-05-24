package ai.latticevpn.android.ui.screens

import ai.latticevpn.android.data.AccountDevice
import ai.latticevpn.android.ui.AccountUiState
import ai.latticevpn.android.ui.LatticeViewModel
import ai.latticevpn.android.ui.Screen
import ai.latticevpn.android.ui.components.InfoItem
import ai.latticevpn.android.ui.components.RowDivider
import ai.latticevpn.android.ui.components.SectionHeader
import ai.latticevpn.android.ui.components.SettingsCard
import ai.latticevpn.android.ui.components.SettingsItem
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/**
 * Account / subscription screen. Shows the customer's account number,
 * their current plan, renewal date and device usage, lets them free a
 * device slot, and signs out. Reached from Settings → Account.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountScreen(vm: LatticeViewModel) {
    BackHandler { vm.navigateTo(Screen.SETTINGS) }

    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    val accountNumber = remember { vm.accountNumber().orEmpty() }
    val state by vm.accountState.collectAsState()
    val tunnelConfig by vm.tunnelConfig.collectAsState()
    val thisDeviceIp = tunnelConfig?.addressV4?.substringBefore("/")

    var pendingRemoval by remember { mutableStateOf<AccountDevice?>(null) }
    var signOutAsk by remember { mutableStateOf(false) }

    // Pull a fresh subscription status each time the screen opens.
    LaunchedEffect(Unit) { vm.refreshAccountStatus() }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                ),
                navigationIcon = {
                    IconButton(onClick = { vm.navigateTo(Screen.SETTINGS) }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                title = { Text("Account", fontWeight = FontWeight.SemiBold) },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            // ---- Account number --------------------------------------------
            SectionHeader("Account number")
            SettingsCard {
                Column(Modifier.padding(16.dp)) {
                    Text(
                        text = accountNumber.ifEmpty { "—" },
                        color = MaterialTheme.colorScheme.onSurface,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.SemiBold,
                        fontFamily = FontFamily.Monospace,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = "This is your only credential — keep it somewhere " +
                            "safe. Anyone who has it can use your subscription.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 12.sp,
                    )
                    Spacer(Modifier.height(12.dp))
                    OutlinedButton(
                        onClick = {
                            clipboard.setText(AnnotatedString(accountNumber))
                            scope.launch { snackbar.showSnackbar("Account number copied") }
                        },
                    ) { Text("Copy") }
                }
            }

            Spacer(Modifier.height(8.dp))

            // ---- Subscription ----------------------------------------------
            SectionHeader("Subscription")
            SettingsCard {
                when (val s = state) {
                    is AccountUiState.Loading ->
                        StatusLine("Loading your subscription…")

                    is AccountUiState.Failed -> {
                        StatusLine(s.message)
                        RowDivider()
                        TextButton(
                            onClick = { vm.refreshAccountStatus() },
                            modifier = Modifier.padding(horizontal = 8.dp),
                        ) { Text("Retry") }
                    }

                    is AccountUiState.Loaded -> {
                        val st = s.status
                        InfoItem(label = "Plan", value = tierLabel(st.tier))
                        RowDivider()
                        InfoItem(
                            label = "Status",
                            value = if (st.isActive) "Active" else "Inactive",
                        )
                        RowDivider()
                        InfoItem(
                            label = if (st.isActive) "Renews" else "Ended",
                            value = formatDate(st.activeUntil),
                        )
                        RowDivider()
                        InfoItem(
                            label = "Devices",
                            value = "${st.deviceCount} of ${st.deviceLimit}",
                        )
                    }
                }
            }

            // ---- Devices ---------------------------------------------------
            (state as? AccountUiState.Loaded)?.status?.devices
                ?.takeIf { it.isNotEmpty() }
                ?.let { devices ->
                    Spacer(Modifier.height(8.dp))
                    SectionHeader("Devices")
                    SettingsCard {
                        devices.forEachIndexed { index, device ->
                            if (index > 0) RowDivider()
                            DeviceRow(
                                device = device,
                                isThisDevice = device.ip == thisDeviceIp,
                                onRemove = { pendingRemoval = device },
                            )
                        }
                    }
                }

            Spacer(Modifier.height(8.dp))

            // ---- Manage ----------------------------------------------------
            SectionHeader("Manage")
            SettingsCard {
                SettingsItem(
                    title = "Manage or cancel subscription",
                    subtitle = "Opens latticevpn.ai in your browser.",
                    onClick = { openUrl(context, "https://latticevpn.ai") },
                )
            }

            Spacer(Modifier.height(16.dp))
            OutlinedButton(
                onClick = { signOutAsk = true },
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = MaterialTheme.colorScheme.error,
                ),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.error),
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Sign out") }

            Spacer(Modifier.height(24.dp))
        }
    }

    // ---- Confirm: remove a device ------------------------------------------
    pendingRemoval?.let { device ->
        AlertDialog(
            onDismissRequest = { pendingRemoval = null },
            title = { Text("Remove device?") },
            text = {
                Text(
                    "This frees up a device slot. The device at ${device.ip} " +
                        "will lose access until it is set up again.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    val id = device.id
                    pendingRemoval = null
                    vm.removeDevice(id) { error ->
                        if (error != null) scope.launch { snackbar.showSnackbar(error) }
                    }
                }) { Text("Remove") }
            },
            dismissButton = {
                TextButton(onClick = { pendingRemoval = null }) { Text("Cancel") }
            },
        )
    }

    // ---- Confirm: sign out -------------------------------------------------
    if (signOutAsk) {
        AlertDialog(
            onDismissRequest = { signOutAsk = false },
            title = { Text("Sign out?") },
            text = {
                Text(
                    "Lattice will disconnect and forget your account number on " +
                        "this device. You'll need the number again to sign back in.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    signOutAsk = false
                    vm.signOut()
                }) { Text("Sign out") }
            },
            dismissButton = {
                TextButton(onClick = { signOutAsk = false }) { Text("Cancel") }
            },
        )
    }
}

/** A single full-width line of muted text inside a [SettingsCard]. */
@Composable
private fun StatusLine(text: String) {
    Text(
        text = text,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontSize = 14.sp,
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
    )
}

/** One provisioned device: address, when it was added, and a remove button. */
@Composable
private fun DeviceRow(
    device: AccountDevice,
    isThisDevice: Boolean,
    onRemove: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 4.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = device.ip.ifEmpty { "Device ${device.id}" },
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Medium,
                )
                if (isThisDevice) {
                    Spacer(Modifier.width(8.dp))
                    ThisDeviceChip()
                }
            }
            Text(
                text = "Added ${formatDate(device.createdAt)}",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        IconButton(onClick = onRemove) {
            Icon(
                imageVector = Icons.Filled.Delete,
                contentDescription = "Remove device",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** Small accent chip marking the device the app is currently running on. */
@Composable
private fun ThisDeviceChip() {
    Surface(
        shape = RoundedCornerShape(6.dp),
        color = MaterialTheme.colorScheme.primaryContainer,
    ) {
        Text(
            text = "This device",
            color = MaterialTheme.colorScheme.primary,
            fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
        )
    }
}

// ---- Helpers --------------------------------------------------------------

private fun tierLabel(tier: String): String = when (tier.lowercase()) {
    "basic" -> "Basic"
    "pro" -> "Pro"
    "" -> "No active plan"
    else -> tier.replaceFirstChar { it.uppercase() }
}

/**
 * Render an RFC3339 instant as a localized medium date. Returns "—" for
 * a blank value, an unparseable string, or the server's epoch-zero
 * "no expiry" sentinel.
 */
private fun formatDate(rfc3339: String): String {
    if (rfc3339.isBlank()) return "—"
    return try {
        val instant = Instant.parse(rfc3339)
        if (instant.epochSecond <= 0L) return "—"
        DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
            .withLocale(Locale.getDefault())
            .withZone(ZoneId.systemDefault())
            .format(instant)
    } catch (e: Exception) {
        "—"
    }
}

/** Open [url] in the device browser; silently no-ops if nothing handles it. */
private fun openUrl(context: Context, url: String) {
    runCatching {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
