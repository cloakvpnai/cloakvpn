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

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

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
    }

    func disconnect() async throws {
        guard let m = manager else { return }
        m.connection.stopVPNTunnel()
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
