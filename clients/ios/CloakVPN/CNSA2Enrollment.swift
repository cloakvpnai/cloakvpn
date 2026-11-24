import CryptoKit
import Foundation

/// One CNSA 2.0 gateway. `name` is the name in its certificate, which the tunnel checks.
struct CNSA2Gateway: Equatable {
    let id: String
    let host: String
    let port: Int
    let name: String
}

/// Reply to POST /v1/device/cnsa2/enroll. Certificates are DER.
struct CNSA2EnrollmentReply {
    let certificate: Data
    let root: Data
    let notAfter: String
    let deviceID: Int64
    let deviceUID: String
    let gateways: [CNSA2Gateway]
}

/// Enrolls this device for CNSA 2.0 mode through the account API.
///
/// The device's ML-DSA-87 key is made here and never leaves the device. Only a
/// certificate request goes out. What comes back is accepted only if:
///  - the root certificate is the Lattice root this build was compiled with, and
///  - the device certificate carries this device's own public key.
///
/// The certificate lasts 30 days and is renewed from day 20 with the same key.
/// An actor, so the app's connect path and its daily timer cannot renew at the same moment.
actor CNSA2Enroller {
    static let shared = CNSA2Enroller()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// SHA-256 of the Lattice VPN CNSA2 Root CA G1 certificate (signed Nov 23, 2026).
    static let rootSHA256 = "03f0a61239af18dcacf6753422c004d04674e324d7b10baa1b4f9eb49150f5bc"
    static let rekeySeconds = 600
    static let renewBefore: TimeInterval = 10 * 24 * 60 * 60

    private let client = LatticeAccountClient()
    private let defaults = UserDefaults.standard
    private enum Key {
        static let notAfter = "cnsa2.enrollment.notAfter"
        static let deviceID = "cnsa2.enrollment.deviceID"
        static let gateway = "cnsa2.enrollment.gateway"
    }

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

    // MARK: state

    private var expiry: Date? {
        let t = defaults.double(forKey: Key.notAfter)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// The gateway saved at the last enrollment.
    var gateway: CNSA2Gateway? {
        guard let d = defaults.dictionary(forKey: Key.gateway),
              let id = d["id"] as? String, let host = d["host"] as? String,
              let port = d["port"] as? Int, let name = d["name"] as? String else { return nil }
        return CNSA2Gateway(id: id, host: host, port: port, name: name)
    }

    /// The server's id for this device, needed to remove it from the account.
    var deviceID: Int64? {
        let v = (defaults.object(forKey: Key.deviceID) as? NSNumber)?.int64Value ?? 0
        return v > 0 ? v : nil
    }

    /// True when the device cannot connect without enrolling first.
    func needsEnrollment(now: Date = Date()) -> Bool {
        guard CNSA2Identity.isEnrolled, gateway != nil, Self.bundledRootCheck() != nil, let expiry else { return true }
        return now >= expiry
    }

    /// True when a certificate exists and is inside the renewal window or past its expiry.
    func renewalDue(now: Date = Date()) -> Bool {
        CNSA2Identity.certificate() != nil && Self.isDue(expiry: expiry, now: now)
    }

    // MARK: enrollment

    /// Enrolls if needed and returns the provider configuration for the tunnel.
    func configuration(accountNumber: String) async throws -> [String: Any] {
        if needsEnrollment() { try await enroll(accountNumber: accountNumber) }
        guard let gateway else { throw Failure(message: "No CNSA 2.0 gateway is available yet.") }
        guard let root = Self.bundledRootCheck() else { throw Failure(message: "This device is not enrolled.") }
        return ["host": gateway.host, "port": gateway.port, "gatewayID": gateway.name,
                "caDER": root, "rekeySeconds": Self.rekeySeconds]
    }

    /// Renews if still due. Returns true if a new certificate was stored.
    @discardableResult
    func renewIfDue(accountNumber: String) async throws -> Bool {
        guard renewalDue() else { return false }
        try await enroll(accountNumber: accountNumber)
        return true
    }

    /// Enrolls, or renews with the existing key.
    func enroll(accountNumber: String) async throws {
        // The name in the request is ignored by the server, which names the device itself.
        let request = try CNSA2Identity.certificateRequest(commonName: "lattice-device")
        let reply = try await client.enrollCNSA2(accountNumber: accountNumber, request: request)
        guard Self.isLatticeRoot(reply.root) else {
            throw Failure(message: "The server's certificate authority is not the one this app trusts.")
        }
        guard let expiry = Self.parseExpiry(reply.notAfter) else {
            throw Failure(message: "The server sent a certificate without a usable expiry.")
        }
        guard let gateway = reply.gateways.first else {
            throw Failure(message: "No CNSA 2.0 gateway is available yet.")
        }
        do {
            try CNSA2Identity.storeCertificate(reply.certificate)
        } catch {
            throw Failure(message: "The server sent a certificate this device cannot use (\(error)).")
        }
        defaults.set(reply.root.base64EncodedString(), forKey: Self.rootKey)
        defaults.set(expiry.timeIntervalSince1970, forKey: Key.notAfter)
        defaults.set(NSNumber(value: reply.deviceID), forKey: Key.deviceID)
        defaults.set(["id": gateway.id, "host": gateway.host, "port": gateway.port, "name": gateway.name],
                     forKey: Key.gateway)
    }

    private static let rootKey = "cnsa2.enrollment.root"

    /// The saved root, base64, if it is still the pinned Lattice root.
    private static func bundledRootCheck() -> String? {
        guard let b64 = UserDefaults.standard.string(forKey: rootKey),
              let der = Data(base64Encoded: b64), isLatticeRoot(der) else { return nil }
        return b64
    }
}
