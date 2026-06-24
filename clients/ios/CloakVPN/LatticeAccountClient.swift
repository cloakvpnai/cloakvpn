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
// The one iOS-specific job is in `provisionDevice`: the central API
// returns the tunnel config as JSON, but TunnelManager.importConfig
// consumes the INI block the old server emitted — so this client renders
// the JSON back into that INI format (and synthesizes the IPv6 ULA the
// iOS NetworkExtension requires, exactly as the old server did).

import Foundation

/// A failure talking to the Lattice account API, classified so the UI can
/// react appropriately (retry vs. re-enter the number vs. renew).
enum AccountError: LocalizedError {
    /// The account number was not recognized (HTTP 401).
    case unauthorized
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
struct AccountStatus: Equatable {
    let tier: String
    let deviceLimit: Int
    let deviceCount: Int
    /// RFC3339 instant the subscription is paid through.
    let activeUntil: String

    /// True when the subscription currently entitles the customer.
    var isActive: Bool { !tier.isEmpty }
}

/// Talks to the central Lattice account API (LatticeAPI.baseURL).
struct LatticeAccountClient {

    private var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        // Provisioning runs add-peer + a rosenpass restart server-side,
        // so it needs generous read headroom; capped so a hung server
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
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw AccountError.other("The server sent a response we couldn't read.")
        }
        return AccountStatus(
            tier: obj["tier"] as? String ?? "",
            deviceLimit: (obj["device_limit"] as? NSNumber)?.intValue ?? 0,
            deviceCount: (obj["device_count"] as? NSNumber)?.intValue ?? 0,
            activeUntil: obj["active_until"] as? String ?? ""
        )
    }

    // MARK: - POST /v1/device

    /// Register this device as a WireGuard + Rosenpass peer in `region`.
    /// Only the device's *public* keys are sent; the private keys are
    /// generated on-device and never leave it.
    ///
    /// Returns the tunnel config rendered as the INI block
    /// `TunnelManager.importConfig` / `ConfigParser` consume.
    func provisionDevice(
        accountNumber: String,
        wgPubkeyB64: String,
        rosenpassPubkeyB64: String,
        region: String
    ) async throws -> String {
        guard let url = URL(string: "\(LatticeAPI.baseURL)/v1/device") else {
            throw AccountError.other("Bad API URL.")
        }
        let payload: [String: Any] = [
            "wg_pubkey": wgPubkeyB64,
            "rosenpass_pubkey": rosenpassPubkeyB64,
            "region": region,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(bearer(accountNumber), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let body = try await execute(req)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let cfg = obj["config"] as? [String: Any]
        else {
            throw AccountError.other("The server response was missing the tunnel config.")
        }
        return Self.renderConfigINI(cfg)
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
        case 401: throw AccountError.unauthorized
        case 402: throw AccountError.noSubscription
        case 403: throw AccountError.deviceLimit
        case 400: throw AccountError.badRegion
        default:
            throw AccountError.other("Lattice server error (\(http.statusCode)). Please try again in a moment.")
        }
    }

    /// Render the central API's JSON `config` object into the INI block
    /// `ConfigParser.parse` expects. The central `wg.ClientConfig` is
    /// IPv4-only, so the IPv6 ULA the iOS NE requires is synthesized from
    /// the assigned tunnel address — the same `fd42:99::X/128` the old
    /// cloak-api-server emitted.
    private static func renderConfigINI(_ cfg: [String: Any]) -> String {
        func s(_ key: String) -> String { cfg[key] as? String ?? "" }

        let assignedIP = s("AssignedIP")                  // "10.99.0.5"
        let addressV4 = {
            // InterfaceAddress may now carry a trailing IPv6 ULA appended for
            // the Android IPv6 leak fix, e.g. "10.99.0.5/32, fd00::2/128".
            // iOS assigns its own IPv6 (addressV6 below), so take only the
            // first comma-separated entry: the IPv4 CIDR. Passing the whole
            // string would make IPAddressRange(from:) fail and the tunnel
            // would throw badField("addressV4") at connect time.
            let v = s("InterfaceAddress")
                .split(separator: ",")
                .first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return v.isEmpty ? "\(assignedIP)/32" : v
        }()
        let lastOctet = assignedIP.split(separator: ".").last.map(String.init) ?? "2"
        let addressV6 = "fd42:99::\(lastOctet)/128"

        var lines: [String] = []
        lines.append("[wireguard]")
        lines.append("address_v4 = \(addressV4)")
        lines.append("address_v6 = \(addressV6)")
        lines.append("dns = \(s("InterfaceDNS"))")
        lines.append("")
        lines.append("[wireguard.peer]")
        lines.append("public_key = \(s("PeerPublicKey"))")
        lines.append("endpoint = \(s("PeerEndpoint"))")
        lines.append("allowed_ips = \(s("PeerAllowedIPs"))")
        lines.append("persistent_keepalive = 25")
        lines.append("")
        lines.append("[rosenpass]")
        lines.append("server_public_key_b64 = \(s("RosenpassPeerPub"))")
        lines.append("server_endpoint = \(s("RosenpassListen"))")
        lines.append("psk_rotation_seconds = 120")
        return lines.joined(separator: "\n") + "\n"
    }
}
