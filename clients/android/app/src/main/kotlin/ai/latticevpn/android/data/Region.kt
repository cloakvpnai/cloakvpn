package ai.latticevpn.android.data

/**
 * Lattice VPN region catalog — the Kotlin port of the iOS Region.swift.
 *
 * Hardcoded (not fetched at runtime) so the cold-start path makes zero
 * network calls and the region picker renders before the device even
 * has connectivity. New regions ship with new app versions — an
 * acceptable cadence.
 *
 * `serverURL` is the region's own cloak-api-server endpoint. With the
 * account-number model the app provisions through the central
 * [LatticeApi.BASE_URL] instead, so `serverURL` is retained only for
 * reference and the future multi-region work (BILLING_INTEGRATION.md
 * §7). `endpointIP` is the WireGuard tunnel endpoint, shown in the
 * region picker.
 */
data class LatticeRegion(
    val id: String,            // stable internal id, e.g. "us-west-1"
    val displayName: String,   // user-facing label, e.g. "US West (Oregon)"
    val shortLabel: String,    // ~3-char chip label, e.g. "US-W"
    val countryFlag: String,   // emoji flag
    val serverURL: String,     // base URL of cloak-api-server
    val endpointIP: String,    // WireGuard tunnel endpoint, for display
) {
    companion object {
        val all: List<LatticeRegion> = listOf(
            LatticeRegion(
                id = "us-west-1",
                displayName = "US West (Oregon)",
                shortLabel = "US-W",
                countryFlag = "🇺🇸", // 🇺🇸
                serverURL = "https://cloak-us-west-1.cloakvpn.ai",
                endpointIP = "5.78.203.171",
            ),
            LatticeRegion(
                id = "us-east-1",
                displayName = "US East (Virginia)",
                shortLabel = "US-E",
                countryFlag = "🇺🇸", // 🇺🇸
                serverURL = "https://cloak-us-east-1.cloakvpn.ai",
                endpointIP = "5.161.198.227",
            ),
            LatticeRegion(
                id = "de1",
                displayName = "Germany (Falkenstein)",
                shortLabel = "DE",
                countryFlag = "🇩🇪", // 🇩🇪
                serverURL = "https://cloak-de1.cloakvpn.ai",
                endpointIP = "91.98.65.98",
            ),
            LatticeRegion(
                id = "fi1",
                displayName = "Finland (Helsinki)",
                shortLabel = "FI",
                countryFlag = "🇫🇮", // 🇫🇮
                serverURL = "https://cloak-fi1.cloakvpn.ai",
                endpointIP = "204.168.252.70",
            ),
        )

        fun byId(id: String): LatticeRegion? = all.firstOrNull { it.id == id }
    }
}
