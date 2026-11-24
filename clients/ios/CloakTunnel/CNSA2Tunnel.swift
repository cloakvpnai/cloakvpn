import Foundation
import NetworkExtension
import os.log
#if canImport(LatticeTLS)
import LatticeTLS
#endif

/// Runs the CNSA 2.0 tunnel (TLS 1.3, see clients/apple-tls) inside the packet tunnel
/// extension, as an alternative to the WireGuard path. Selected when the provider
/// configuration carries a "cnsa2" dictionary:
///   host, port, gatewayID                    strings / number (gatewayID is the name in the gateway certificate)
///   caDER                                    base64
///   clientCertDER, clientKeyPKCS8            base64, lab only; normally the device's own enrolled identity is used
///   routes                                   optional ["10.88.0.0/24"] or ["0.0.0.0/0"]; default is what the gateway assigns
///   dns                                      optional ["1.1.1.1"], used when the gateway sends none
///   rekeySeconds                             optional, default 300
/// There is no fallback: if the suite cannot be negotiated the tunnel does not come up.
final class CNSA2TunnelController {
    private let log = OSLog(subsystem: "ai.cloakvpn.CloakVPN.tunnel", category: "cnsa2")
    private weak var provider: NEPacketTunnelProvider?
    /// Every call into the session happens on this queue.
    private let queue = DispatchQueue(label: "ai.cloakvpn.cnsa2")
    private var session: TunnelSession?
    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var startCompletion: ((Error?) -> Void)?
    private var stopping = false
    private var config: [String: Any] = [:]
    private var host = ""

