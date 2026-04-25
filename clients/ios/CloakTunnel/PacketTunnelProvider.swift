import Foundation
import NetworkExtension
import os.log
import WireGuardKit

/// The Network Extension entrypoint. iOS instantiates this when the user
/// flips the connect toggle (or when the system auto-connects on demand).
///
/// Responsibilities:
///   - Parse our CloakConfig out of the providerConfiguration dictionary
///     (populated by the main app via TunnelManager.importConfig).
///   - Build a wg-quick-style tunnel configuration from that.
///   - Hand it to `WireGuardAdapter`, which owns the wireguard-go data
///     path and the tun interface.
///   - Honor PSK updates pushed from the main app via `handleAppMessage`
///     (this is how Rosenpass-derived post-quantum PSKs reach us — see
///     docs/IOS_PQC.md for the full story).
///
/// What this file deliberately does NOT do:
///   - Run rosenpass crypto inside the NE. Memory budget is too tight in
///     the worst case (50 MiB jetsam cap). Rosenpass runs in the main app;
///     see RosenpassBridge.swift.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "ai.cloakvpn.CloakVPN.tunnel", category: "tunnel")

    /// The WireGuardKit adapter. nil before startTunnel, non-nil after.
    private var adapter: WireGuardAdapter?

    /// The active tunnel config. We keep a copy so PSK rotation can build
    /// a new TunnelConfiguration with the same peer + interface settings
    /// but a fresh preshared key.
    private var currentConfig: TunnelConfiguration?

    // MARK: - Lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("startTunnel", log: log, type: .info)

        // 1. Pull our serialized CloakConfig out of providerConfiguration.
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let dict = proto.providerConfiguration
        else {
            os_log("startTunnel: missing providerConfiguration", log: log, type: .error)
            completionHandler(PacketTunnelError.missingProtocol)
            return
        }

        let cloakCfg: CloakConfig
        do {
            cloakCfg = try CloakConfig(dict: dict)
        } catch {
            os_log("startTunnel: bad CloakConfig: %{public}s",
                   log: log, type: .error, String(describing: error))
            completionHandler(error)
            return
        }

        // 2. Build a WireGuardKit TunnelConfiguration directly from
        //    CloakConfig fields. Mullvad's wireguard-apple fork exposes
        //    only `WireGuardKit` and `WireGuardKitTypes` as public
        //    products — the wg-quick parser lives in their internal
        //    `Shared` module, not reachable from here. So we wire each
        //    field through manually. (Side benefit: tighter error
        //    messages than the parser would give.)
        let tunnelCfg: TunnelConfiguration
        do {
            tunnelCfg = try Self.makeTunnelConfiguration(from: cloakCfg)
        } catch {
            os_log("startTunnel: TunnelConfiguration build failed: %{public}s",
                   log: log, type: .error, String(describing: error))
            completionHandler(error)
            return
        }

        // 3. Build the adapter. The closure is the wireguard-go log sink.
        let adapter = WireGuardAdapter(with: self) { [weak self] _, message in
            // wireguard-go logs are noisy; log at debug. NSLog works inside
            // the NE without an OSLog import; this also surfaces in
            // Console.app filtered by process name "CloakTunnel".
            os_log("wg: %{public}s", log: self?.log ?? .default, type: .debug, message)
        }
        self.adapter = adapter
        self.currentConfig = tunnelCfg

        // 4. Start the tunnel. WireGuardKit handles setTunnelNetworkSettings
        //    internally based on the InterfaceConfiguration we passed in
        //    — we don't need to build NEPacketTunnelNetworkSettings ourselves.
        adapter.start(tunnelConfiguration: tunnelCfg) { adapterError in
            if let adapterError = adapterError {
                os_log("WireGuardAdapter.start failed: %{public}s",
                       log: self.log, type: .error, String(describing: adapterError))
                completionHandler(adapterError)
                return
            }
            os_log("tunnel up", log: self.log, type: .info)
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        os_log("stopTunnel reason=%d", log: log, type: .info, reason.rawValue)
        guard let adapter = adapter else {
            completionHandler()
            return
        }
        adapter.stop { error in
            if let error = error {
                os_log("adapter.stop error: %{public}s",
                       log: self.log, type: .error, String(describing: error))
            }
            self.adapter = nil
            self.currentConfig = nil
            completionHandler()
        }
    }

    // MARK: - PSK rotation (called from the main app via sendProviderMessage)

    /// Receives messages from the main app process.
    ///
    /// Wire format (kept dumb on purpose so it survives across OS versions):
    ///
    ///   First byte = opcode:
    ///     0x01 = "set preshared key": the next 32 bytes are the new PSK.
    ///
    /// Anything else is logged and dropped. We respond with a single byte:
    /// 0 = ok, non-zero = error code.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard let opcode = messageData.first else {
            os_log("handleAppMessage: empty payload", log: log, type: .error)
            completionHandler?(Data([0xFF]))
            return
        }

        switch opcode {
        case 0x01: // SET_PSK
            let psk = messageData.dropFirst()
            guard psk.count == 32 else {
                os_log("SET_PSK: wrong PSK length %d (want 32)",
                       log: log, type: .error, psk.count)
                completionHandler?(Data([0xFE]))
                return
            }
            applyPresharedKey(Data(psk)) { ok in
                completionHandler?(Data([ok ? 0x00 : 0xFD]))
            }

        default:
            os_log("handleAppMessage: unknown opcode 0x%02x",
                   log: log, type: .error, opcode)
            completionHandler?(Data([0xFC]))
        }
    }

    /// Apply a Rosenpass-derived PSK by rebuilding the tunnel config with
    /// the new preshared key on the (single) peer and asking WireGuardKit
    /// to swap it in. WireGuardKit reuses the underlying tun and only
    /// reconfigures the wireguard-go session, so this is cheap (~ms) and
    /// doesn't drop in-flight UDP.
    private func applyPresharedKey(
        _ psk: Data,
        completion: @escaping (Bool) -> Void
    ) {
        guard let current = currentConfig else {
            os_log("applyPresharedKey: no current config", log: log, type: .error)
            completion(false)
            return
        }
        guard let adapter = adapter else {
            os_log("applyPresharedKey: no adapter", log: log, type: .error)
            completion(false)
            return
        }

        var peers = current.peers
        guard !peers.isEmpty else {
            os_log("applyPresharedKey: no peers", log: log, type: .error)
            completion(false)
            return
        }
        peers[0].preSharedKey = PreSharedKey(rawValue: psk)

        let updated = TunnelConfiguration(
            name: current.name,
            interface: current.interface,
            peers: peers
        )

        adapter.update(tunnelConfiguration: updated) { [weak self] error in
            if let error = error {
                os_log("applyPresharedKey adapter.update failed: %{public}s",
                       log: self?.log ?? .default, type: .error, String(describing: error))
                completion(false)
                return
            }
            self?.currentConfig = updated
            os_log("PSK rotated", log: self?.log ?? .default, type: .info)
            completion(true)
        }
    }
}

