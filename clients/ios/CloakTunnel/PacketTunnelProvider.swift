// SPDX-License-Identifier: MIT
//
// Cloak VPN — PacketTunnelProvider for the CloakTunnel NetworkExtension
// target. This file is a STRUCTURAL CLONE of upstream wireguard-apple's
// reference PacketTunnelProvider.swift (commit master/2024+), with two
// additions:
//
//   (a) Custom config parsing — we read CloakConfig from
//       NETunnelProviderProtocol.providerConfiguration (our wire format,
//       not wg-quick) and build a TunnelConfiguration manually.
//
//   (b) `handleAppMessage` opcode 0x01 SET_PSK — the host app pushes a
//       freshly-derived rosenpass PSK via sendProviderMessage; we apply
//       it to the WG peer configuration via WireGuardAdapter.update().
//
// Critically, this file does NOT override `setTunnelNetworkSettings` —
// upstream doesn't either, and overriding it (even as a stub
// pass-through) was the cause of an 8-hour debugging marathon on
// 2026-04-26 evening where decrypted packets never reached iOS network
// stack despite handshakes completing.
//
// Earlier additions (Option D rosenpass UDP relay opcodes 0x02-0x04,
// the rosenpassServerIP property, the extractIP helper) are
// REMOVED here. They will be re-added carefully on top of this
// known-working base when we re-enable PQC. For now: plain WG, focus on
// proving traffic flows.

