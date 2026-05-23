package ai.latticevpn.android.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Lattice VPN brand palette — Phase A6.
 *
 * Derived from the website-v2 brand tokens and the Lattice logo: a
 * deep-navy canvas, a mint-green primary accent ("secure / connected"),
 * and a warm amber for transitional ("connecting") states.
 */

// Surfaces — deep navy, darkest at the base.
val LatticeNavy           = Color(0xFF0A1628) // window / Scaffold background
val LatticeNavyElevated   = Color(0xFF0E1F3A) // top of the background gradient
val LatticeSurface        = Color(0xFF13243F) // cards, sheets
val LatticeSurfaceVariant = Color(0xFF1C2F4E) // inputs, chips, inset rows
val LatticeOutline        = Color(0xFF2A3F63) // hairline borders, ring tracks

// Accents.
val LatticeMint           = Color(0xFF5FE3B5) // primary — "secure / connected"
val LatticeMintDark       = Color(0xFF06231A) // text/icons on a mint fill
val LatticeMintContainer  = Color(0xFF124A38) // low-emphasis mint fill
val LatticeAmber          = Color(0xFFF4B740) // secondary — "connecting"
val LatticeRed            = Color(0xFFF87171) // error

// Text.
val LatticeOnSurface      = Color(0xFFEAF1F8) // primary text
val LatticeOnSurfaceMuted = Color(0xFF93A4BE) // secondary text, disabled
