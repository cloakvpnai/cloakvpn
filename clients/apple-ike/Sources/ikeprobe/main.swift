import CryptoKit
import Darwin
import Foundation
import LatticeIKE

// ikeprobe: connects to a gateway with the CNSA 2.0 profile, pings through the
// tunnel, and reports what was negotiated. Development tool for the lab.

func checksum(_ d: Data) -> UInt16 {
    var sum: UInt32 = 0, i = 0
    let b = [UInt8](d)
    while i + 1 < b.count { sum += UInt32(b[i]) << 8 | UInt32(b[i + 1]); i += 2 }
    if i < b.count { sum += UInt32(b[i]) << 8 }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
}

func icmpEcho(src: [UInt8], dst: [UInt8], seq: UInt16) -> Data {
    var icmp = Data([8, 0, 0, 0, 0x4c, 0x56, UInt8(seq >> 8), UInt8(seq & 0xff)]) + Data("lattice-cnsa2".utf8)
    let c = checksum(icmp); icmp[2] = UInt8(c >> 8); icmp[3] = UInt8(c & 0xff)
    let total = UInt16(20 + icmp.count)
    var ip = Data([0x45, 0, UInt8(total >> 8), UInt8(total & 0xff), 0, UInt8(seq & 0xff), 0, 0, 64, 1, 0, 0] + src + dst)
    let h = checksum(ip); ip[10] = UInt8(h >> 8); ip[11] = UInt8(h & 0xff)
    return ip + icmp
}

let a = CommandLine.arguments
guard a.count >= 8 else {
    print("usage: ikeprobe <host> <port> <ca.der> <client.der> <client.key.der> <clientID> <gatewayID> [pingTarget]")
    exit(2)
}
do {
    let ca = try MLDSACertificate(der: try Data(contentsOf: URL(fileURLWithPath: a[3])))
    let seed = try mldsa87Seed(fromPKCS8: try Data(contentsOf: URL(fileURLWithPath: a[5])))
    let key = try MLDSA87.PrivateKey(seedRepresentation: seed, publicKey: nil)
    let session = IKESession(transport: try POSIXUDPTransport(host: a[1], port: UInt16(a[2])!),
                             config: .init(gatewayID: a[7], clientID: a[6], ca: ca,
                                           clientCertificateDER: try Data(contentsOf: URL(fileURLWithPath: a[4])), clientKey: key))
    let t0 = Date()
    let r = try session.connect()
    print(String(format: "connected in %.0f ms", Date().timeIntervalSince(t0) * 1000))
    print("IKE:  \(r.ikeSuite)")
    print("ESP:  \(r.espSuite)")
    print("Auth: \(r.authentication)")
    print("Address: \(r.virtualIP.map { $0.map(String.init).joined(separator: ".") } ?? "none")")
    if let vip = r.virtualIP {
        let target = (a.count > 8 ? a[8] : "10.99.0.1").split(separator: ".").map { UInt8($0)! }
        var seq: UInt16 = 0
        func ping(_ label: String) throws {
            var replies = 0
            for _ in 1...3 {
                seq += 1
                try session.sendPacket(icmpEcho(src: vip, dst: target, seq: seq))
                if let p = try session.receivePacket(timeout: 2), p.count >= 28, p[9] == 1, p[20] == 0 { replies += 1 }
            }
            print("\(label): \(replies) of 3 replies (SPI \(session.inboundSPI))")
        }
        try ping("Ping through tunnel")
        let rounds = Int(ProcessInfo.processInfo.environment["REKEYS"] ?? "2") ?? 2
        for i in 0..<rounds {
            try session.rekeyChild()
            try ping("After re-key \(i + 1) (ML-KEM-1024)")
        }
    }
    try session.close()
    print("closed cleanly")
} catch {
    print("FAILED: \(error)")
    exit(1)
}
