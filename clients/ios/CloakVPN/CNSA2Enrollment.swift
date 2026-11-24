import Foundation

/// App side of CNSA 2.0 enrollment: enrolls the device the first time the mode is
/// used, keeps the list of gateways the server offers, and picks the one for the
/// region the user chose. The request, the checks on the reply and the renewal rule
/// live in `CNSA2Renewal`, which the tunnel extension shares. An actor, so two
/// enrollments from the app cannot overlap.
actor CNSA2Enroller {
    static let shared = CNSA2Enroller()

    static let rekeySeconds = 600

    private let defaults = UserDefaults.standard
    private enum Key {
        static let notAfter = "cnsa2.enrollment.notAfter"   // before the expiry moved to the keychain
        static let deviceID = "cnsa2.enrollment.deviceID"
        static let gateway = "cnsa2.enrollment.gateway"     // before gateway choice: the single gateway
        static let gateways = "cnsa2.enrollment.gateways"
        static let root = "cnsa2.enrollment.root"
    }
    /// Read by the UI without going through the actor: the region id of the gateway in use.
    static let currentGatewayKey = "cnsa2.gateway.current"

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

    private static func gateway(from d: [String: Any]) -> CNSA2Gateway? {
        guard let id = d["id"] as? String, let host = d["host"] as? String,
              let port = d["port"] as? Int, let name = d["name"] as? String else { return nil }
        return CNSA2Gateway(id: id, host: host, port: port, name: name)
    }

    /// The gateways the server offered last time it was asked.
    var gateways: [CNSA2Gateway] {
        if let list = defaults.array(forKey: Key.gateways) as? [[String: Any]] {
            let parsed = list.compactMap(Self.gateway(from:))
            if !parsed.isEmpty { return parsed }
        }
        return defaults.dictionary(forKey: Key.gateway).flatMap(Self.gateway(from:)).map { [$0] } ?? []
    }

    private func save(_ list: [CNSA2Gateway]) {
        guard !list.isEmpty else { return }
        defaults.set(list.map { ["id": $0.id, "host": $0.host, "port": $0.port, "name": $0.name] as [String: Any] },
                     forKey: Key.gateways)
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
        guard CNSA2Identity.isEnrolled, !gateways.isEmpty, savedRoot != nil, let expiry else { return true }
        return now >= expiry
    }

    /// Picks the gateway for a region. With no region chosen, the first one offered.
    /// There is no silent substitute: a region without a gateway is an error the user sees.
    static func choose(_ gateways: [CNSA2Gateway], regionID: String?) -> CNSA2Gateway? {
        guard let regionID else { return gateways.first }
        return gateways.first { $0.id == regionID }
    }

    /// Enrolls if needed, refreshes the gateway list, and returns the provider
    /// configuration for the tunnel to the gateway of `regionID`.
    func configuration(accountNumber: String, regionID: String?) async throws -> [String: Any] {
        if needsEnrollment() {
            try await enroll(accountNumber: accountNumber)
        } else if let fresh = try? await CNSA2Renewal.fetchGateways(accountNumber: accountNumber) {
            save(fresh)   // best effort: a failed refresh keeps the saved list
        }
        guard let root = savedRoot else {
            throw CNSA2Renewal.Failure(status: 0, message: "This device is not enrolled.")
        }
        let offered = gateways
        guard let gateway = Self.choose(offered, regionID: regionID) else {
            let where_ = offered.map(\.id).joined(separator: ", ")
            throw CNSA2Renewal.Failure(status: 0, message: offered.isEmpty
                ? "No CNSA 2.0 gateway is available yet."
                : "CNSA 2.0 mode is not available in that region yet. Available: \(where_).")
        }
        defaults.set(gateway.id, forKey: Self.currentGatewayKey)
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
        save(reply.gateways)
    }
}
