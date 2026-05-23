package ai.latticevpn.android.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

/**
 * Lattice brand Material 3 color scheme. The app is dark-only by
 * design — a VPN client is a "trust" surface and the deep-navy +
 * mint identity reads consistently in any ambient light.
 */
private val LatticeColorScheme = darkColorScheme(
    primary = LatticeMint,
    onPrimary = LatticeMintDark,
    primaryContainer = LatticeMintContainer,
    onPrimaryContainer = LatticeMint,
    secondary = LatticeAmber,
    onSecondary = LatticeNavy,
    secondaryContainer = LatticeSurfaceVariant,
    onSecondaryContainer = LatticeOnSurface,
    background = LatticeNavy,
    onBackground = LatticeOnSurface,
    surface = LatticeSurface,
    onSurface = LatticeOnSurface,
    surfaceVariant = LatticeSurfaceVariant,
    onSurfaceVariant = LatticeOnSurfaceMuted,
    error = LatticeRed,
    onError = LatticeNavy,
    outline = LatticeOutline,
    outlineVariant = LatticeOutline,
)

/** Wraps app content in the Lattice brand Material 3 theme (dark only). */
@Composable
fun LatticeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = LatticeColorScheme,
        typography = Typography(),
        content = content,
    )
}
