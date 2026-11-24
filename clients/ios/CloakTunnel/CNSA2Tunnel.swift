import Foundation
import Network
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
    private var port = 1194
    private var identity: TunnelIdentity?
    private var rekeyInterval: TimeInterval = 300
    /// Set once the tunnel has come up the first time. From then on a lost connection is
    /// rebuilt here, with the routes left in place so traffic waits instead of leaking.
    private var everConnected = false
    private var appliedSettings: TunnelSettings?
    private var retryDelay: TimeInterval = 1
    private var retryPending = false
    private var pumping = false
    private var pathMonitor: NWPathMonitor?
    private var lastPath: String?
    private var pendingPath: String?
    private var currentPath = ""

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
                self.port = port
                self.identity = identity
                self.rekeyInterval = rekey
                self.startCompletion = completion
                try self.connect()
            } catch {
                os_log("cnsa2: start failed: %{public}s", log: self.log, type: .error, String(describing: error))
                self.teardown()
                completion(error)
            }
        }
    }

    private func connect() throws {
        guard let identity else { throw LatticeTunnelError("configuration") }
        try openSocket(host: host, port: port)
        let s = TunnelSession(identity: identity, rekeyInterval: rekeyInterval)
        let fd = self.fd
        s.send = { d in _ = d.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } }
        s.onPacket = { [weak self] packet in
            self?.provider?.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
        }
        s.log = { [weak self] line in
            guard let self else { return }
            os_log("cnsa2: %{public}s", log: self.log, type: .info, line)
        }
        s.onStateChange = { [weak self, weak s] state in
            guard let self, let s, self.session === s else { return }
            self.sessionChanged(state)
        }
        session = s

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.session?.tick(now: self.now())
        }
        t.resume()
        timer = t
        s.start(now: now())
    }

    private func openSocket(host: String, port: Int) throws {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { throw LatticeTunnelError("cannot resolve the gateway") }
        defer { freeaddrinfo(res) }
        let s = socket(info.pointee.ai_family, SOCK_DGRAM, 0)
        guard s >= 0, Darwin.connect(s, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
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
            teardown()
            if let completion = startCompletion {
                startCompletion = nil
                completion(LatticeTunnelError(reason))
            } else if stopping {
                return
            } else if everConnected && !Self.permanent.contains(where: { reason.localizedCaseInsensitiveContains($0) }) {
                scheduleRetry(reason)
            } else {
                provider?.cancelTunnelWithError(LatticeTunnelError(reason))
            }
        default:
            break
        }
    }

    /// Failures that trying again cannot fix.
    private static let permanent = ["certificate rejected", "refused this device", "outside the CNSA", "chose cipher",
                                    "compression", "did not agree", "device certificate", "device key", "not enrolled"]

    private func scheduleRetry(_ reason: String) {
        guard !stopping, !retryPending else { return }
        retryPending = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        provider?.reasserting = true
        os_log("cnsa2: down (%{public}s), retrying in %{public}.0f s; traffic is held", log: log, type: .error, reason, delay)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopping else { return }
            self.retryPending = false
            guard self.session == nil else { return }
            do { try self.connect() } catch {
                self.teardown()
                self.scheduleRetry(String(describing: error))
            }
        }
    }

    /// The network under the tunnel changed: rebuild now instead of waiting for the keepalive to notice.
    private func pathChanged(_ description: String) {
        // An empty description means no usable network: wait for one instead of reacting.
        guard !description.isEmpty else { return }
        guard everConnected, !stopping, let known = lastPath, known != description else { lastPath = lastPath ?? description; return }
        // Phones report brief changes all the time. Act only if the new primary
        // interface is still the primary one two seconds later.
        pendingPath = description
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.pendingPath == description, self.currentPath == description, !self.stopping else { return }
            self.pendingPath = nil
            self.switchPath(to: description)
        }
    }

    private func switchPath(to description: String) {
        guard lastPath != description else { return }
        lastPath = description
        os_log("cnsa2: network changed, reconnecting", log: log, type: .info)
        session?.close(now: now())
        teardown()
        retryDelay = 1
        provider?.reasserting = true
        if !retryPending { do { try connect() } catch { teardown(); scheduleRetry(String(describing: error)) } }
    }

    private func watchPath() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
        m.pathUpdateHandler = { [weak self] path in
            // Identify the path by its primary physical interface only (for example en0
            // for Wi-Fi, pdp_ip0 for cellular). The full list changes too often to act on.
            let primary = path.status == .satisfied ? (path.availableInterfaces.first?.name ?? "") : ""
            self?.currentPath = primary
            self?.pathChanged(primary)
        }
        m.start(queue: queue)
        pathMonitor = m
    }

    private func applySettings(_ assigned: TunnelSettings) {
        if everConnected, appliedSettings == assigned {
            // back up after a drop with the same address: nothing to change
            retryDelay = 1
            provider?.reasserting = false
            return
        }
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
                self.appliedSettings = assigned
                self.everConnected = true
                self.retryDelay = 1
                self.provider?.reasserting = false
                self.watchPath()
                if !self.pumping { self.pumping = true; self.pump() }
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
            pathMonitor?.cancel(); pathMonitor = nil
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

    /// Reads outgoing packets for as long as the tunnel exists. While the connection is
    /// down they are dropped here, so nothing leaves outside the tunnel.
    private func pump() {
        provider?.packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async {
                guard !self.stopping else { return }
                if let s = self.session {
                    let t = self.now()
                    for (i, p) in packets.enumerated() where protocols[i].int32Value == AF_INET { s.sendPacket(p, now: t) }
                }
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
