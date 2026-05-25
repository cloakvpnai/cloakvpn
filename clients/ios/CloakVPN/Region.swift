// SPDX-License-Identifier: MIT
//
// Lattice VPN — Region catalog.
//
// Hardcoded list of Lattice regions, displayed in the in-app region
// picker. When the user taps a region, TunnelManager.selectRegion sends
// the region `id` on POST /v1/device to the central account API, which
// routes the peer onto that region's concentrator and returns the tunnel
// config (BILLING_INTEGRATION.md §7).
//
// `id` is the contract: it must match the ids in the server's
// regions.json exactly. `endpointIP` is the WireGuard tunnel endpoint,
// shown in the picker for reference.
//
// The list is bundled (not fetched at runtime) so the cold-start path
// makes zero network calls and the picker renders before the device even
// has connectivity. New regions ship with new app versions.

import Foundation

struct CloakRegion: Identifiable, Equatable, Codable {
    let id: String              // stable internal id, e.g. "us-west-1"
    let displayName: String     // user-facing label, e.g. "US West (Oregon)"
    let shortLabel: String      // ~3-char chip label under flag, e.g. "US-W"
    let countryFlag: String     // emoji flag
    let endpointIP: String      // WireGuard tunnel endpoint, for display

    /// Every concentrator wired into the central account API. All ten are
    /// live (BILLING_INTEGRATION.md §7).
    static let all: [CloakRegion] = [
        CloakRegion(id: "us-west-1",    displayName: "US West (Oregon)",
                    shortLabel: "US-W", countryFlag: "🇺🇸", endpointIP: "5.78.203.171"),
        CloakRegion(id: "us-east-1",    displayName: "US East (Virginia)",
                    shortLabel: "US-E", countryFlag: "🇺🇸", endpointIP: "5.161.198.227"),
        CloakRegion(id: "us-central-1", displayName: "US Central (Dallas)",
                    shortLabel: "US-C", countryFlag: "🇺🇸", endpointIP: "207.148.1.253"),
        CloakRegion(id: "de1",          displayName: "Germany (Falkenstein)",
                    shortLabel: "DE",   countryFlag: "🇩🇪", endpointIP: "91.98.65.98"),
        CloakRegion(id: "fi1",          displayName: "Finland (Helsinki)",
                    shortLabel: "FI",   countryFlag: "🇫🇮", endpointIP: "204.168.252.70"),
        CloakRegion(id: "es1",          displayName: "Spain (Madrid)",
                    shortLabel: "ES",   countryFlag: "🇪🇸", endpointIP: "65.20.99.121"),
        CloakRegion(id: "mx1",          displayName: "Mexico (Mexico City)",
                    shortLabel: "MX",   countryFlag: "🇲🇽", endpointIP: "216.238.95.21"),
        CloakRegion(id: "za1",          displayName: "South Africa (Johannesburg)",
                    shortLabel: "ZA",   countryFlag: "🇿🇦", endpointIP: "139.84.248.50"),
        CloakRegion(id: "in1",          displayName: "India (Mumbai)",
                    shortLabel: "IN",   countryFlag: "🇮🇳", endpointIP: "65.20.77.179"),
        CloakRegion(id: "jp1",          displayName: "Japan (Tokyo)",
                    shortLabel: "JP",   countryFlag: "🇯🇵", endpointIP: "167.179.75.10"),
    ]

    static func byID(_ id: String) -> CloakRegion? {
        all.first { $0.id == id }
    }
}
