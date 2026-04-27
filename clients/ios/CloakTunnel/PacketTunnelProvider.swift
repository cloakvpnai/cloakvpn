// SPDX-License-Identifier: MIT
//
// Cloak VPN — PacketTunnelProvider for the CloakTunnel NetworkExtension
// target.
//
// 2026-04-27 ROOT-CAUSE FIX (see docs/TRIAGE_2026-04-27.md):
// Our SwiftPM dep is mullvad/wireguard-apple (mullvad-master). Mullvad's
// `WireGuardAdapter.start()` was rewritten to support multi-hop and DAITA
// and in the process REMOVED the `setTunnelNetworkSettings` call that
// upstream wireguard-apple makes in `start()`. Mullvad expects the host
// app to install network settings via a higher-level coordinator they
// don't ship publicly. Without that call, iOS never installs IPs / DNS /
// routes on the utun, so the wireguard-go data plane runs blind: WG
// handshake completes (UDP, doesn't traverse utun), keepalives flow
// (internal heartbeat), but no application traffic enters utun.
//
// This file compensates by calling `setTunnelNetworkSettings`
// EXPLICITLY before `adapter.start`. We can't switch to upstream
// wireguard-apple as a SwiftPM dep because upstream's Package.swift has
// been broken since 2023 (declares swift-tools-version:5.3 but uses
// .macOS(.v12)/.iOS(.v15) which require 5.5+).
//
// Layout of this file:
//   - Lifecycle: startTunnel / stopTunnel
//   - handleAppMessage: opcode 0x00 GET_RUNTIME_CONFIG, 0x01 SET_PSK
//   - applyPresharedKey: builds new TunnelConfiguration with PSK and
//     hands it to WireGuardAdapter.update()
//   - makeTunnelConfiguration: CloakConfig wire format → WireGuardKit
//     model
//   - makeNetworkSettings: TunnelConfiguration → NEPacketTunnelNetwork-
//     Settings (port of upstream's PacketTunnelSettingsGenerator.
//     generateNetworkSettings — this is the bit Mullvad's adapter is
//     missing)
//
// Opcodes 0x02-0x04 (Option D rosenpass UDP relay) will be re-added
// after this file is validated end-to-end with plain WG.

