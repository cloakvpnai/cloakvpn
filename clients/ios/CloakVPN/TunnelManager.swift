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
    func importConfig(_ text: String) throws {
        let parsed = try ConfigParser.parse(text)
        let manager = self.manager ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.cloakvpn.app.tunnel"
        proto.serverAddress = parsed.endpoint
        proto.providerConfiguration = parsed.asDictionary

        // Secrets (WireGuard private key, Rosenpass secret) go to Keychain via app group.
        // Left as TODO — see RosenpassBridge.swift and KeychainHelper (not yet committed).
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
        guard let m = manager else { throw TunnelError.noConfig }
        try m.connection.startVPNTunnel()

        // Kick off the Rosenpass loop in parallel. The first PSK can
        // arrive while WireGuard is still doing its classical handshake;
        // either way the NE applies it on receipt and re-keys without
        // dropping in-flight UDP.
        if let cfg = config, cfg.pqEnabled {
            rosenpass.start(
                clientSecretKeyB64: cfg.clientRPSecretKeyB64,
                clientPublicKeyB64: cfg.clientRPPublicKeyB64,
                serverPublicKeyB64: cfg.serverRPPublicKeyB64,
                serverEndpoint: cfg.rpEndpoint,
                rotationSeconds: cfg.pskRotationSeconds
            )
        }
    }

    func disconnect() async throws {
        rosenpass.stop()
        guard let m = manager else { return }
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
        switch s {
        case .connected: status = .connected
        case .connecting: status = .connecting
        case .disconnected: status = .disconnected
        case .disconnecting: status = .disconnecting
        case .reasserting: status = .reasserting
        case .invalid: status = .invalid
        @unknown default: status = .invalid
        }
    }
}

// `TunnelError` lives in ConfigParser.swift so the NetworkExtension
// target (which compiles ConfigParser.swift but NOT this file) can see
// it too. Don't redeclare it here.