    init(provider: NEPacketTunnelProvider) { self.provider = provider }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start(_ cfg: [String: Any], completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            do {
                func b64(_ k: String) throws -> Data {
                    guard let s = cfg[k] as? String, let d = Data(base64Encoded: s) else { throw LatticeTunnelError("configuration value \(k)") }
                    return d
                }
                guard let host = cfg["host"] as? String, let gatewayName = cfg["gatewayID"] as? String else {
                    throw LatticeTunnelError("configuration")
                }
                let port = (cfg["port"] as? NSNumber)?.intValue ?? 1194
                var rekey: TimeInterval = 300
                if let r = (cfg["rekeySeconds"] as? NSNumber)?.doubleValue, r >= 10 { rekey = r }
                // The device's own enrolled identity, unless a lab configuration supplies one.
                let certificate: Data, key: Data
                if cfg["clientKeyPKCS8"] != nil {
                    certificate = try b64("clientCertDER"); key = try b64("clientKeyPKCS8")
                } else {
                    guard let stored = CNSA2Identity.certificate() else { throw LatticeTunnelError("this device is not enrolled") }
                    certificate = stored; key = try CNSA2Identity.privateKeyPKCS8()
                }
                let identity = TunnelIdentity(caDER: try b64("caDER"), certificateDER: certificate,
                                              privateKeyPKCS8: key, gatewayName: gatewayName)
                self.config = cfg
                self.host = host
                self.startCompletion = completion
                try self.openSocket(host: host, port: port)

                let s = TunnelSession(identity: identity, rekeyInterval: rekey)
                let fd = self.fd
                s.send = { d in _ = d.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } }
                s.onPacket = { [weak self] packet in
                    self?.provider?.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
                }
                s.log = { [weak self] line in
                    guard let self else { return }
                    os_log("cnsa2: %{public}s", log: self.log, type: .info, line)
                }
                s.onStateChange = { [weak self] state in self?.sessionChanged(state) }
                self.session = s

                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now() + 0.2, repeating: 0.2)
                t.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.session?.tick(now: self.now())
                }
                t.resume()
                self.timer = t
                s.start(now: self.now())
            } catch {
                os_log("cnsa2: start failed: %{public}s", log: self.log, type: .error, String(describing: error))
                self.teardown()
                completion(error)
            }
        }
    }

    private func openSocket(host: String, port: Int) throws {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { throw LatticeTunnelError("cannot resolve the gateway") }
        defer { freeaddrinfo(res) }
        let s = socket(info.pointee.ai_family, SOCK_DGRAM, 0)
        guard s >= 0, connect(s, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            if s >= 0 { close(s) }
            throw LatticeTunnelError("cannot reach the gateway")
        }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        fd = s
        let r = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        r.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = recv(s, &buffer, buffer.count, 0)
                if n <= 0 { break }
                self.session?.receive(Data(buffer[0..<n]), now: self.now())
            }
        }
        r.setCancelHandler { close(s) }
        r.resume()
        reader = r
    }

    private func sessionChanged(_ state: TunnelSession.State) {
        switch state {
        case .connected:
            guard let s = session else { return }
            os_log("cnsa2: established, %{public}s", log: log, type: .info, s.suite)
            applySettings(s.settings)
        case .failed(let reason):
            os_log("cnsa2: connection ended: %{public}s", log: log, type: .error, reason)
            let error = LatticeTunnelError(reason)
            teardown()
            if let completion = startCompletion {
                startCompletion = nil
                completion(error)
            } else if !stopping {
                provider?.cancelTunnelWithError(error)
            }
        default:
            break
        }
    }

    private func applySettings(_ assigned: TunnelSettings) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: host)
        let v4 = NEIPv4Settings(addresses: [assigned.address], subnetMasks: [assigned.netmask])
        if let routes = config["routes"] as? [String] {
            v4.includedRoutes = routes.compactMap(Self.route)
        } else if assigned.redirectGateway {
            v4.includedRoutes = [NEIPv4Route.default()]
        } else {
            var routes = [Self.subnetRoute(address: assigned.address, netmask: assigned.netmask)].compactMap { $0 }
            for r in assigned.routes {
                let parts = r.split(separator: " ").map(String.init)
                if let first = parts.first {
                    routes.append(NEIPv4Route(destinationAddress: first, subnetMask: parts.count > 1 ? parts[1] : "255.255.255.255"))
                }
            }
            v4.includedRoutes = routes
        }
        settings.ipv4Settings = v4
        settings.mtu = 1280
        let dns = assigned.dns.isEmpty ? ((config["dns"] as? [String]) ?? []) : assigned.dns
        if !dns.isEmpty { settings.dnsSettings = NEDNSSettings(servers: dns) }

        provider?.setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                let completion = self.startCompletion
                self.startCompletion = nil
                if let error {
                    self.session?.close(now: self.now())
                    self.teardown()
                    completion?(error)
                    return
                }
                self.pump()
                completion?(nil)
            }
        }
    }

    private func teardown() {
        timer?.cancel(); timer = nil
        reader?.cancel(); reader = nil   // closes the socket
        fd = -1
        session = nil
    }

    /// Tells the gateway the connection is over, then calls `completion`.
    func stop(completion: @escaping () -> Void) {
        queue.async { [self] in
            stopping = true
            session?.close(now: now())
            // let the exit notice leave before the socket closes
            queue.asyncAfter(deadline: .now() + 0.3) { [self] in
                teardown()
                completion()
            }
        }
    }

    /// Answer to the app's status query. `last_handshake_time_sec` is when the keys in use
    /// were last established (connect or the most recent re-key).
    var statusReport: String {
        queue.sync {
            guard let s = session else { return "mode=cnsa2\n" }
            let age = max(0, now() - s.lastKeyTime)
            let t = Int(Date().timeIntervalSince1970 - age)
            return "mode=cnsa2\nlast_handshake_time_sec=\(t)\ncnsa2_rekeys=\(s.rekeyCount)\ncnsa2_suite=\(s.suite)\n"
        }
    }

    private func pump() {
        provider?.packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async {
                guard let s = self.session else { return }
                let t = self.now()
                for (i, p) in packets.enumerated() where protocols[i].int32Value == AF_INET { s.sendPacket(p, now: t) }
                self.pump()
            }
        }
    }

    private static func subnetRoute(address: String, netmask: String) -> NEIPv4Route? {
        let a = address.split(separator: ".").compactMap { UInt8($0) }, m = netmask.split(separator: ".").compactMap { UInt8($0) }
        guard a.count == 4, m.count == 4 else { return nil }
        let net = zip(a, m).map { String($0 & $1) }.joined(separator: ".")
        return NEIPv4Route(destinationAddress: net, subnetMask: netmask)
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
