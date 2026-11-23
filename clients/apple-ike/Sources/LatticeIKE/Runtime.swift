import CryptoKit
import Darwin
import Foundation

/// UDP socket to the gateway. Sockets opened by a packet tunnel extension are not routed
/// through the tunnel itself, so this is usable from inside the extension.
public final class POSIXUDPTransport: DatagramTransport {
    private let fd: Int32

    public init(host: String, port: UInt16) throws {
        var hints = addrinfo(), res: UnsafeMutablePointer<addrinfo>?
        hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { throw IKEError.transport("cannot resolve \(host)") }
        defer { freeaddrinfo(res) }
        fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0, connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { throw IKEError.transport("cannot reach \(host)") }
    }
    deinit { close(fd) }

    public func send(_ datagram: Data) throws {
        let n = datagram.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, datagram.count, 0) }
        guard n == datagram.count else { throw IKEError.transport("send failed (errno \(errno))") }
    }
    public func receive(timeout: TimeInterval) throws -> Data? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 65535)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0 ? Data(buf.prefix(n)) : nil
    }
}

/// Runs one CNSA 2.0 connection: handshake, then a single thread that reads the socket,
/// replaces the data keys on a timer, and sends NAT keepalives. Packets from the system are
/// sent with `send(_:)` from any thread.
public final class IKETunnelRuntime {
    public struct Options {
        /// How often the data keys are replaced with a fresh ML-KEM-1024 exchange.
        public var rekeyInterval: TimeInterval = 300
        public var keepaliveInterval: TimeInterval = 20
        public init() {}
    }

    /// Called on the runtime thread for every decrypted IP packet from the gateway.
    public var onPacket: ((Data) -> Void)?
    /// Called once when the connection ends; the error is nil for a requested stop.
    public var onStopped: ((Error?) -> Void)?

    private let session: IKESession
    private let options: Options
    private let state = NSLock()
    private var running = false
    public var childRekeys: Int { session.childRekeys }

    public init(host: String, port: UInt16, config: IKESession.Config, options: Options = Options()) throws {
        session = IKESession(transport: try POSIXUDPTransport(host: host, port: port), config: config)
        self.options = options
    }

    /// Blocking handshake. Call off the main thread.
    public func connect() throws -> IKESession.Established { try session.connect() }

    public func start() {
        state.lock(); running = true; state.unlock()
        let t = Thread { [weak self] in self?.loop() }
        t.name = "lattice.ike.runtime"; t.qualityOfService = .userInitiated
        t.start()
    }

    public func stop() { state.lock(); running = false; state.unlock() }

    public func send(_ packet: Data) { try? session.sendPacket(packet) }

    private var isRunning: Bool { state.lock(); defer { state.unlock() }; return running }

    private func loop() {
        var lastRekey = Date(), lastKeepalive = Date(), failure: Error?
        while isRunning, session.isOpen {
            do {
                if Date().timeIntervalSince(lastRekey) >= options.rekeyInterval {
                    try session.rekeyChild()
                    lastRekey = Date()
                }
                if Date().timeIntervalSince(lastKeepalive) >= options.keepaliveInterval {
                    try session.sendKeepalive()
                    lastKeepalive = Date()
                }
                if let p = try session.receivePacket(timeout: 0.5) { onPacket?(p) }
            } catch {
                failure = error
                break
            }
        }
        let requested = !isRunning
        if session.isOpen { try? session.close() }
        if failure == nil, !requested { failure = IKEError.transport("the gateway closed the connection") }
        onStopped?(failure)
    }
}
