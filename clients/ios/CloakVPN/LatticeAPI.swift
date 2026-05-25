// SPDX-License-Identifier: MIT
//
// Lattice VPN — central account API constants + account-number helpers.
//
// In the no-account billing model the customer's only credential is the
// account number they receive after subscribing at latticevpn.ai — there
// is no email and no password. Every call to the account API authenticates
// with it as an `Authorization: Bearer` token.
//
// This is the iOS port of the Android `LatticeApi`; the normalize/format
// rules must agree with server/api/internal/account/account.go exactly so
// the server hashes the same symbols the app sends.

import Foundation

enum LatticeAPI {

    /// HTTPS base URL of the Lattice account API — a Caddy reverse proxy
    /// terminating TLS in front of the central `cloakvpn-api`. No trailing
    /// slash. See docs/DEPLOY_API.md.
    static let baseURL = "https://api.latticevpn.ai"

    /// Symbol count of a complete account number
    /// (server/api/internal/account).
    static let accountNumberLength = 25

    /// Crockford base-32 alphabet — excludes I, L, O, U. Must match
    /// server/api/internal/account/account.go exactly.
    private static let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Strip an account number to its bare symbols: uppercased, with all
    /// hyphens, whitespace and any non-alphabet characters removed. The
    /// server hashes the normalized form, so this only has to agree with it.
    static func normalize(_ input: String) -> String {
        String(input.uppercased().filter { crockford.contains($0) })
    }

    /// Canonical display form: the symbols regrouped into hyphenated groups
    /// of five, e.g. "36ASS-06QHX-877TR-8T1D0-6DV38". Safe to send to the
    /// server as-is — it normalizes before hashing.
    static func format(_ input: String) -> String {
        let symbols = Array(normalize(input))
        var groups: [String] = []
        var i = 0
        while i < symbols.count {
            let end = min(i + 5, symbols.count)
            groups.append(String(symbols[i..<end]))
            i += 5
        }
        return groups.joined(separator: "-")
    }

    /// True when `input` has the full complement of account-number symbols.
    static func isComplete(_ input: String) -> Bool {
        normalize(input).count == accountNumberLength
    }
}
