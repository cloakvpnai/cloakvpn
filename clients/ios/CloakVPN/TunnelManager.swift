import Combine
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

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        // Forward derived PSKs into the NE.
        rosenpass.onPSKDerived = { [weak self] psk in
            self?.pushPresharedKey(psk)
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
    /// Splits the parsed CloakConfig in two:
    ///   - WG fields + small PQ flags → `providerConfiguration` (small,
    ///     persisted by iOS, readable by both processes).
    ///   - Three Rosenpass key blobs (~1.4 MB combined) → App Group
    ///     container via `AppGroupKeyStore`. The NE never reads these;
    ///     they're for `RosenpassBridge` in the main app.
    ///
    /// If writing the keys to the App Group container fails, we abort the
    /// whole import — saving an `NETunnelProviderManager` without the keys
    /// would put the user in a state where Connect appears to work but
    /// PQC silently never engages. Failing loud is better.
    func importConfig(_ text: String) throws {
        let parsed = try ConfigParser.parse(text)

        // Stash the big Rosenpass blobs FIRST. If this fails, abort before
        // we touch the system VPN preferences — leaves the device in a
        // clean state.
        if parsed.pqEnabled {
            try AppGroupKeyStore.saveRosenpassKeys(
                serverPublicB64: parsed.serverRPPublicKeyB64,
                clientSecretB64: parsed.clientRPSecretKeyB64,
                clientPublicB64: parsed.clientRPPublicKeyB64
            )
        } else {
            // Re-importing a non-PQ config; clear any stale keys so a
            // future PQ config doesn't silently inherit them.
            AppGroupKeyStore.clear()
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
        // The three big Rosenpass keys aren't in `config` (which round-
        // trips through providerConfiguration) — they live in the App
        // Group container. Load them on demand here. If they're missing,
        // log it and skip rosenpass; the tunnel will still come up
        // classically (no PQ protection) so the user isn't stranded.
        guard let cfg = config, cfg.pqEnabled else { return }
        do {
            let keys = try AppGroupKeyStore.loadRosenpassKeys()
            rosenpass.start(
                clientSecretKeyB64: keys.clientSecretB64,
                clientPublicKeyB64: keys.clientPublicB64,
                serverPublicKeyB64: keys.serverPublicB64,
                serverEndpoint: cfg.rpEndpoint,
                rotationSeconds: cfg.pskRotationSeconds
            )
        } catch {
            print("connect: PQC keys unavailable, skipping rosenpass loop: \(error.localizedDescription)")
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
}

// `TunnelError` lives in ConfigParser.swift so the NetworkExtension
// target (which compiles ConfigParser.swift but NOT this file) can see
// it too. Don't redeclare it here.
