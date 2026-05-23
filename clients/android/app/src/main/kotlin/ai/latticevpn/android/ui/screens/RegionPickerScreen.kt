package ai.latticevpn.android.ui.screens

import ai.latticevpn.android.data.LatticeRegion
import ai.latticevpn.android.ui.LatticeViewModel
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

/**
 * Region picker — Phase A6. Lists the hardcoded [LatticeRegion] catalog
 * and provisions the device against whichever the user taps via
 * [LatticeViewModel.selectRegion]. On success it returns to Home; on
 * failure it surfaces the error in a snackbar and stays put.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RegionPickerScreen(vm: LatticeViewModel) {
    BackHandler { vm.navigateHome() }

    val selected by vm.selectedRegion.collectAsState()
    val snackbarHost = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    // The id of the region currently being provisioned, or null when idle.
    var pendingId by remember { mutableStateOf<String?>(null) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbarHost) },
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
                title = { Text("Select location", fontWeight = FontWeight.SemiBold) },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item {
                Text(
                    text = "All locations run the same post-quantum (Rosenpass) " +
                        "key exchange. Pick the one closest to you for the best speed.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(bottom = 6.dp),
                )
            }
            items(LatticeRegion.all, key = { it.id }) { region ->
                RegionRow(
                    region = region,
                    isSelected = region.id == selected?.id,
                    isProvisioning = region.id == pendingId,
                    enabled = pendingId == null,
                    onClick = {
                        pendingId = region.id
                        vm.selectRegion(region) { error ->
                            if (error == null) {
                                vm.navigateHome()
                            } else {
                                pendingId = null
                                scope.launch { snackbarHost.showSnackbar(error) }
                            }
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun RegionRow(
    region: LatticeRegion,
    isSelected: Boolean,
    isProvisioning: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val borderColor =
        if (isSelected) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.outline

    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, borderColor),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text = region.countryFlag, fontSize = 28.sp)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = region.displayName,
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Medium,
                )
                Text(
                    text = region.endpointIP,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontSize = 12.sp,
                )
            }
            Spacer(Modifier.width(12.dp))
            when {
                isProvisioning -> CircularProgressIndicator(
                    modifier = Modifier.size(22.dp),
                    strokeWidth = 2.5.dp,
                    color = MaterialTheme.colorScheme.primary,
                )
                isSelected -> Icon(
                    Icons.Filled.Check,
                    contentDescription = "Selected",
                    tint = MaterialTheme.colorScheme.primary,
                )
                else -> ShortLabelChip(region.shortLabel)
            }
        }
    }
}

@Composable
private fun ShortLabelChip(label: String) {
    Surface(
        shape = RoundedCornerShape(6.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Text(
            text = label,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
        )
    }
}
