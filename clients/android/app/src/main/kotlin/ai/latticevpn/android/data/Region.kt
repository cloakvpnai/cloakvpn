package ai.latticevpn.android.data

import ai.latticevpn.android.BuildConfig

/**
 * Lattice VPN region catalog — the Kotlin port of the iOS Region.swift.
 *
 * Hardcoded (not fetched at runtime) so the cold-start path makes zero
 * network calls and the region picker renders before the device even
 * has connectivity. New regions ship with new app versions — an
 * acceptable cadence.
 *
 * `serverURL` is the per-region HTTPS cloak-api-server endpoint (used
 * for auth + peer provisioning). `endpointIP` is the WireGuard tunnel
 * endpoint — kept separate because the provisioning API and the tunnel
 * endpoint could in principle live on different hosts.
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

        /**
         * Bootstrap key — authenticates ONLY the /api/v1/auth/exchange
         * call that mints a per-install JWT. Provisioning calls
         * authorize via the minted JWT, not this key.
         *
         * Injected at build time from clients/android/secrets.properties
         * (gitignored) into BuildConfig — the Android equivalent of the
         * iOS Secrets.xcconfig -> Info.plist path. Same value as the iOS
         * app and /etc/cloak/bootstrap-key on every region.
         */
        val bootstrapKey: String
            get() = BuildConfig.CLOAK_BOOTSTRAP_KEY
    }
}
