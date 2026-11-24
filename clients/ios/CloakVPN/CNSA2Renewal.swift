import CryptoKit
import Foundation
import os.log

/// One CNSA 2.0 gateway. `name` is the name in its certificate, which the tunnel checks.
struct CNSA2Gateway: Equatable {
    let id: String
    let host: String
    let port: Int
    let name: String
}

/// Getting and renewing this device's CNSA 2.0 certificate through the account API.
///
/// Compiled into the app and into the tunnel extension. The extension is the one
/// process that is always running while the tunnel is up, so it does the periodic
/// renewal: a device that stays connected for weeks with the app closed never
/// reaches expiry. The app uses the same code to enroll and to renew when opened.
///
/// The device's ML-DSA-87 key never leaves the device; only a certificate request
/// goes out. A reply is accepted only if the root certificate is the Lattice root
/// this build was compiled with and the device certificate carries this device's key.
enum CNSA2Renewal {
    /// SHA-256 of the Lattice VPN CNSA2 Root CA G1 certificate (signed Nov 23, 2026).
    static let rootSHA256 = "03f0a61239af18dcacf6753422c004d04674e324d7b10baa1b4f9eb49150f5bc"
    /// A 30 day certificate is renewed in its last 10 days, with the same key.
    static let renewBefore: TimeInterval = 10 * 24 * 60 * 60

    struct Failure: LocalizedError {
        /// HTTP status, or 0 when the server could not be reached or the reply was refused.
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    struct Reply {
        let root: Data
        let notAfter: Date
        let deviceID: Int64
        let deviceUID: String
        let gateways: [CNSA2Gateway]
    }

    private static let log = OSLog(subsystem: "ai.cloakvpn.CloakVPN", category: "cnsa2renewal")

    // MARK: pure checks

    static func isLatticeRoot(_ der: Data) -> Bool {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined() == rootSHA256
    }

    /// Parses the server's expiry, for example 2026-12-24T09:34:11Z.
    static func parseExpiry(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// True in the last 10 days of the certificate and after its expiry.
    static func isDue(expiry: Date?, now: Date) -> Bool {
        guard let expiry else { return false }
        return now >= expiry.addingTimeInterval(-renewBefore)
    }

    /// True when a certificate exists and is inside the renewal window or past its expiry.
    static func renewalDue(now: Date = Date()) -> Bool {
        CNSA2Identity.certificate() != nil && isDue(expiry: CNSA2Identity.certificateExpiry, now: now)
    }

    // MARK: renewal

    /// Renews if due, using the signed-in account. Returns true if a new certificate was stored.
    /// Failures are logged and left for the next check; nothing here can break a working tunnel.
    @discardableResult
    static func renewIfDue() async -> Bool {
        guard renewalDue(), let number = AppGroupKeyStore.loadAccountNumber() else { return false }
        do {
            let reply = try await issue(accountNumber: number)
            os_log("certificate renewed, valid to %{public}s", log: log, type: .default,
                   ISO8601DateFormatter().string(from: reply.notAfter))
            return true
        } catch {
            os_log("renewal failed: %{public}s", log: log, type: .error, error.localizedDescription)
            return false
        }
    }

    /// Requests a certificate for this device's key (creating the key on first use),
    /// checks the reply, and stores the certificate and its expiry in the keychain.
    static func issue(accountNumber: String) async throws -> Reply {
        // The name in the request is ignored by the server, which names the device itself.
        let request = try CNSA2Identity.certificateRequest(commonName: "lattice-device")
        guard let url = URL(string: "\(LatticeAPI.baseURL)/v1/device/cnsa2/enroll") else {
            throw Failure(status: 0, message: "Bad API URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer " + LatticeAPI.format(accountNumber), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["request": request.base64EncodedString()])

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession(configuration: .ephemeral).data(for: req)
        } catch {
            throw Failure(status: 0, message: "Couldn't reach Lattice. Check your connection and try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw Failure(status: status, message: message(for: status)) }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let certificate = (obj["certificate"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let root = (obj["root"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let notAfter = (obj["not_after"] as? String).flatMap(parseExpiry)
        else {
            throw Failure(status: 0, message: "The server sent an enrollment reply we couldn't read.")
        }
        guard isLatticeRoot(root) else {
            throw Failure(status: 0, message: "The server's certificate authority is not the one this app trusts.")
        }
        do {
            try CNSA2Identity.storeCertificate(certificate)   // refuses a certificate for another key
            try CNSA2Identity.setCertificateExpiry(notAfter)
        } catch {
            throw Failure(status: 0, message: "The server sent a certificate this device cannot use (\(error)).")
        }
        let device = obj["device"] as? [String: Any]
        let gateways = parseGateways(obj["gateways"])
        return Reply(root: root, notAfter: notAfter,
                     deviceID: (device?["id"] as? NSNumber)?.int64Value ?? 0,
                     deviceUID: device?["uid"] as? String ?? "", gateways: gateways)
    }

    /// The gateways a signed-in app may use, without asking for a certificate.
    static func fetchGateways(accountNumber: String) async throws -> [CNSA2Gateway] {
        guard let url = URL(string: "\(LatticeAPI.baseURL)/v1/cnsa2/gateways") else {
            throw Failure(status: 0, message: "Bad API URL.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer " + LatticeAPI.format(accountNumber), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw Failure(status: status, message: message(for: status)) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(status: 0, message: "The server sent a gateway list we couldn't read.")
        }
        return parseGateways(obj["gateways"])
    }

    /// Removes this device from the account. The server revokes its certificates.
    static func removeDevice(accountNumber: String, deviceID: Int64) async throws {
        guard let url = URL(string: "\(LatticeAPI.baseURL)/v1/device/cnsa2?id=\(deviceID)") else {
            throw Failure(status: 0, message: "Bad API URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 15
        req.setValue("Bearer " + LatticeAPI.format(accountNumber), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) || status == 404 else {
            throw Failure(status: status, message: message(for: status))
        }
    }

    static func parseGateways(_ value: Any?) -> [CNSA2Gateway] {
        ((value as? [[String: Any]]) ?? []).compactMap { g -> CNSA2Gateway? in
            guard let host = g["host"] as? String, let name = g["name"] as? String else { return nil }
            return CNSA2Gateway(id: g["id"] as? String ?? "", host: host, port: g["port"] as? Int ?? 1194, name: name)
        }
    }

    private static func message(for status: Int) -> String {
        switch status {
        case 401: return "That account number wasn't recognized. Check it and try again."
        case 402: return "This subscription isn't active. Renew it at latticevpn.ai to continue."
        case 403: return "You've reached your device limit. Remove a device to add this one."
        case 409: return "This device is already registered to a different account."
        case 429: return "Too many requests. Please try again in a little while."
        default: return "Lattice server error (\(status)). Please try again in a moment."
        }
    }
}
