package com.cloakvpn.app.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.cloakvpn.app.vpn.TunnelRepository
import com.cloakvpn.app.vpn.TunnelState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloakApp(
    onConnect: () -> Unit,
    onDisconnect: () -> Unit
) {
    val ctx = LocalContext.current
    val repo = remember { TunnelRepository.get(ctx) }
    val state by repo.state.collectAsState()
    val config by repo.config.collectAsState()
    var configText by remember { mutableStateOf("") }
    var showImport by remember { mutableStateOf(false) }
    var err by remember { mutableStateOf<String?>(null) }

    MaterialTheme {
        Scaffold(topBar = { TopAppBar(title = { Text("Cloak VPN") }) }) { pad ->
            Column(
                modifier = Modifier.padding(pad).padding(16.dp).fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                StatusBadge(state)

                Button(
                    onClick = { if (state == TunnelState.CONNECTED) onDisconnect() else onConnect() },
                    enabled = config != null,
                    modifier = Modifier.fillMaxWidth().height(60.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (state == TunnelState.CONNECTED) Color.Red else MaterialTheme.colorScheme.primary
                    )
                ) {
                    Text(
                        if (state == TunnelState.CONNECTED) "Disconnect" else "Connect",
                        fontSize = 18.sp, fontWeight = FontWeight.SemiBold
                    )
                }

                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp)) {
                        val cfg = config
                        if (cfg == null) {
                            Text("No config imported.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        } else {
                            Text("Endpoint: ${cfg.endpoint}", fontSize = 13.sp)
                            Text(
                                "PQC: Rosenpass ${if (cfg.pqEnabled) "ENABLED" else "disabled"}",
                                fontSize = 13.sp
                            )
                        }
                    }
                }

                Spacer(Modifier.weight(1f))

                OutlinedButton(onClick = { showImport = true }) {
                    Text("Import config")
                }
            }

            if (showImport) {
                AlertDialog(
                    onDismissRequest = { showImport = false },
                    title = { Text("Paste config") },
                    text = {
                        OutlinedTextField(
                            value = configText,
                            onValueChange = { configText = it },
                            modifier = Modifier.fillMaxWidth().height(280.dp),
                            shape = RoundedCornerShape(8.dp)
                        )
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            try {
                                repo.importConfig(configText)
                                showImport = false
                            } catch (e: Exception) {
                                err = e.message
                            }
                        }) { Text("Save") }
                    },
                    dismissButton = {
                        TextButton(onClick = { showImport = false }) { Text("Cancel") }
                    }
                )
            }

            err?.let {
                AlertDialog(
                    onDismissRequest = { err = null },
                    title = { Text("Error") },
                    text = { Text(it) },
                    confirmButton = { TextButton(onClick = { err = null }) { Text("OK") } }
                )
            }
        }
    }
}

@Composable
private fun StatusBadge(state: TunnelState) {
    val (color, label) = when (state) {
        TunnelState.CONNECTED -> Color(0xFF22C55E) to "Connected"
        TunnelState.CONNECTING -> Color(0xFFEAB308) to "Connecting…"
        TunnelState.DISCONNECTED -> Color.Gray to "Disconnected"
        TunnelState.DISCONNECTING -> Color(0xFFF97316) to "Disconnecting"
        TunnelState.ERROR -> Color.Red to "Error"
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Surface(
            color = color,
            shape = RoundedCornerShape(999.dp),
            modifier = Modifier.size(12.dp)
        ) { }
        Text(label, fontSize = 16.sp, fontWeight = FontWeight.Medium)
    }
}
