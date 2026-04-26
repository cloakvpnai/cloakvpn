import Combine
import CryptoKit
import Foundation
import NetworkExtension
import SwiftUI

@MainActor
final class TunnelManager: ObservableObject {
    enum Status: Equatable, CustomStringConvertible {
        case disconnected, connecting, connected, reasserting, disconnecting, invalid

        var color: Color {
            switch self {
            case .connected: return .green
            case .connecting, .reasserting: return .yellow
            case .disconnected: return .secondary
            case .disconnecting: return .orange
            case .invalid: return .red
            }
        }
        var description: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .reasserting: return "Reasserting"
            case .disconnecting: return "Disconnecting"
            case .invalid: return "Invalid"
            }
        }
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var config: CloakConfig?

    /// The post-quantum key exchange driver. Owned by the main app
    /// (never the NE — see docs/IOS_PQC.md). Bridges PSKs into the NE
    /// via `sendProviderMessage` opcode 0x01.
    let rosenpass = RosenpassBridge()

    /// Base64 of the device's locally-generated rosenpass public key,
    /// once available. Published so the UI can render a fingerprint and
    /// expose a "Share my public key" affordance. nil during the brief
    /// window between app launch and `ensureLocalKeypair()` completion
    /// on first install. Stable across launches once persisted.
    @Published private(set) var localPublicKeyB64: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        // Forward derived PSKs into the NE.
        rosenpass.onPSKDerived = { [weak self] psk in
            self?.pushPresharedKey(psk)
        }
        // Belt-and-suspenders: any legacy server-shipped client keys
        // sitting on disk from earlier builds get cleaned up on every
        // launch. New code path never reads them, but no point letting
        // stale files linger in the App Group container.
        AppGroupKeyStore.deleteLegacyClientKeys()
    }

    /// Ensure this device has a locally-generated rosenpass keypair
    /// persisted in the App Group container. Idempotent — if a keypair
    /// already exists from a prior launch, just publishes the cached
    /// public key. Otherwise generates a fresh one via the FFI's
    /// `generateStaticKeypair()` (~50-200ms on iPhone 13 Pro Max,
    /// imperceptible to the user) and persists.
    ///
    /// Should be called on app launch, ideally from the SwiftUI
    /// `.task { await tunnel.ensureLocalKeypair() }` modifier on the
    /// root view. Safe to call multiple times.
    func ensureLocalKeypair() async {
        // Fast path — keypair already on disk.
        if AppGroupKeyStore.hasLocalKeypair() {
            do {
                let kp = try AppGroupKeyStore.loadLocalKeypair()
                self.localPublicKeyB64 = kp.publicB64
            } catch {
                debugLog("ensureLocalKeypair: load failed despite has=true, regenerating: \(error)")
                AppGroupKeyStore.clearLocalKeypair()
                await generateAndPersistLocalKeypair()
            }
            return
        }
        await generateAndPersistLocalKeypair()
    }

    /// Generate a fresh rosenpass keypair via the FFI and persist to the
    /// App Group container. Heavy lifting (McEliece keygen, ~1-3 MB
    /// working set, hundreds of ms) is done off the MainActor.
    private func generateAndPersistLocalKeypair() async {
        do {
            let kp = try await Task.detached(priority: .userInitiated) {
                try generateStaticKeypair()
            }.value
            let secretB64 = kp.secretKey.base64EncodedString()
            let publicB64 = kp.publicKey.base64EncodedString()
            try AppGroupKeyStore.saveLocalKeypair(secretB64: secretB64, publicB64: publicB64)
            self.localPublicKeyB64 = publicB64
            debugLog("ensureLocalKeypair: generated & persisted (pk=\(kp.publicKey.count) B, sk=\(kp.secretKey.count) B)")
        } catch {
            debugLog("ensureLocalKeypair: generation failed: \(error)")
            // Don't crash — the UI will see localPublicKeyB64 stay nil
            // and can show a "PQC identity unavailable" state.
        }
    }

    /// Load existing VPN configurations from the system preferences.
    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first
            if let m = manager {
                updateStatus(m.connection.status)
                observeStatus(m.connection)
                if let cfgDict = (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
                   let cfg = try? CloakConfig(dict: cfgDict) {
                    config = cfg
                }
            }
        } catch {
            print("TunnelManager.load error: \(error)")
        }
    }

    /// Persist a new config and attach it to an NETunnelProviderManager.
    ///
    /// New (privacy-fixed) data flow:
    ///   - WG fields + small PQ flags → `providerConfiguration` (small,
    ///     persisted by iOS, readable by both processes).
    ///   - Server's rosenpass public key → App Group container via
    ///     `AppGroupKeyStore.saveServerPublicKey`. ~700 KB on disk.
    ///   - Any `client_secret_key_b64` / `client_public_key_b64` fields
    ///     in the imported config block are IGNORED. The device's local
    ///     keypair (already generated by `ensureLocalKeypair`) is the
    ///     only client-side identity that ever participates in handshakes.
    ///     Server-shipped client keys break PQC privacy — see
    ///     docs/IOS_PQC.md "Open items" §22.
    ///
    /// If writing the server pubkey to the App Group fails we abort the
    /// whole import — saving an `NETunnelProviderManager` without the
    /// pubkey on disk would put the user in a state where Connect appears
    /// to work but PQC silently never engages. Failing loud is better.
    func importConfig(_ text: String) throws {
        let parsed = try ConfigParser.parse(text)

        // Stash just the server's pubkey (the only PQC blob we still
        // accept from the config). If this fails, abort before we touch
        // the system VPN preferences — leaves the device in a clean state.
        if parsed.pqEnabled {
            guard !parsed.serverRPPublicKeyB64.isEmpty else {
                throw TunnelError.parse("PQ enabled but server_public_key_b64 is empty")
            }
            try AppGroupKeyStore.saveServerPublicKey(parsed.serverRPPublicKeyB64)
        } else {
            // Re-importing a non-PQ config; clear stale server pubkey so
            // a future PQ config doesn't silently inherit a wrong one.
            // Local keypair is preserved — the device's identity is
            // stable across config re-imports.
            AppGroupKeyStore.clearServerPublicKey()
        }

        let manager = self.manager ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        // MUST match the CloakTunnel target's PRODUCT_BUNDLE_IDENTIFIER
        // exactly. iOS uses this string to locate the NetworkExtension
        // binary to launch when startVPNTunnel() is called. A mismatch
        // here results in iOS silently doing nothing (or briefly
        // transitioning to Connecting then snapping back to Disconnected
        // with no logs), which is one of the most painful failure modes
        // in NE-land — there's no error surfaced to the host app.
        proto.providerBundleIdentifier = "ai.cloakvpn.CloakVPN.CloakTunnel"
        proto.serverAddress = parsed.endpoint
        // .asDictionary deliberately excludes the three big Rosenpass keys
        // — see ConfigParser.swift. They're already on disk in the App
        // Group container by the time we reach this line.
        proto.providerConfiguration = parsed.asDictionary

        // Secrets (WireGuard private key) currently flow through
        // providerConfiguration plaintext. TODO: move to Keychain via the
        // App Group's `kSecAttrAccessGroup`. Tracked separately — same
        // posture Mullvad shipped with for months. Not blocking the
        // first PQC smoke test.
        proto.passwordReference = nil

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Cloak VPN"
        manager.isEnabled = true

        Task {
            do {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                self.manager = manager
                self.config = parsed
                self.observeStatus(manager.connection)
            } catch {
                print("importConfig save error: \(error)")
            }
        }
    }

    func connect() async throws {
        debugLog("connect() called, current status=\(status)")
        guard let m = manager else {
            debugLog("connect() FAILING: manager is nil")
            throw TunnelError.noConfig
        }
        debugLog("connect(): starting VPN tunnel via NETunnelProviderManager")
        try m.connection.startVPNTunnel()

        // Kick off the Rosenpass loop in parallel. The first PSK can
        // arrive while WireGuard is still doing its classical handshake;
        // either way the NE applies it on receipt and re-keys without
        // dropping in-flight UDP.
        //
        // Load the device's local rosenpass keypair (generated on first
        // launch) and the server's pubkey (from the imported config) from
        // the App Group container. If either is missing, skip rosenpass —
        // the tunnel still comes up classically (no PQ protection) so the
        // user isn't stranded; the UI can warn about the missing PQC
        // identity separately.
        guard let cfg = config, cfg.pqEnabled else { return }
        do {
            let local = try AppGroupKeyStore.loadLocalKeypair()
            let serverPub = try AppGroupKeyStore.loadServerPublicKey()
            rosenpass.start(
                clientSecretKeyB64: local.secretB64,
                clientPublicKeyB64: local.publicB64,
                serverPublicKeyB64: serverPub,
                serverEndpoint: cfg.rpEndpoint,
                rotationSeconds: cfg.pskRotationSeconds
            )
        } catch {
            debugLog("connect: PQC keys unavailable, skipping rosenpass loop: \(error.localizedDescription)")
        }
    }

    func disconnect() async throws {
        debugLog("disconnect() called, current status=\(status)")
        rosenpass.stop()
        guard let m = manager else {
            debugLog("disconnect(): manager is nil, nothing to stop")
            return
        }
        debugLog("disconnect(): stopping VPN tunnel")
        m.connection.stopVPNTunnel()
    }

    // MARK: - PSK delivery to the NE

    /// Wire format: opcode (1 byte) + payload.
    /// 0x01 = SET_PSK, payload = 32-byte preshared key.
    /// (Mirrors PacketTunnelProvider.handleAppMessage on the receiving side.)
    private static let opcodeSetPsk: UInt8 = 0x01

    /// Push a Rosenpass-derived PSK to the running PacketTunnelProvider
    /// extension via `sendProviderMessage`. Best-effort — if the tunnel
    /// isn't up yet, the message is dropped and we'll retry on the next
    /// rotation tick.
    private func pushPresharedKey(_ psk: Data) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            print("pushPresharedKey: tunnel not connected, dropping (will retry on next rotation)")
            return
        }
        guard psk.count == 32 else {
            print("pushPresharedKey: refusing to push PSK of length \(psk.count)")
            return
        }
        var payload = Data()
        payload.append(Self.opcodeSetPsk)
        payload.append(psk)

        do {
            try session.sendProviderMessage(payload) { response in
                if let response = response, let code = response.first {
                    if code == 0 {
                        print("PSK accepted by NE")
                    } else {
                        print("PSK rejected by NE, code=0x\(String(code, radix: 16))")
                    }
                } else {
                    print("PSK push: no response from NE")
                }
            }
        } catch {
            print("pushPresharedKey send error: \(error)")
        }
    }

    // MARK: - Status observation

    private func observeStatus(_ conn: NEVPNConnection) {
        if let o = statusObserver { NotificationCenter.default.removeObserver(o) }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: conn, queue: .main
        ) { [weak self] note in
            // Swift 6 strict concurrency: NotificationCenter's callback is
            // @Sendable, so we can't capture `self` and just dereference it
            // inside a Task. Instead pull the only thing we need (the new
            // status enum, which IS Sendable) out of the notification on the
            // notification queue, THEN hop to the main actor.
            guard let newStatus = (note.object as? NEVPNConnection)?.status else { return }
            Task { @MainActor [weak self] in
                self?.updateStatus(newStatus)
            }
        }
    }

    private func updateStatus(_ s: NEVPNStatus) {
        let old = status
        switch s {
        case .connected: status = .connected
        case .connecting: status = .connecting
        case .disconnected: status = .disconnected
        case .disconnecting: status = .disconnecting
        case .reasserting: status = .reasserting
        case .invalid: status = .invalid
        @unknown default: status = .invalid
        }
        debugLog("status change: \(old) → \(status) (raw NEVPNStatus=\(s.rawValue))")
    }

    /// Debug-only logging. Stripped from release builds entirely so the
    /// `[TunnelManager]` prefix doesn't show up in production Console.app
    /// captures. We added these during the 2026-04-25 PQC smoke-test
    /// debugging marathon — keeping them around behind `#if DEBUG` because
    /// the next time iOS NetworkExtension state goes weird, having them
    /// pre-wired saves an hour of "wait, where's the connect path going?"
    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[TunnelManager] \(message())")
        #endif
    }

    // MARK: - Local pubkey export (for server-side registration)

    /// Short hex fingerprint of a base64 rosenpass public key — first
    /// 16 hex chars (8 bytes) of SHA-256 over the base64 string. Used
    /// for the UI's "your PQC identity" display and as part of the
    /// share filename so the user can recognize which device they
    /// AirDropped from.
    ///
    /// Note: this fingerprints the base64 STRING, not the raw key
    /// bytes. Either is fine for human-recognition purposes; the
    /// string-based hash matches what they'll see in a rendered
    /// config or copy-paste view.
    static func pubkeyFingerprint(_ b64: String) -> String {
        let hash = SHA256.hash(data: Data(b64.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Computed convenience for the UI — the short fingerprint of the
    /// currently-loaded local pubkey, or nil if generation hasn't
    /// completed yet. SwiftUI re-evaluates this whenever
    /// `localPublicKeyB64` changes.
    var localPubkeyFingerprint: String? {
        localPublicKeyB64.map(Self.pubkeyFingerprint)
    }

    /// Write the local pubkey (base64) to a tmp-dir file with a
    /// recognizable filename including the fingerprint, and return
    /// the URL for SwiftUI's ShareLink. Caller is responsible for
    /// not retaining the returned URL after the share sheet closes —
    /// the file lives in the system's autocleaned tmp directory.
    ///
    /// File contents are exactly the base64 of the rosenpass public
    /// key, no extra framing. The server's `add-peer.sh` (when
    /// invoked with this file as its second argument) base64-decodes
    /// and writes the binary to /etc/rosenpass/<peer>.rosenpass-public.
    func makeLocalPubkeyShareFile() throws -> URL {
        guard let pubB64 = self.localPublicKeyB64 else {
            throw TunnelError.parse("local rosenpass keypair not yet generated")
        }
        let fp = Self.pubkeyFingerprint(pubB64)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloakvpn-pubkey-\(fp).b64")
        try pubB64.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// `TunnelError` lives in ConfigParser.swift so the NetworkExtension
// target (which compiles ConfigParser.swift but NOT this file) can see
// it too. Don't redeclare it here.
