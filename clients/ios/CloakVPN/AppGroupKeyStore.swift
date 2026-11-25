import Foundation

/// Small files the app and its tunnel extension share through the App Group container.
///
/// Today that is one thing: the customer's account number. The device's CNSA 2.0 key
/// lives in the keychain (see CNSA2Identity), not here.
///
/// Earlier versions of the app connected with WireGuard and kept its keys here, along
/// with Rosenpass keys and an older sign-in token. This version cannot use any of them,
/// so `eraseLegacyFiles()` removes them at every launch.
enum AppGroupKeyStore {
    static let appGroupID = "group.ai.cloakvpn.CloakVPN"

    private static let accountNumberFile = "account_number.txt"

    /// Files written by WireGuard-based versions of the app.
    private static let legacyFiles = [
        "rp_server_pubkey.b64",
        "rp_local_seckey.b64", "rp_local_pubkey.b64",
        "rp_client_seckey.b64", "rp_client_pubkey.b64",
        "wg_local_seckey.b64", "wg_local_pubkey.b64",
        "auth_jwt.json", "auth_install.uuid",
    ]

    enum StoreError: LocalizedError {
        case containerUnavailable
        case readFailed(String, underlying: Error)
        case writeFailed(String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .containerUnavailable:
                return "App Group container '\(AppGroupKeyStore.appGroupID)' is unavailable. Check entitlements."
            case let .readFailed(name, underlying):
                return "Read \(name) failed: \(underlying.localizedDescription)"
            case let .writeFailed(name, underlying):
                return "Write \(name) failed: \(underlying.localizedDescription)"
            }
        }
    }

    // MARK: - Account number (the customer's only credential)

    /// Persist the customer's account number (canonical hyphenated form).
    static func saveAccountNumber(_ number: String) throws {
        guard let dir = containerURL else { throw StoreError.containerUnavailable }
        guard let data = number.data(using: .utf8) else {
            throw StoreError.writeFailed(accountNumberFile, underlying: CocoaError(.fileWriteInapplicableStringEncoding))
        }
        do {
            // Readable after the first unlock since boot: the tunnel extension can start
            // before the user has unlocked again, and it needs the number to renew its
            // certificate.
            try data.write(to: dir.appendingPathComponent(accountNumberFile),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw StoreError.writeFailed(accountNumberFile, underlying: error)
        }
    }

    /// The stored account number, or nil if the customer has not signed in.
    static func loadAccountNumber() -> String? {
        guard let dir = containerURL,
              let data = try? Data(contentsOf: dir.appendingPathComponent(accountNumberFile)),
              let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Forget the account number, at sign-out.
    static func clearAccountNumber() {
        guard let dir = containerURL else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(accountNumberFile))
    }

    // MARK: - Cleanup after older versions

    /// Remove key and token files left by WireGuard-based versions of the app. Safe to
    /// call at every launch; it does nothing when they are already gone.
    static func eraseLegacyFiles() {
        guard let dir = containerURL else { return }
        for name in legacyFiles {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
}