import Foundation
import NetworkExtension
import os.log
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "ai.cloakvpn.CloakVPN.tunnel", category: "tunnel")

    /// The WireGuardKit adapter. Lazily constructed so initialization
    /// happens on the same thread that drives startTunnel — matches
    /// upstream's pattern.
    private lazy var adapter: WireGuardAdapter = {
        return WireGuardAdapter(with: self) { [weak self] logLevel, message in
            os_log("wg: %{public}s",
                   log: self?.log ?? .default,
                   type: logLevel.osLogType,
                   message)
        }
    }()

    /// The active tunnel configuration. Kept so PSK rotations can build
    /// a new TunnelConfiguration with the same interface + peer settings
    /// but a fresh preshared key, then call adapter.update().
    private var currentConfig: TunnelConfiguration?

    // MARK: - Lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("startTunnel", log: log, type: .info)

        // Pull the serialized CloakConfig out of the NE's
        // providerConfiguration dictionary (populated by the host app's
        // TunnelManager.importConfig).
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

        // Build a WireGuardKit TunnelConfiguration directly from
        // CloakConfig fields. Mullvad's wireguard-apple fork exposes
        // only `WireGuardKit` and `WireGuardKitTypes` as public products
        // — the wg-quick parser lives in their internal `Shared`
        // module, not reachable from here. So we wire each field
        // through manually. See `makeTunnelConfiguration` below.
        let tunnelCfg: TunnelConfiguration
        do {
            tunnelCfg = try Self.makeTunnelConfiguration(from: cloakCfg)
        } catch {
            os_log("startTunnel: TunnelConfiguration build failed: %{public}s",
                   log: log, type: .error, String(describing: error))
            completionHandler(error)
            return
        }
        self.currentConfig = tunnelCfg

        // Hand off to WireGuardAdapter. WireGuardKit will:
        //   1. Tell iOS to set up utun via setTunnelNetworkSettings
        //   2. Wait for that to complete
        //   3. Call wgTurnOn to start the wireguard-go data plane
        //   4. Wire packetFlow ↔ wireguard-go's TUN reader/writer
        //
        // We do NOT override setTunnelNetworkSettings (upstream doesn't
        // either; intercepting it broke the data path on 2026-04-26).
        adapter.start(tunnelConfiguration: tunnelCfg) { [weak self] adapterError in
            guard let self = self else { return }
            if let adapterError = adapterError {
                os_log("WireGuardAdapter.start failed: %{public}s",
                       log: self.log, type: .error,
                       String(describing: adapterError))
                completionHandler(adapterError)
                return
            }
            let ifaceName = self.adapter.interfaceName ?? "unknown"
            os_log("tunnel up on interface %{public}s",
                   log: self.log, type: .info, ifaceName)
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        os_log("stopTunnel reason=%d", log: log, type: .info, reason.rawValue)
        adapter.stop { [weak self] error in
            if let error = error {
                os_log("adapter.stop error: %{public}s",
                       log: self?.log ?? .default, type: .error,
                       String(describing: error))
            }
            self?.currentConfig = nil
            completionHandler()
        }
    }

    // MARK: - PSK rotation (called from the main app via sendProviderMessage)

    /// Receives messages from the main app process.
    ///
    /// Wire format (kept dumb on purpose so it survives across OS
    /// versions and matches upstream's pattern of a single first-byte
    /// opcode):
    ///
    ///   First byte = opcode:
    ///     0x00 = "get runtime config" (upstream-compat; returns UAPI
    ///            config string for diagnostics)
    ///     0x01 = "set preshared key": the next 32 bytes are the new
    ///            PSK from rosenpass. Response is single byte: 0 = ok,
    ///            non-zero = error code.
    ///
    /// Anything else is logged and dropped.
    ///
    /// NOTE: opcodes 0x02-0x04 (the Option D rosenpass UDP relay we
    /// shipped on 2026-04-26) are temporarily removed here. They will
    /// be re-added on top of this known-working base when PQC is
    /// re-enabled. For now: plain WG.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard let completionHandler = completionHandler else { return }
        guard let opcode = messageData.first else {
            os_log("handleAppMessage: empty payload", log: log, type: .error)
            completionHandler(Data([0xFF]))
            return
        }

        switch opcode {
        case 0x00: // GET_RUNTIME_CONFIG (upstream-compat diagnostic path)
            adapter.getRuntimeConfiguration { settings in
                completionHandler(settings?.data(using: .utf8))
            }

        case 0x01: // SET_PSK
            let psk = messageData.dropFirst()
            guard psk.count == 32 else {
                os_log("SET_PSK: wrong PSK length %d (want 32)",
                       log: log, type: .error, psk.count)
                completionHandler(Data([0xFE]))
                return
            }
            applyPresharedKey(Data(psk)) { ok in
                completionHandler(Data([ok ? 0x00 : 0xFD]))
            }

        default:
            os_log("handleAppMessage: unknown opcode 0x%02x",
                   log: log, type: .error, opcode)
            completionHandler(Data([0xFC]))
        }
    }

    /// Apply a Rosenpass-derived PSK by rebuilding the tunnel config
    /// with the new preshared key on the (single) peer and asking
    /// WireGuardKit to swap it in. WireGuardKit reuses the underlying
    /// utun and only reconfigures the wireguard-go session, so this is
    /// cheap (~ms) and doesn't drop in-flight UDP.
    private func applyPresharedKey(
        _ psk: Data,
        completion: @escaping (Bool) -> Void
    ) {
        guard let current = currentConfig else {
            os_log("applyPresharedKey: no current config", log: log, type: .error)
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
                       log: self?.log ?? .default, type: .error,
                       String(describing: error))
                completion(false)
                return
            }
            self?.currentConfig = updated
            os_log("PSK rotated", log: self?.log ?? .default, type: .info)
            completion(true)
        }
    }
}

// MARK: - Errors

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

// MARK: - WireGuardLogLevel → OSLogType

private extension WireGuardLogLevel {
    var osLogType: OSLogType {
        switch self {
        case .verbose: return .debug
        case .error: return .error
        }
    }
}

// MARK: - CloakConfig → WireGuardKit TunnelConfiguration

extension PacketTunnelProvider {
    /// Translate our wire-format CloakConfig (raw base64 strings,
    /// "host:port" strings, "10.0.0.1/24" strings) into the
    /// strongly-typed WireGuardKit model that WireGuardAdapter can
    /// consume.
    ///
    /// Throws `PacketTunnelError.badField` on the first malformed input
    /// so the user sees a precise error rather than a wg-quick parser's
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

        // DNS — drop any malformed entries with a log, don't fail the
        // whole tunnel.
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
