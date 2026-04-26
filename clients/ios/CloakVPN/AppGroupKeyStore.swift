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
        // Server's rosenpass public key (from the imported config block).
        case serverRPPublicKey = "rp_server_pubkey.b64"

        // -- Locally-generated device keypair --
        // Generated on first app launch via the FFI's generateStaticKeypair().
        // The secret never leaves the device — this is the privacy fix that
        // closes the hole where the server formerly held every client's
        // PQ private key. Stable identity for this iPhone install; survives
        // re-imports of new server configs.
        case localRPSecretKey = "rp_local_seckey.b64"
        case localRPPublicKey = "rp_local_pubkey.b64"

        // -- LEGACY: server-generated client keys (DEPRECATED) --
        // These were the old privacy-broken design where add-peer.sh on
        // the server ran rosenpass gen-keys and shipped both halves in
        // the config. Still present to clean up on migration; no new
        // code path writes to them. Will be removed once we're confident
        // every install has migrated to the local keypair design.
        case clientRPSecretKey = "rp_client_seckey.b64"  // legacy
        case clientRPPublicKey = "rp_client_pubkey.b64"  // legacy
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

    // MARK: - Public API — Local device keypair (the privacy-fix)
    //
    // The new design: the device generates its own rosenpass keypair on
    // first launch via the FFI's generateStaticKeypair(). The server only
    // ever sees the public key (registered out-of-band by the user pasting
    // it into add-peer.sh). The secret never leaves the device.
    //
    // Storage layout: rp_local_seckey.b64 + rp_local_pubkey.b64 in the
    // App Group container, both with .completeUntilFirstUserAuthentication
    // file protection.

    /// Persist a freshly-generated rosenpass keypair as this device's
    /// long-term PQC identity. Idempotent — overwrites any prior local
    /// keypair atomically. (Re-keying is intentional via clearLocalKeypair
    /// + saveLocalKeypair; don't use this to silently rotate.)
    static func saveLocalKeypair(secretB64: String, publicB64: String) throws {
        try writeAtomic(secretB64, to: .localRPSecretKey)
        try writeAtomic(publicB64, to: .localRPPublicKey)
    }

    /// Load this device's locally-generated rosenpass keypair. Throws if
    /// either file is missing — caller should treat that as "no local
    /// identity yet" and call saveLocalKeypair after generateStaticKeypair.
    static func loadLocalKeypair() throws -> (secretB64: String, publicB64: String) {
        let secret = try read(.localRPSecretKey)
        let pubkey = try read(.localRPPublicKey)
        return (secret, pubkey)
    }

    /// True if this device has already generated and persisted a local
    /// keypair. Cheap — uses fileExists, no decoding.
    static func hasLocalKeypair() -> Bool {
        guard let dir = containerURL else { return false }
        let fm = FileManager.default
        return [Filename.localRPSecretKey, .localRPPublicKey]
            .allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0.rawValue).path) }
    }

    /// Wipe the local keypair. Use sparingly — this destroys the device's
    /// long-term PQC identity; the next handshake will need a re-issued
    /// peer registration on the server. Useful for "forget this device"
    /// flows or re-keying.
    static func clearLocalKeypair() {
        guard let dir = containerURL else { return }
        let fm = FileManager.default
        for f in [Filename.localRPSecretKey, .localRPPublicKey] {
            try? fm.removeItem(at: dir.appendingPathComponent(f.rawValue))
        }
    }

    // MARK: - Public API — Server pubkey (from imported config)

    /// Persist just the server's rosenpass public key, parsed from an
    /// imported config block. Replaces any prior server-pubkey on disk.
    static func saveServerPublicKey(_ b64: String) throws {
        try writeAtomic(b64, to: .serverRPPublicKey)
    }

    /// Load the server's rosenpass public key.
    static func loadServerPublicKey() throws -> String {
        try read(.serverRPPublicKey)
    }

    /// True if a server pubkey has been imported.
    static func hasServerPublicKey() -> Bool {
        guard let dir = containerURL else { return false }
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(Filename.serverRPPublicKey.rawValue).path
        )
    }

    /// Wipe the server pubkey only. Useful when re-importing a config
    /// for a different region.
    static func clearServerPublicKey() {
        guard let dir = containerURL else { return }
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent(Filename.serverRPPublicKey.rawValue)
        )
    }

    // MARK: - Public API — Legacy monolithic accessors (DEPRECATED)
    //
    // These were the original (privacy-broken) design where the server
    // generated client keys and shipped them in the config. New code
    // should use saveLocalKeypair / saveServerPublicKey instead.
    // Kept temporarily so existing call sites compile during the
    // refactor; they'll be deleted once nothing references them.

    /// Persist the three Rosenpass key blobs. Idempotent — overwrites any
    /// existing files atomically.
    @available(*, deprecated, message: "Server-generated client keys break PQC privacy. Use saveLocalKeypair (device-generated) and saveServerPublicKey separately.")
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
    @available(*, deprecated, message: "Use loadLocalKeypair() + loadServerPublicKey() instead.")
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
    @available(*, deprecated, message: "Use hasLocalKeypair() + hasServerPublicKey() instead.")
    static func hasRosenpassKeys() -> Bool {
        guard let dir = containerURL else { return false }
        let fm = FileManager.default
        return [Filename.serverRPPublicKey, .clientRPSecretKey, .clientRPPublicKey]
            .allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0.rawValue).path) }
    }

    /// Wipe ALL stored keys, including local keypair, server pubkey,
    /// and any legacy server-shipped client keys. Best-effort.
    static func clear() {
        guard let dir = containerURL else { return }
        let fm = FileManager.default
        let allFiles: [Filename] = [
            .serverRPPublicKey,
            .localRPSecretKey, .localRPPublicKey,
            .clientRPSecretKey, .clientRPPublicKey,
        ]
        for f in allFiles {
            try? fm.removeItem(at: dir.appendingPathComponent(f.rawValue))
        }
    }

    /// Migrate any legacy server-generated client keys off disk. Safe to
    /// call on every launch — no-op if the legacy files don't exist.
    /// Removes them so they can't be accidentally consumed by a stale
    /// code path; doesn't touch the local keypair or server pubkey.
    static func deleteLegacyClientKeys() {
        guard let dir = containerURL else { return }
        let fm = FileManager.default
        for f in [Filename.clientRPSecretKey, .clientRPPublicKey] {
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
