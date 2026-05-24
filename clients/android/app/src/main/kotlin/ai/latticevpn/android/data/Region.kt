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
        // Every concentrator that physically exists. Only the ids listed
        // in [liveRegionIds] are offered to users — see [all].
        private val catalog: List<LatticeRegion> = listOf(
            LatticeRegion(
                id = "us-west-1",
                displayName = "US West (Oregon)",
                shortLabel = "US-W",
                countryFlag = "🇺🇸",
                serverURL = "https://cloak-us-west-1.cloakvpn.ai",
                endpointIP = "5.78.203.171",
            ),
            LatticeRegion(
                id = "us-east-1",
                displayName = "US East (Virginia)",
                shortLabel = "US-E",
                countryFlag = "🇺🇸",
                serverURL = "https://cloak-us-east-1.cloakvpn.ai",
                endpointIP = "5.161.198.227",
            ),
            LatticeRegion(
                id = "de1",
                displayName = "Germany (Falkenstein)",
                shortLabel = "DE",
                countryFlag = "🇩🇪",
                serverURL = "https://cloak-de1.cloakvpn.ai",
                endpointIP = "91.98.65.98",
            ),
            LatticeRegion(
                id = "fi1",
                displayName = "Finland (Helsinki)",
                shortLabel = "FI",
                countryFlag = "🇫🇮",
                serverURL = "https://cloak-fi1.cloakvpn.ai",
                endpointIP = "204.168.252.70",
            ),
        )

        // Regions actually wired into the account API and offered in the
        // app. The other concentrators in [catalog] exist but multi-region
        // provisioning is not built yet (BILLING_INTEGRATION.md §7) — add
        // their ids here once it ships, and the picker re-expands on its own.
        private val liveRegionIds = setOf("us-west-1")

        /** Regions shown to the user — only the ones that actually work. */
        val all: List<LatticeRegion> = catalog.filter { it.id in liveRegionIds }

        fun byId(id: String): LatticeRegion? = all.firstOrNull { it.id == id }
    }
}