import Foundation
import Network
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

        // ROOT-CAUSE FIX: install network settings on the utun BEFORE
        // adapter.start. Upstream's WireGuardAdapter does this for you;
        // Mullvad's fork (which we depend on via SwiftPM) does NOT.
        // Without this call, the utun has no IPs/routes/DNS and iOS
        // routes nothing into the tunnel even though wireguard-go is
        // running and WG handshakes complete.
        let networkSettings = Self.makeNetworkSettings(from: tunnelCfg)
        os_log("setTunnelNetworkSettings: applying", log: log, type: .info)
        setTunnelNetworkSettings(networkSettings) { [weak self] settingsError in
            guard let self = self else { return }
            if let settingsError = settingsError {
                os_log("setTunnelNetworkSettings failed: %{public}s",
                       log: self.log, type: .error,
                       String(describing: settingsError))
                completionHandler(settingsError)
                return
            }
            os_log("setTunnelNetworkSettings: applied; starting adapter",
                   log: self.log, type: .info)

            // Now hand off to WireGuardAdapter. With Mullvad's fork the
            // adapter will:
            //   1. NOT call setTunnelNetworkSettings (we did it above)
            //   2. Resolve endpoints, build the wg UAPI config string
            //   3. Call wgTurnOnIAN to start the wireguard-go data plane
            //      against the utun fd we already configured
            self.adapter.start(tunnelConfiguration: tunnelCfg) { [weak self] adapterError in
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

// MARK: - TunnelConfiguration → NEPacketTunnelNetworkSettings
//
// Port of upstream wireguard-apple's
// PacketTunnelSettingsGenerator.generateNetworkSettings, with logic kept
// identical so the routing/DNS behaviour matches the official WG iOS app
// exactly. We need this because Mullvad's WireGuardAdapter doesn't call
// setTunnelNetworkSettings on our behalf.
//
// SPDX-License-Identifier: MIT (the inlined logic below is © 2018-2023
// WireGuard LLC, MIT-licensed in upstream wireguard-apple).
extension PacketTunnelProvider {
    static func makeNetworkSettings(from tunnelCfg: TunnelConfiguration) -> NEPacketTunnelNetworkSettings {
        // iOS requires a tunnelRemoteAddress, but WG can have many or
        // zero peers — 127.0.0.1 is the upstream-blessed placeholder.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        // ---- DNS ----
        if !tunnelCfg.interface.dnsSearch.isEmpty || !tunnelCfg.interface.dns.isEmpty {
            let dnsServerStrings = tunnelCfg.interface.dns.map { $0.stringRepresentation }
            let dnsSettings = NEDNSSettings(servers: dnsServerStrings)
            dnsSettings.searchDomains = tunnelCfg.interface.dnsSearch
            if !tunnelCfg.interface.dns.isEmpty {
                // Force ALL DNS through the tunnel. Without this, iOS
                // can leak DNS to the captive resolver via mDNSResponder.
                dnsSettings.matchDomains = [""]
            }
            settings.dnsSettings = dnsSettings
        }

        // ---- MTU ----
        // 1280 is upstream's chosen-by-pain default for iOS (see
        // PacketTunnelSettingsGenerator comment about "broken networks
        // out there"). If our config specifies a non-zero MTU, honor it.
        let mtu = tunnelCfg.interface.mtu ?? 0
        if mtu == 0 {
            settings.mtu = NSNumber(value: 1280)
        } else {
            settings.mtu = NSNumber(value: mtu)
        }

        // ---- Local interface addresses ----
        var ipv4Addresses: [(addr: String, mask: String)] = []
        var ipv6Addresses: [(addr: String, prefix: NSNumber)] = []
        for range in tunnelCfg.interface.addresses {
            if range.address is IPv4Address {
                ipv4Addresses.append(("\(range.address)", "\(range.subnetMask())"))
            } else if range.address is IPv6Address {
                ipv6Addresses.append(("\(range.address)",
                                     NSNumber(value: range.networkPrefixLength)))
            }
        }

        // ---- Included routes (= what gets routed INTO the tunnel) ----
        var ipv4Routes = [NEIPv4Route]()
        var ipv6Routes = [NEIPv6Route]()

        // First: routes to our own interface subnets, with us as gateway.
        for range in tunnelCfg.interface.addresses {
            if range.address is IPv4Address {
                let route = NEIPv4Route(destinationAddress: "\(range.maskedAddress())",
                                        subnetMask: "\(range.subnetMask())")
                route.gatewayAddress = "\(range.address)"
                ipv4Routes.append(route)
            } else if range.address is IPv6Address {
                let route = NEIPv6Route(destinationAddress: "\(range.maskedAddress())",
                                        networkPrefixLength: NSNumber(value: range.networkPrefixLength))
                route.gatewayAddress = "\(range.address)"
                ipv6Routes.append(route)
            }
        }

        // Then: each peer's allowedIPs becomes an included route.
        // For full-tunnel WG (allowedIPs = 0.0.0.0/0, ::/0) this is what
        // installs the default route into the tunnel. THIS is the line
        // whose absence was breaking us.
        for peer in tunnelCfg.peers {
            for range in peer.allowedIPs {
                if range.address is IPv4Address {
                    ipv4Routes.append(NEIPv4Route(destinationAddress: "\(range.address)",
                                                  subnetMask: "\(range.subnetMask())"))
                } else if range.address is IPv6Address {
                    ipv6Routes.append(NEIPv6Route(destinationAddress: "\(range.address)",
                                                  networkPrefixLength: NSNumber(value: range.networkPrefixLength)))
                }
            }
        }

        // ---- IPv4 settings ----
        let v4 = NEIPv4Settings(addresses: ipv4Addresses.map { $0.addr },
                                subnetMasks: ipv4Addresses.map { $0.mask })
        v4.includedRoutes = ipv4Routes
        settings.ipv4Settings = v4

        // ---- IPv6 settings ----
        let v6 = NEIPv6Settings(addresses: ipv6Addresses.map { $0.addr },
                                networkPrefixLengths: ipv6Addresses.map { $0.prefix })
        v6.includedRoutes = ipv6Routes
        settings.ipv6Settings = v6

        return settings
    }
}
