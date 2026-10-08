package ai.latticevpn.android.ui.screens

import ai.latticevpn.android.ui.LatticeViewModel
import ai.latticevpn.android.ui.Screen
import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Open-source acknowledgements screen — Android counterpart of the iOS
 * `AcknowledgementsView` (build 109). Displays the bundled
 * `assets/ThirdPartyNotices.txt` (WireGuard, Rosenpass, liboqs, and their
 * MIT / Apache-2.0 license texts). Required to comply with the attribution
 * terms of those licenses. Pure in-app text — no external links.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LicensesScreen(vm: LatticeViewModel) {
    BackHandler { vm.navigateTo(Screen.SETTINGS) }

    val context = LocalContext.current
    var notices by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        notices = withContext(Dispatchers.IO) {
            runCatching {
                context.assets.open("ThirdPartyNotices.txt")
                    .bufferedReader(Charsets.UTF_8)
                    .use { it.readText() }
            }.onFailure {
                Log.e("LicensesScreen", "Failed to load ThirdPartyNotices.txt: ${it.message}")
            }.getOrDefault(
                "Lattice VPN is built on open-source software including " +
                    "WireGuard, Rosenpass, and liboqs (Open Quantum Safe). " +
                    "Full license texts could not be loaded; see latticevpn.ai.",
            )
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
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
                title = { Text("Open-Source Licenses", fontWeight = FontWeight.SemiBold) },
            )
        },
    ) { padding ->
        Text(
            text = notices,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
            lineHeight = 16.sp,
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .fillMaxWidth()
                .padding(16.dp),
        )
    }
}
