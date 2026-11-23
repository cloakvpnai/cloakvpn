import Foundation
import LatticeTLS

// Lab probe: connects to a gateway, pings it through the tunnel, reports re-keys.
//   tlsprobe <host> <port> <ca.der> <cert.der> <key.pkcs8.der> <gateway name> [rekey seconds] [run seconds]

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 7 else {
    print("usage: tlsprobe host port ca.der cert.der key.der gatewayName [rekeySeconds] [runSeconds]")
    exit(2)
}
func file(_ path: String) -> Data {
    guard let d = FileManager.default.contents(atPath: path) else { print("cannot read \(path)"); exit(2) }
    return d
}
let rekey = args.count > 7 ? TimeInterval(args[7]) ?? 60 : 60
let runFor = args.count > 8 ? TimeInterval(args[8]) ?? 150 : 150

// UDP socket
var hints = addrinfo(); hints.ai_socktype = SOCK_DGRAM; hints.ai_family = AF_INET
var res: UnsafeMutablePointer<addrinfo>?
guard getaddrinfo(args[1], args[2], &hints, &res) == 0, let info = res else { print("cannot resolve \(args[1])"); exit(1) }
let fd = socket(info.pointee.ai_family, SOCK_DGRAM, 0)
guard fd >= 0, connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { print("socket failed"); exit(1) }
freeaddrinfo(res)

func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

func checksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var i = 0
    while i + 1 < bytes.count { sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]); i += 2 }
    if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum & 0xffff)
}
func ipv4(_ s: String) -> [UInt8] { s.split(separator: ".").compactMap { UInt8($0) } }
func echoRequest(from: String, to: String, seq: UInt16) -> Data {
    var icmp: [UInt8] = [8, 0, 0, 0, 0x4c, 0x56, UInt8(seq >> 8), UInt8(seq & 0xff)] + Array("lattice-cnsa2-tls".utf8)
    let c = checksum(icmp); icmp[2] = UInt8(c >> 8); icmp[3] = UInt8(c & 0xff)
    let total = 20 + icmp.count
    var ip: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 0xff), 0, 0, 0, 0, 64, 1, 0, 0] + ipv4(from) + ipv4(to)
    let h = checksum(ip); ip[10] = UInt8(h >> 8); ip[11] = UInt8(h & 0xff)
    return Data(ip + icmp)
}

let identity = TunnelIdentity(caDER: file(args[3]), certificateDER: file(args[4]), privateKeyPKCS8: file(args[5]), gatewayName: args[6])
let session = TunnelSession(identity: identity, rekeyInterval: rekey)
var replies = 0, sent = 0
let started = now()
session.send = { d in _ = d.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } }
session.log = { print(String(format: "[%6.2f] %@", now() - started, $0)) }
session.onStateChange = { print(String(format: "[%6.2f] state: %@", now() - started, "\($0)")) }
session.onPacket = { p in
    let b = [UInt8](p)
    if b.count >= 28, b[9] == 1, b[20] == 0 { replies += 1 }
}
session.start(now: now())

var buffer = [UInt8](repeating: 0, count: 65536)
var lastPing: TimeInterval = 0
var connectedAt: TimeInterval?
while true {
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    if poll(&p, 1, 100) > 0 {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n > 0 { session.receive(Data(buffer[0..<n]), now: now()) }
    }
    let t = now()
    session.tick(now: t)
    if case .failed(let why) = session.state { print("FAILED: \(why)"); exit(1) }
    if session.state == .connected {
        if connectedAt == nil {
            connectedAt = t
            print(String(format: "[%6.2f] connected in %.0f ms, suite: %@", t - started, (t - started) * 1000, session.suite))
            print("         address \(session.settings.address), gateway \(session.settings.gateway)")
        }
        if t - lastPing >= 1 {
            lastPing = t
            sent += 1
            session.sendPacket(echoRequest(from: session.settings.address, to: session.settings.gateway, seq: UInt16(sent & 0xffff)), now: t)
        }
        if t - connectedAt! >= runFor { break }
    } else if t - started > 40 { print("FAILED: no connection"); exit(1) }
}
Thread.sleep(forTimeInterval: 0.3)
var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
while poll(&p, 1, 50) > 0 { let n = recv(fd, &buffer, buffer.count, 0); if n > 0 { session.receive(Data(buffer[0..<n]), now: now()) } }
session.close(now: now())
print("pings: \(replies)/\(sent) answered, re-keys: \(session.rekeyCount), suite: \(session.suite)")
exit(replies >= sent - 2 && replies > 0 ? 0 : 1)
