import Foundation

/// App side of CNSA 2.0 enrollment: enrolls the device the first time the mode is
/// used and remembers which gateway the server named. The request, the checks on the
/// reply and the renewal rule live in `CNSA2Renewal`, which the tunnel extension
/// shares. An actor, so two enrollments from the app cannot overlap.
actor CNSA2Enroller {
    static let shared = CNSA2Enroller()

    static let rekeySeconds = 600

    private let defaults = UserDefaults.standard
    private enum Key {
        static let notAfter = "cnsa2.enrollment.notAfter"   // before the expiry moved to the keychain
        static let deviceID = "cnsa2.enrollment.deviceID"
        static let gateway = "cnsa2.enrollment.gateway"
        static let root = "cnsa2.enrollment.root"
    }

    /// The certificate's expiry. Kept in the keychain so the tunnel extension sees it too.
    private var expiry: Date? {
        if let date = CNSA2Identity.certificateExpiry { return date }
        // A device enrolled before the expiry moved: carry it over once.
        let t = defaults.double(forKey: Key.notAfter)
        guard t > 0 else { return nil }
        let date = Date(timeIntervalSince1970: t)
        try? CNSA2Identity.setCertificateExpiry(date)
        return date
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

    /// The saved root, base64, if it is still the pinned Lattice root.
    private var savedRoot: String? {
        guard let b64 = defaults.string(forKey: Key.root),
              let der = Data(base64Encoded: b64), CNSA2Renewal.isLatticeRoot(der) else { return nil }
        return b64
    }

    /// True when the device cannot connect without enrolling first.
    func needsEnrollment(now: Date = Date()) -> Bool {
        guard CNSA2Identity.isEnrolled, gateway != nil, savedRoot != nil, let expiry else { return true }
        return now >= expiry
    }

    /// Enrolls if needed and returns the provider configuration for the tunnel.
    func configuration(accountNumber: String) async throws -> [String: Any] {
        if needsEnrollment() { try await enroll(accountNumber: accountNumber) }
        guard let gateway, let root = savedRoot else {
            throw CNSA2Renewal.Failure(status: 0, message: "No CNSA 2.0 gateway is available yet.")
        }
        return ["host": gateway.host, "port": gateway.port, "gatewayID": gateway.name,
                "caDER": root, "rekeySeconds": Self.rekeySeconds]
    }

    /// Renews if the certificate is in its last 10 days. Returns true if a new one was stored.
    @discardableResult
    func renewIfDue(accountNumber: String) async throws -> Bool {
        _ = expiry   // carries an old expiry over to the keychain if needed
        guard CNSA2Renewal.renewalDue() else { return false }
        try await enroll(accountNumber: accountNumber)
        return true
    }

    /// Enrolls, or renews with the existing key.
    func enroll(accountNumber: String) async throws {
        let reply = try await CNSA2Renewal.issue(accountNumber: accountNumber)
        defaults.set(reply.root.base64EncodedString(), forKey: Key.root)
        defaults.set(NSNumber(value: reply.deviceID), forKey: Key.deviceID)
        if let gateway = reply.gateways.first {
            defaults.set(["id": gateway.id, "host": gateway.host, "port": gateway.port, "name": gateway.name],
                         forKey: Key.gateway)
        }
    }
}
