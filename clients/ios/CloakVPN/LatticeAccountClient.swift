// SPDX-License-Identifier: MIT
//
// Lattice VPN — central account + provisioning API client.
//
// Talks to the one central `cloakvpn-api` at LatticeAPI.baseURL. Every
// call authenticates with the customer's account number as an
// `Authorization: Bearer` token — there are no user accounts, JWTs, or
// bootstrap keys. This replaces the old CloakAuthClient (JWT bootstrap)
// + the per-region cloak-api-server provisioning path.
//
// iOS port of the Android `AccountClient`; the wire format is identical.

import Foundation

/// A failure talking to the Lattice account API, classified so the UI can
/// react appropriately (retry vs. re-enter the number vs. renew).
enum AccountError: LocalizedError {
    /// The account number was not recognized (HTTP 401).
    /// `serverKeepsPreviousNumbers` is true when the server marked the 401
    /// with `X-Lattice-Keeps-Previous-Numbers: 1`, i.e. it keeps old numbers
    /// valid on a store restore, so silently redeeming this device's App Store
    /// entitlement for a new number cannot sign out the customer's other
    /// devices. Older servers omit the header; never auto-redeem against them.
    case unauthorized(serverKeepsPreviousNumbers: Bool)
    /// A number that used to work is no longer recognized, and it could not
    /// be recovered automatically from an App Store subscription on this
    /// device. Raised by TunnelManager, never by the HTTP layer.
    case numberReplaced
    /// Recognized, but the subscription is not active (HTTP 402).
    case noSubscription
    /// Every device slot for this subscription is in use (HTTP 403).
    case deviceLimit
    /// The chosen region is not known to the server (HTTP 400).
    case badRegion
    /// The server could not be reached at all.
    case network
    /// Anything else (5xx, malformed response, …).
    case other(String)

    /// Customer-facing message — safe to show directly in an alert.
    var userMessage: String {
        switch self {
        case .unauthorized:
            return "That account number wasn't recognized. Check it and try again."
        case .numberReplaced:
            return "This device's account number is no longer active. It may have been replaced when your subscription was restored on another device. Sign out, then tap Restore Purchases or enter your current account number."
        case .noSubscription:
            return "This subscription isn't active. Renew it at latticevpn.ai to continue."
        case .deviceLimit:
            return "You've reached your device limit. Remove a device to add this one."
        case .badRegion:
            return "That location is unavailable right now. Try another."
        case .network:
            return "Couldn't reach Lattice. Check your connection and try again."
        case .other(let detail):
            return detail
        }
    }

    var errorDescription: String? { userMessage }
}

/// The server's view of a subscription — backs the Account screen and the
/// sign-in validation.
struct AccountStatus: Equatable, Decodable {
    let tier: String
    let deviceLimit: Int
    let deviceCount: Int
    /// RFC3339 instant the subscription is paid through.
    let activeUntil: String

    private enum CodingKeys: String, CodingKey {
        case tier
        case deviceLimit = "device_limit"
        case deviceCount = "device_count"
        case activeUntil = "active_until"
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        tier = try fields.decode(String.self, forKey: .tier)
        deviceLimit = try fields.decode(Int.self, forKey: .deviceLimit)
        deviceCount = try fields.decode(Int.self, forKey: .deviceCount)
        activeUntil = try fields.decode(String.self, forKey: .activeUntil)
        guard tier == tier.trimmingCharacters(in: .whitespacesAndNewlines),
              deviceLimit >= 0, deviceCount >= 0,
              Self.parseExpiry(activeUntil) != nil,
              tier.isEmpty ? deviceLimit == 0 : deviceLimit > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid subscription status fields."))
        }
    }

    private static func parseExpiry(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    var activeUntilDate: Date? { Self.parseExpiry(activeUntil) }

    func isActive(at date: Date) -> Bool {
        guard !tier.isEmpty, deviceLimit > 0, let expiry = activeUntilDate else { return false }
        return expiry > date
    }

    /// Eligibility requires a complete response and an unexpired entitlement.
    var isActive: Bool { isActive(at: Date()) }
}

/// Talks to the central Lattice account API (LatticeAPI.baseURL).
struct LatticeAccountClient {

    private var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        // Generous read headroom for slow links; capped so a hung server
        // cannot block the UI indefinitely.
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }

    // MARK: - GET /v1/account

    /// Fetch subscription state. Used both to validate an account number
    /// at sign-in and to populate the Account screen. Throws
    /// `AccountError.unauthorized` if the number is unknown.
    func fetchAccount(accountNumber: String) async throws -> AccountStatus {
        guard let url = URL(string: "\(LatticeAPI.baseURL)/v1/account") else {
            throw AccountError.other("Bad API URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(bearer(accountNumber), forHTTPHeaderField: "Authorization")

        let body = try await execute(req)
        do {
            return try JSONDecoder().decode(AccountStatus.self, from: body)
        } catch {
            // Never log response bodies or credentials. Missing/type-invalid fields
            // are an API error, not evidence of an inactive subscription.
            throw AccountError.other("Lattice returned incomplete or invalid subscription information. Please refresh and try again.")
        }
    }

    // MARK: - DELETE /v1/device

    /// Release a device slot so a customer at their device limit can free
    /// one. `deviceID` comes from the Account screen's device list.
    func revokeDevice(accountNumber: String, deviceID: Int) async throws {
        guard let url = URL(string: "\(LatticeAPI.baseURL)/v1/device?id=\(deviceID)") else {
            throw AccountError.other("Bad API URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(bearer(accountNumber), forHTTPHeaderField: "Authorization")
        _ = try await execute(req)  // 204 No Content — body unused
    }

    // MARK: - Internals

    private func bearer(_ accountNumber: String) -> String {
        "Bearer " + LatticeAPI.format(accountNumber)
    }

    /// Run `request`, returning the response body on a 2xx, or throwing a
    /// classified `AccountError` otherwise.
    private func execute(_ request: URLRequest) async throws -> Data {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: request)
        } catch {
            throw AccountError.network
        }
        guard let http = resp as? HTTPURLResponse else {
            throw AccountError.other("Unexpected response from Lattice.")
        }
        if (200...299).contains(http.statusCode) {
            return data
        }
        switch http.statusCode {
        case 401:
            let keeps = http.value(forHTTPHeaderField: "X-Lattice-Keeps-Previous-Numbers") == "1"
            throw AccountError.unauthorized(serverKeepsPreviousNumbers: keeps)
        case 402: throw AccountError.noSubscription
        case 403: throw AccountError.deviceLimit
        case 400: throw AccountError.badRegion
        case 409: throw AccountError.other("This device is already registered to a different account.")
        case 429: throw AccountError.other("Too many requests. Please try again in a little while.")
        default:
            throw AccountError.other("Lattice server error (\(http.statusCode)). Please try again in a moment.")
        }
    }

}
