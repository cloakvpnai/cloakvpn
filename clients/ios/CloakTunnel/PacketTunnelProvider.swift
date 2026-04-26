import Foundation
import Network
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

    /// The IP literal of the rosenpass server (extracted from
    /// `CloakConfig.rpEndpoint` at startTunnel time). When set, every
    /// `setTunnelNetworkSettings` call has an `excludedRoutes` entry for
    /// this IP added before being passed through to the parent. Without
    /// the exclusion, the WG `0.0.0.0/0, ::/0` AllowedIPs route claims
    /// EVERY destination — including UDP/9999 to the rosenpass server —
    /// leaving the main app's rosenpass NWConnection sitting in
    /// `.waiting` state forever (with `prohibitedInterfaceTypes = [.other]`
    /// excluding utun, no usable path remains, and iOS does not fall back).
    /// See docs/IOS_PQC.md "End-to-end smoke test" §8 for the full debug
    /// story. Cleared in stopTunnel.
    private var rosenpassServerIP: String?

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

        // Stash the rosenpass server IP so our setTunnelNetworkSettings
        // override can carve a hole in WireGuard's full-tunnel routing
        // for it. Only relevant when PQC is enabled — for classical-only
        // configs the main app never sends to UDP/9999 anyway.
        if cloakCfg.pqEnabled {
            self.rosenpassServerIP = Self.extractIP(from: cloakCfg.rpEndpoint)
            if rosenpassServerIP == nil {
                // Soft warn but don't fail the whole tunnel — the user
                // can still get classical-tunnel coverage. The PQC loop
                // will simply fail to handshake, surfacing in the UI.
                os_log("startTunnel: couldn't parse IP from rpEndpoint %{public}s; PQC routing exclude disabled",
                       log: log, type: .error, cloakCfg.rpEndpoint)
            }
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
            self.rosenpassServerIP = nil
            completionHandler()
        }
    }

    // MARK: - Tunnel network settings injection

    /// Intercepts every `setTunnelNetworkSettings` call WireGuardKit makes
    /// (initial tunnel-up + every PSK rotation re-key) and adds an
    /// `excludedRoutes` entry for the rosenpass server's IP before passing
    /// through to the parent. This is the surgical, Mullvad-pattern
    /// alternative to manually carving 192.0.0.0/4 out of the peer's
    /// AllowedIPs in the wire-format config:
    ///
    ///   - Server-side configs stay clean — `add-peer.sh` writes the usual
    ///     `0.0.0.0/0, ::/0` and we don't lose tunnel coverage for any
    ///     unrelated IPs.
    ///   - The exclusion is reapplied on every settings write, so PSK
    ///     rotations don't accidentally drop it.
    ///   - Only the rosenpass server's exact `/32` (IPv4) or `/128` (IPv6)
    ///     is excluded — strictly the minimum hole needed.
    ///
    /// If `rosenpassServerIP` is nil (PQC disabled or rpEndpoint
    /// unparseable), we pass the settings through unmodified and the
    /// behavior degrades to classical-only WG.
    override func setTunnelNetworkSettings(
        _ tunnelNetworkSettings: NETunnelNetworkSettings?,
        completionHandler: ((Error?) -> Void)? = nil
    ) {
        if let settings = tunnelNetworkSettings as? NEPacketTunnelNetworkSettings,
           let serverIP = self.rosenpassServerIP {
            Self.injectRosenpassExcludedRoute(into: settings, ip: serverIP, log: log)
        }
        super.setTunnelNetworkSettings(tunnelNetworkSettings, completionHandler: completionHandler)
    }

    /// Mutates the given settings to add a single `/32` (or `/128`) excluded
    /// route for the rosenpass server's IP. Idempotent — checking via
    /// destinationAddress equality avoids duplicate entries on re-keys.
    private static func injectRosenpassExcludedRoute(
        into settings: NEPacketTunnelNetworkSettings,
        ip: String,
        log: OSLog
    ) {
        if let v4 = IPv4Address(ip) {
            let route = NEIPv4Route(destinationAddress: ip, subnetMask: "255.255.255.255")
            let ipv4 = settings.ipv4Settings ?? NEIPv4Settings(addresses: [], subnetMasks: [])
            var existing = ipv4.excludedRoutes ?? []
            if !existing.contains(where: { $0.destinationAddress == ip }) {
                existing.append(route)
                ipv4.excludedRoutes = existing
                settings.ipv4Settings = ipv4
                os_log("excluded route added for rosenpass server %{public}s/32",
                       log: log, type: .info, ip)
            }
            _ = v4 // silence unused-binding warning while still validating parse
        } else if let v6 = IPv6Address(ip) {
            let route = NEIPv6Route(destinationAddress: ip, networkPrefixLength: 128)
            let ipv6 = settings.ipv6Settings ?? NEIPv6Settings(addresses: [], networkPrefixLengths: [])
            var existing = ipv6.excludedRoutes ?? []
            if !existing.contains(where: { $0.destinationAddress == ip }) {
                existing.append(route)
                ipv6.excludedRoutes = existing
                settings.ipv6Settings = ipv6
                os_log("excluded route added for rosenpass server %{public}s/128",
                       log: log, type: .info, ip)
            }
            _ = v6
        } else {
            os_log("rosenpass server IP %{public}s parsed as neither v4 nor v6 — exclude skipped",
                   log: log, type: .error, ip)
        }
    }

    /// Parse the host part of an "IP:port" or "[IPv6]:port" string. Returns
    /// only the host substring; intentionally does NOT do DNS resolution
    /// (we'd need to do that asynchronously and synchronizing with
    /// startTunnel adds complexity for negligible benefit — `add-peer.sh`
    /// always writes a literal IP into rpEndpoint). If/when we move to
    /// DNS-based endpoints, replace this with NWPathMonitor or
    /// CFHostStartInfoResolution-based resolution.
    private static func extractIP(from endpoint: String) -> String? {
        // Strip port. IPv6 endpoints are bracketed: "[::1]:9999".
        if endpoint.hasPrefix("[") {
            // [v6]:port form
            guard let close = endpoint.firstIndex(of: "]") else { return nil }
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            return IPv6Address(host) != nil ? host : nil
        }
        // v4-style host:port — split on the LAST colon to be safe with
        // bare-IPv6 (no brackets, no port) inputs, which we then validate.
        if let colon = endpoint.lastIndex(of: ":") {
            let host = String(endpoint[..<colon])
            if IPv4Address(host) != nil { return host }
            // Could be a bare IPv6 with no port — try the whole string
            if IPv6Address(endpoint) != nil { return endpoint }
            return nil
        }
        // No port at all — assume bare host, validate as IP
        if IPv4Address(endpoint) != nil { return endpoint }
        if IPv6Address(endpoint) != nil { return endpoint }
        return nil
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
