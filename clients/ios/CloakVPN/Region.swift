// SPDX-License-Identifier: MIT
//
// Cloak VPN — Region catalog.
//
// Hardcoded list of available Cloak regions, displayed in the in-app
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
        CloakRegion(
            id: "us-west-1",
            displayName: "US West (Oregon)",
            shortLabel: "US-W",
            countryFlag: "🇺🇸",
            serverURL: "http://5.78.203.171:8443",
            endpointIP: "5.78.203.171"
        ),
        CloakRegion(
            id: "us-east-1",
            displayName: "US East (Virginia)",
            shortLabel: "US-E",
            countryFlag: "🇺🇸",
            serverURL: "http://5.161.198.227:8443",
            endpointIP: "5.161.198.227"
        ),
        CloakRegion(
            id: "de1",
            displayName: "Germany (Falkenstein)",
            shortLabel: "DE",
            countryFlag: "🇩🇪",
            serverURL: "http://91.98.65.98:8443",
            endpointIP: "91.98.65.98"
        ),
        CloakRegion(
            id: "fi1",
            displayName: "Finland (Helsinki)",
            shortLabel: "FI",
            countryFlag: "🇫🇮",
            serverURL: "http://204.168.252.70:8443",
            endpointIP: "204.168.252.70"
        ),
    ]

    /// Bundled API key. See file-level comment about the trust model
    /// — this gets replaced with per-customer auth before public
    /// launch. Compromise impact today: an attacker with the binary
    /// can register peers freely on any region (resource exhaustion,
    /// free tunneling). Mitigations in place: rate limiting (TODO),
    /// IP allocation per /32 (subnet caps usage at ~250 peers per
    /// region before we need add-peer.sh GC).
    static let bundledAPIKey = "<REDACTED-OLD-API-KEY>"

    static func byID(_ id: String) -> CloakRegion? {
        all.first { $0.id == id }
    }
}
