package ai.latticevpn.android.ui.screens

import ai.latticevpn.android.BuildConfig
import ai.latticevpn.android.data.LatticeRegion
import ai.latticevpn.android.ui.LatticeViewModel
import ai.latticevpn.android.ui.Screen
import ai.latticevpn.android.ui.components.InfoItem
import ai.latticevpn.android.ui.components.RowDivider
import ai.latticevpn.android.ui.components.SectionHeader
import ai.latticevpn.android.ui.components.SettingsCard
import ai.latticevpn.android.ui.components.SettingsItem
import ai.latticevpn.android.ui.components.SettingsToggle
import ai.latticevpn.android.vpn.RosenpassStatus
import android.content.Intent
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * Settings — Phase A6. Covers the three things a VPN client settings
 * screen needs at this stage: the system always-on / kill-switch
 * hand-off, a couple of app-local preferences, and a read-out of the
 * post-quantum security posture.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(vm: LatticeViewModel) {
    BackHandler { vm.navigateHome() }

    val context = LocalContext.current
    val autoConnect by vm.autoConnect.collectAsState()
    val rosenpass by vm.rosenpassStatus.collectAsState()
    val deviceKey by vm.localRosenpassPublicKeyB64.collectAsState()

    var showImport by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                ),
                navigationIcon = {
                    IconButton(onClick = { vm.navigateHome() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                title = { Text("Settings", fontWeight = FontWeight.SemiBold) },
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
            // ---- Account ----------------------------------------------------
            SectionHeader("Account")
            SettingsCard {
                SettingsItem(
                    title = "Account & subscription",
                    subtitle = "Your plan, devices, and account number.",
                    leadingIcon = Icons.Filled.AccountCircle,
                    onClick = { vm.navigateTo(Screen.ACCOUNT) },
                )
            }

            Spacer(Modifier.height(8.dp))

            // ---- Connection -------------------------------------------------
            SectionHeader("Connection")
            SettingsCard {
                SettingsItem(
                    title = "Always-on VPN & Kill Switch",
                    subtitle = "Open Android settings to keep Lattice always on and " +
                        "block traffic whenever the tunnel drops.",
                    leadingIcon = Icons.Filled.Lock,
                    onClick = {
                        runCatching {
                            context.startActivity(
                                Intent(Settings.ACTION_VPN_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                        }
                    },
                )
                RowDivider()
                SettingsToggle(
                    title = "Auto-connect on launch",
                    subtitle = "Connect automatically each time you open the app.",
                    checked = autoConnect,
                    onCheckedChange = vm::setAutoConnect,
                )
            }

            Spacer(Modifier.height(8.dp))

            // ---- Security ---------------------------------------------------
            SectionHeader("Security")
            SettingsCard {
                InfoItem(label = "Encryption", value = "Rosenpass (post-quantum)")
                RowDivider()
                InfoItem(label = "Key exchange status", value = rosenpassLabel(rosenpass))
                RowDivider()
                InfoItem(label = "Device PQ key", value = keyFingerprint(deviceKey))
            }

            Spacer(Modifier.height(8.dp))

            // ---- Advanced ---------------------------------------------------
            SectionHeader("Advanced")
            SettingsCard {
                SettingsItem(
                    title = "Import configuration manually",
                    subtitle = "Paste a WireGuard + Rosenpass config block.",
                    showChevron = true,
                    onClick = { showImport = true },
                )
            }

            Spacer(Modifier.height(8.dp))

            // ---- About ------------------------------------------------------
            SectionHeader("About")
            SettingsCard {
                InfoItem(label = "Version", value = BuildConfig.VERSION_NAME)
                RowDivider()
                InfoItem(
                    label = "Locations",
                    value = LatticeRegion.all.size.let { n -> if (n == 1) "1 region" else "$n regions" },
                )
            }

            Spacer(Modifier.height(24.dp))
        }
    }

    if (showImport) {
        ImportConfigDialog(vm = vm, onDismiss = { showImport = false })
    }
}

/** The manual paste-config dialog, preserved from the Phase 0 flow. */
@Composable
private fun ImportConfigDialog(vm: LatticeViewModel, onDismiss: () -> Unit) {
    var configText by remember { mutableStateOf("") }
    val importError by vm.importError.collectAsState()

    AlertDialog(
        onDismissRequest = {
            vm.clearImportError()
            onDismiss()
        },
        title = { Text("Import configuration") },
        text = {
            Column {
                OutlinedTextField(
                    value = configText,
                    onValueChange = { configText = it },
                    placeholder = { Text("Paste config block…") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(260.dp),
                    shape = RoundedCornerShape(8.dp),
                )
                if (importError != null) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = importError ?: "",
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = configText.isNotBlank(),
                onClick = {
                    vm.importConfig(configText) {
                        vm.navigateHome()
                        onDismiss()
                    }
                },
            ) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = {
                vm.clearImportError()
                onDismiss()
            }) { Text("Cancel") }
        },
    )
}

// ---- Copy helpers ---------------------------------------------------------

private fun rosenpassLabel(status: RosenpassStatus): String = when (status) {
    RosenpassStatus.Idle -> "Idle"
    RosenpassStatus.Connecting -> "Connecting"
    RosenpassStatus.Handshaking -> "Handshaking"
    is RosenpassStatus.Established -> "Active · ${status.rotations} rotations"
    is RosenpassStatus.Error -> "Error: ${status.message}"
}

private fun keyFingerprint(publicKeyB64: String?): String {
    if (publicKeyB64.isNullOrEmpty()) return "Generating…"
    return publicKeyB64.take(20) + "…"
}