enum PacketTunnelError: Error, LocalizedError {
    case missingProtocol
    case badField(String, String) // (fieldName, value)

    var errorDescription: String? {
        switch self {
        case .missingProtocol:
            return "Missing or malformed VPN protocolConfiguration."
        case let .badField(name, value):
            return "Invalid \(name) in tunnel config: \(value.prefix(40))…"
        }
    }
}

// MARK: - CloakConfig → WireGuardKit TunnelConfiguration

extension PacketTunnelProvider {
    /// Translate our wire-format CloakConfig (raw base64 strings, "host:port"
    /// strings, "10.0.0.1/24" strings) into the strongly-typed
    /// WireGuardKit model that WireGuardAdapter can consume.
    ///
    /// Throws `PacketTunnelError.badField` on the first malformed input so
    /// the user sees a precise error rather than a wg-quick parser's
    /// cryptic message.
    static func makeTunnelConfiguration(from cfg: CloakConfig) throws -> TunnelConfiguration {
        // ---- Interface (the local end of the tunnel) ----
        guard let skBytes = Data(base64Encoded: cfg.wgPrivateKey),
              let privateKey = PrivateKey(rawValue: skBytes) else {
            throw PacketTunnelError.badField("wgPrivateKey", cfg.wgPrivateKey)
        }
        var iface = InterfaceConfiguration(privateKey: privateKey)

        // Interface addresses: typically one v4 + one v6 in CIDR form.
        guard let v4 = IPAddressRange(from: cfg.addressV4) else {
            throw PacketTunnelError.badField("addressV4", cfg.addressV4)
        }
        guard let v6 = IPAddressRange(from: cfg.addressV6) else {
            throw PacketTunnelError.badField("addressV6", cfg.addressV6)
        }
        iface.addresses = [v4, v6]

        // DNS — drop any malformed entries with a log, don't fail the whole tunnel.
        iface.dns = cfg.dns.compactMap { DNSServer(from: $0) }
        iface.mtu = 1420 // safe default for WireGuard over most transports

        // ---- Peer (the concentrator) ----
        guard let pkBytes = Data(base64Encoded: cfg.peerPublicKey),
              let publicKey = PublicKey(rawValue: pkBytes) else {
            throw PacketTunnelError.badField("peerPublicKey", cfg.peerPublicKey)
        }
        var peer = PeerConfiguration(publicKey: publicKey)

        // AllowedIPs — usually "0.0.0.0/0, ::/0" for full-tunnel.
        peer.allowedIPs = try cfg.allowedIPs.map { rangeStr in
            guard let range = IPAddressRange(from: rangeStr) else {
                throw PacketTunnelError.badField("allowedIPs", rangeStr)
            }
            return range
        }

        guard let endpoint = Endpoint(from: cfg.endpoint) else {
            throw PacketTunnelError.badField("endpoint", cfg.endpoint)
        }
        peer.endpoint = endpoint
        peer.persistentKeepAlive = UInt16(clamping: cfg.persistentKeepalive)
        // peer.preSharedKey is left nil; the Rosenpass-derived PSK will
        // be installed later via handleAppMessage → applyPresharedKey.

        return TunnelConfiguration(name: "Cloak", interface: iface, peers: [peer])
    }
}
