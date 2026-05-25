package ai.latticevpn.android.data

/**
 * Lattice VPN region catalog — the Kotlin port of the iOS Region.swift.
 *
 * Hardcoded (not fetched at runtime) so the cold-start path makes zero
 * network calls and the region picker renders before the device even
 * has connectivity. New regions ship with new app versions — an
 * acceptable cadence.
 *
 * With the account-number model the app provisions every region through
 * the central [LatticeApi.BASE_URL]; it sends the region [id] on
 * POST /v1/device and the central API routes the peer onto that region's
 * concentrator (BILLING_INTEGRATION.md §7). `serverURL` is vestigial —
 * the old per-region cloak-api-server endpoint — kept only for reference.
 * `endpointIP` is the WireGuard tunnel endpoint, shown in the picker.
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
                id = "us-central-1",
                displayName = "US Central (Dallas)",
                shortLabel = "US-C",
                countryFlag = "🇺🇸",
                serverURL = "https://rgn-us-central-1.latticevpn.ai",
                endpointIP = "207.148.1.253",
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
            LatticeRegion(
                id = "es1",
                displayName = "Spain (Madrid)",
                shortLabel = "ES",
                countryFlag = "🇪🇸",
                serverURL = "https://rgn-es1.latticevpn.ai",
                endpointIP = "65.20.99.121",
            ),
            LatticeRegion(
                id = "mx1",
                displayName = "Mexico (Mexico City)",
                shortLabel = "MX",
                countryFlag = "🇲🇽",
                serverURL = "https://rgn-mx1.latticevpn.ai",
                endpointIP = "216.238.95.21",
            ),
            LatticeRegion(
                id = "za1",
                displayName = "South Africa (Johannesburg)",
                shortLabel = "ZA",
                countryFlag = "🇿🇦",
                serverURL = "https://rgn-za1.latticevpn.ai",
                endpointIP = "139.84.248.50",
            ),
            LatticeRegion(
                id = "in1",
                displayName = "India (Mumbai)",
                shortLabel = "IN",
                countryFlag = "🇮🇳",
                serverURL = "https://rgn-in1.latticevpn.ai",
                endpointIP = "65.20.77.179",
            ),
            LatticeRegion(
                id = "jp1",
                displayName = "Japan (Tokyo)",
                shortLabel = "JP",
                countryFlag = "🇯🇵",
                serverURL = "https://rgn-jp1.latticevpn.ai",
                endpointIP = "167.179.75.10",
            ),
        )

        // Regions wired into the account API and offered in the app. All
        // ten concentrators are live (BILLING_INTEGRATION.md §7, built);
        // this set gates the picker, so it stays explicit.
        private val liveRegionIds = setOf(
            "us-west-1", "us-east-1", "us-central-1", "de1", "fi1",
            "es1", "mx1", "za1", "in1", "jp1",
        )

        /** Regions shown to the user — only the ones that actually work. */
        val all: List<LatticeRegion> = catalog.filter { it.id in liveRegionIds }

        fun byId(id: String): LatticeRegion? = all.firstOrNull { it.id == id }
    }
}
