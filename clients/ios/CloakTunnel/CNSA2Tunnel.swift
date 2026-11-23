import CryptoKit
import Foundation
import NetworkExtension
import os.log
#if canImport(LatticeIKE)
import LatticeIKE
#endif

/// Runs the CNSA 2.0 (IKEv2/IPsec) tunnel inside the packet tunnel extension, as an
/// alternative to the WireGuard path. Selected when the provider configuration carries a
/// "cnsa2" dictionary:
///   host, port, gatewayID, clientID      strings / number
///   caDER, clientCertDER, clientKeySeed  base64
///   routes                               ["10.99.0.0/24"] or ["0.0.0.0/0"]
///   dns                                  optional ["1.1.1.1"], used when the gateway sends none
///   rekeySeconds                         optional, default 300
/// There is no fallback: if the profile cannot be negotiated the tunnel does not come up.
final class CNSA2TunnelController {
    private let log = OSLog(subsystem: "ai.cloakvpn.CloakVPN.tunnel", category: "cnsa2")
    private weak var provider: NEPacketTunnelProvider?
    private var runtime: IKETunnelRuntime?
    private var stopping = false

    init(provider: NEPacketTunnelProvider) { self.provider = provider }

    func start(_ cfg: [String: Any], completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                func b64(_ k: String) throws -> Data {
                    guard let s = cfg[k] as? String, let d = Data(base64Encoded: s) else { throw IKEError.malformed("configuration value \(k)") }
                    return d
                }
                guard let host = cfg["host"] as? String, let gatewayID = cfg["gatewayID"] as? String,
                      let clientID = cfg["clientID"] as? String else { throw IKEError.malformed("configuration") }
                let port = UInt16((cfg["port"] as? NSNumber)?.intValue ?? 4500)
                let key = try MLDSA87.PrivateKey(seedRepresentation: try b64("clientKeySeed"), publicKey: nil)
                var options = IKETunnelRuntime.Options()
                if let r = (cfg["rekeySeconds"] as? NSNumber)?.doubleValue, r >= 10 { options.rekeyInterval = r }
                let rt = try IKETunnelRuntime(host: host, port: port,
                                              config: .init(gatewayID: gatewayID, clientID: clientID,
                                                            ca: try MLDSACertificate(der: try b64("caDER")),
                                                            clientCertificateDER: try b64("clientCertDER"), clientKey: key),
                                              options: options)
                let est = try rt.connect()
                guard let vip = est.virtualIP else { throw IKEError.policy("gateway assigned no address") }
                os_log("cnsa2: established, IKE %{public}s, ESP %{public}s, auth %{public}s", log: self.log, type: .info,
                       est.ikeSuite, est.espSuite, est.authentication)

                let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: host)
                let v4 = NEIPv4Settings(addresses: [vip.map(String.init).joined(separator: ".")], subnetMasks: ["255.255.255.255"])
                v4.includedRoutes = ((cfg["routes"] as? [String]) ?? ["0.0.0.0/0"]).compactMap(Self.route)
                settings.ipv4Settings = v4
                settings.mtu = 1280
                var dns = est.dnsServers.map { $0.map(String.init).joined(separator: ".") }
                if dns.isEmpty { dns = (cfg["dns"] as? [String]) ?? [] }
                if !dns.isEmpty { settings.dnsSettings = NEDNSSettings(servers: dns) }

                self.provider?.setTunnelNetworkSettings(settings) { [weak self] error in
                    guard let self else { return }
                    if let error { rt.stop(); completion(error); return }
                    self.runtime = rt
                    rt.onPacket = { [weak self] packet in
                        self?.provider?.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
                    }
                    rt.onStopped = { [weak self] error in
                        guard let self, !self.stopping else { return }
                        os_log("cnsa2: connection ended: %{public}s", log: self.log, type: .error, String(describing: error))
                        self.provider?.cancelTunnelWithError(error)
                    }
                    rt.start()
                    self.pump()
                    completion(nil)
                }
            } catch {
                os_log("cnsa2: start failed: %{public}s", log: self.log, type: .error, String(describing: error))
                completion(error)
            }
        }
    }

    func stop() {
        stopping = true
        runtime?.stop()
        runtime = nil
    }

    /// Status line for the app: "rekeys=N".
    var statusLine: String { "cnsa2 rekeys=\(runtime?.childRekeys ?? 0)" }

    private func pump() {
        provider?.packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, let rt = self.runtime else { return }
            for (i, p) in packets.enumerated() where protocols[i].int32Value == AF_INET { rt.send(p) }
            self.pump()
        }
    }

    private static func route(_ cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits) else { return nil }
        if bits == 0 { return NEIPv4Route.default() }
        let mask = UInt32.max << UInt32(32 - bits)
        let m = [24, 16, 8, 0].map { String((mask >> UInt32($0)) & 0xff) }.joined(separator: ".")
        return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: m)
    }
}
