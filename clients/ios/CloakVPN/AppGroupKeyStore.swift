import Foundation

/// Persists the three Rosenpass key blobs to the App Group container so
/// they're available to the main app across launches without bloating
/// `NETunnelProviderProtocol.providerConfiguration` (which has practical
/// size limits in the hundreds of KB; our McEliece-460896 public keys
/// alone are ~700 KB each base64-encoded).
///
/// The NE deliberately does NOT read this — Rosenpass runs in the main
/// app only and pushes 32-byte derived PSKs to the NE via
/// `sendProviderMessage`. See `docs/IOS_PQC.md` for the architecture
/// rationale.
///
/// Storage layout (inside the App Group container):
///   ./rp_server_pubkey.b64
///   ./rp_client_seckey.b64
///   ./rp_client_pubkey.b64
///
/// All three files use Data Protection class
/// `.completeUntilFirstUserAuthentication` — readable after first unlock
/// post-boot, encrypted at rest before that. Matches what the NE itself
/// needs (NEs run in the background long before the user touches the
/// device, so we can't use stricter classes).
enum AppGroupKeyStore {
    static let appGroupID = "group.ai.cloakvpn.CloakVPN"

    private enum Filename: String {
        case serverRPPublicKey = "rp_server_pubkey.b64"
        case clientRPSecretKey = "rp_client_seckey.b64"
        case clientRPPublicKey = "rp_client_pubkey.b64"
    }

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

    // MARK: - Public API

    /// Persist the three Rosenpass key blobs. Idempotent — overwrites any
    /// existing files atomically.
    static func saveRosenpassKeys(
        serverPublicB64: String,
        clientSecretB64: String,
        clientPublicB64: String
    ) throws {
        try writeAtomic(serverPublicB64, to: .serverRPPublicKey)
        try writeAtomic(clientSecretB64, to: .clientRPSecretKey)
        try writeAtomic(clientPublicB64, to: .clientRPPublicKey)
    }

    /// Load all three Rosenpass key blobs. Throws if any are missing.
    static func loadRosenpassKeys() throws
        -> (serverPublicB64: String, clientSecretB64: String, clientPublicB64: String)
    {
        let server = try read(.serverRPPublicKey)
        let secret = try read(.clientRPSecretKey)
        let client = try read(.clientRPPublicKey)
        return (server, secret, client)
    }

    /// True if all three key files are present. Cheap — uses `fileExists`,
    /// no decoding.
    static func hasRosenpassKeys() -> Bool {
        guard let dir = containerURL else { return false }
        let fm = FileManager.default
        return [Filename.serverRPPublicKey, .clientRPSecretKey, .clientRPPublicKey]
            .allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0.rawValue).path) }
    }

    /// Wipe all stored keys. Best-effort — silently ignores missing files.
    static func clear() {
        guard let dir = containerURL else { return }
        let fm = FileManager.default
        for f in [Filename.serverRPPublicKey, .clientRPSecretKey, .clientRPPublicKey] {
            try? fm.removeItem(at: dir.appendingPathComponent(f.rawValue))
        }
    }

    // MARK: - Internals

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static func url(for file: Filename) throws -> URL {
        guard let dir = containerURL else { throw StoreError.containerUnavailable }
        return dir.appendingPathComponent(file.rawValue)
    }

    private static func writeAtomic(_ s: String, to file: Filename) throws {
        let target = try url(for: file)
        guard let data = s.data(using: .utf8) else {
            throw StoreError.writeFailed(file.rawValue,
                                         underlying: CocoaError(.fileWriteInapplicableStringEncoding))
        }
        do {
            // .completeUntilFirstUserAuthentication: readable after first
            // unlock post-boot. NE process needs this class because it can
            // start before the user has unlocked since reboot (e.g. on-demand
            // VPN). Stricter classes would lock us out of the keys then.
            try data.write(to: target,
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw StoreError.writeFailed(file.rawValue, underlying: error)
        }
    }

    private static func read(_ file: Filename) throws -> String {
        let target = try url(for: file)
        do {
            let data = try Data(contentsOf: target)
            guard let s = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return s
        } catch {
            throw StoreError.readFailed(file.rawValue, underlying: error)
        }
    }
}
