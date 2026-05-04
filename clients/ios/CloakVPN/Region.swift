// SPDX-License-Identifier: MIT
//
// Lattice VPN — Region catalog.
//
// Hardcoded list of available Lattice regions, displayed in the in-app
// region picker (ContentView's quick-connect strip). When the user taps
// a region's flag, TunnelManager.selectRegion runs the provisioning API
// flow against that region's URL with the bundled API key, then the
// returned config is auto-imported and the user can Connect.
//
// Per-customer flow today is open-with-shared-token: every install of
// the app embeds the same API key, which acts as a "knock to enter"
// proof rather than user identity. Replacing this with proper
// per-customer auth (App Store receipt validation → JWT, Sign in with
// Apple, etc.) is part of the App Store / TestFlight readiness pass
// (task #4). Until then, the bundled token is enough for alpha/beta
// distribution.
//
// Region list is also intentionally bundled (not fetched at runtime
// from a discovery endpoint) — keeps the cold-start path zero
// network calls and lets the user see the flag strip before they have
// connectivity. New regions ship with new app versions; that's
// acceptable cadence for the next several quarters.

import Foundation

struct CloakRegion: Identifiable, Equatable, Codable {
    let id: String              // stable internal id, e.g. "us-west-1"
    let displayName: String     // user-facing label, e.g. "US West (Oregon)"
    let shortLabel: String      // ~3-char chip label under flag, e.g. "US"
    let countryFlag: String     // emoji flag
    let serverURL: String       // base URL of cloak-api-server
    let endpointIP: String      // for the IP display block

    static let all: [CloakRegion] = [
        // serverURL points at the per-region HTTPS endpoint terminated
        // by nginx (Let's Encrypt cert via Cloudflare DNS-01 challenge,
        // auto-renewed via certbot.timer). nginx proxies 443 -> 127.0.0.1:8443
        // where cloak-api-server.py listens. endpointIP is the WireGuard
        // tunnel endpoint — independent of where the provisioning API
        // lives (could in theory split if we ever shard regions).
        CloakRegion(
            id: "us-west-1",
            displayName: "US West (Oregon)",
            shortLabel: "US-W",
            countryFlag: "🇺🇸",
            serverURL: "https://cloak-us-west-1.cloakvpn.ai",
            endpointIP: "5.78.203.171"
        ),
        CloakRegion(
            id: "us-east-1",
            displayName: "US East (Virginia)",
            shortLabel: "US-E",
            countryFlag: "🇺🇸",
            serverURL: "https://cloak-us-east-1.cloakvpn.ai",
            endpointIP: "5.161.198.227"
        ),
        CloakRegion(
            id: "de1",
            displayName: "Germany (Falkenstein)",
            shortLabel: "DE",
            countryFlag: "🇩🇪",
            serverURL: "https://cloak-de1.cloakvpn.ai",
            endpointIP: "91.98.65.98"
        ),
        CloakRegion(
            id: "fi1",
            displayName: "Finland (Helsinki)",
            shortLabel: "FI",
            countryFlag: "🇫🇮",
            serverURL: "https://cloak-fi1.cloakvpn.ai",
            endpointIP: "204.168.252.70"
        ),
    ]

    /// Bootstrap key — used ONLY to authenticate the
    /// `/api/v1/auth/exchange` call which mints a per-install JWT.
    /// Provisioning calls (POST `/api/v1/peers`) authorize via the
    /// minted JWT, NOT this key.
    ///
    /// Loaded at build time from `Secrets.xcconfig` (gitignored — never
    /// committed) and exposed via `Info.plist[CLOAK_BOOTSTRAP_KEY]`.
    /// Server-side counterpart: `/etc/cloak/bootstrap-key` on every
    /// region (identical so a JWT minted by one region authorizes
    /// calls to any).
    ///
    /// Trust model: same install bundle = same key. Compromise impact
    /// is bounded — an attacker who extracts this from the binary can
    /// mint JWTs for arbitrary install UUIDs, but each JWT is short-
    /// lived (24h) and rate-limitable per-subject. When StoreKit IAP
    /// ships, this path is replaced by Apple-signed transaction JWS
    /// and the bootstrap key path gets torn out entirely.
    ///
    /// Why bundled-but-not-committed: keeps the secret out of git
    /// history while still embedding it in the shipped binary. A
    /// determined attacker can still extract it via `strings` on the
    /// .ipa, but they don't get it from a `git clone` — and rotation
    /// becomes a non-history-rewriting operation.
    static var bootstrapKey: String {
        guard let v = Bundle.main.infoDictionary?["CLOAK_BOOTSTRAP_KEY"] as? String,
              !v.isEmpty,
              !v.contains("$(") // unresolved xcconfig placeholder
        else {
            fatalError("""
            CLOAK_BOOTSTRAP_KEY missing from Info.plist.
            Build is misconfigured: copy Secrets.xcconfig.example to
            Secrets.xcconfig, fill in the live key, and ensure both
            Debug and Release configurations have "Based on Configuration
            File" set to Secrets in the project's Info tab.
            """)
        }
        return v
    }

    static func byID(_ id: String) -> CloakRegion? {
        all.first { $0.id == id }
    }
}
