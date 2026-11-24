import Foundation

// The tunnel framing is the OpenVPN wire protocol (control channel carrying
// TLS, AEAD data channel), so the gateway can be a stock OpenVPN 2.6 server.

enum Opcode: UInt8 {
    case softReset = 3        // P_CONTROL_SOFT_RESET_V1
    case control = 4          // P_CONTROL_V1
    case ack = 5              // P_ACK_V1
    case dataV1 = 6           // P_DATA_V1
    case hardResetClient = 7  // P_CONTROL_HARD_RESET_CLIENT_V2
    case hardResetServer = 8  // P_CONTROL_HARD_RESET_SERVER_V2
    case dataV2 = 9           // P_DATA_V2
}

extension Data {
    mutating func appendUInt16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
    mutating func appendUInt32(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xff)); append(UInt8((v >> 8) & 0xff)); append(UInt8(v & 0xff))
    }
}

/// Bounds-checked reader. Every parse of gateway input goes through this.
struct Reader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw LatticeTunnelError("truncated packet") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    mutating func uint32() throws -> UInt32 {
        let b = try take(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw LatticeTunnelError("truncated packet") }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func rest() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }
}

struct ControlPacket {
    var opcode: Opcode
    var keyID: UInt8
    var sessionID: Data
    var acks: [UInt32] = []
    var remoteSessionID: Data?
    var packetID: UInt32?
    var payload = Data()

    static let maxAcks = 8

    func encoded() -> Data {
        var out = Data([opcode.rawValue << 3 | (keyID & 7)])
        out.append(sessionID)
        out.append(UInt8(acks.count))
        for a in acks { out.appendUInt32(a) }
        if !acks.isEmpty, let remote = remoteSessionID { out.append(remote) }
        if let id = packetID { out.appendUInt32(id) }
        out.append(payload)
        return out
    }

    static func parse(_ datagram: Data) throws -> ControlPacket {
        var r = Reader(datagram)
        let first = try r.byte()
        guard let op = Opcode(rawValue: first >> 3), op != .dataV1, op != .dataV2 else {
            throw LatticeTunnelError("unknown packet type")
        }
        var p = ControlPacket(opcode: op, keyID: first & 7, sessionID: Data(try r.take(8)))
        let count = Int(try r.byte())
        guard count <= maxAcks else { throw LatticeTunnelError("too many acknowledgements") }
        for _ in 0..<count { p.acks.append(try r.uint32()) }
        if count > 0 { p.remoteSessionID = Data(try r.take(8)) }
        if op != .ack {
            p.packetID = try r.uint32()
            p.payload = r.rest()
        }
        return p
    }
}

/// Keys for one direction pair, taken from the TLS exporter.
struct DataKeys {
    let sealKey: Data, sealIV: Data   // device -> gateway
    let openKey: Data, openIV: Data   // gateway -> device

    static let exporterLabel = "EXPORTER-OpenVPN-datakeys"
    static let exporterLength = 256

    /// Layout: two keys, each 64 bytes of cipher key then 64 bytes of HMAC key.
    /// AES-256-GCM uses the first 32 cipher bytes, and the first 8 HMAC bytes
    /// as the fixed part of the nonce. The client sends with the first key.
    init(exported: Data) throws {
        guard exported.count == DataKeys.exporterLength else { throw LatticeTunnelError("bad key material") }
        let b = [UInt8](exported)
        sealKey = Data(b[0..<32]); sealIV = Data(b[64..<72])
        openKey = Data(b[128..<160]); openIV = Data(b[192..<200])
    }
}

/// Sliding window against replayed data packets.
struct ReplayWindow {
    private var highest: UInt32 = 0
    private var seen: UInt64 = 0

    mutating func accept(_ id: UInt32) -> Bool {
        if id == 0 { return false }
        if id > highest {
            let shift = id - highest
            seen = shift >= 64 ? 0 : seen << UInt64(shift)
            seen |= 1
            highest = id
            return true
        }
        let behind = highest - id
        if behind >= 64 { return false }
        let bit = UInt64(1) << UInt64(behind)
        if seen & bit != 0 { return false }
        seen |= bit
        return true
    }
}

enum DataChannel {
    /// OpenVPN's keepalive payload.
    static let ping = Data([0x2a, 0x18, 0x7b, 0xf3, 0x64, 0x1e, 0xb4, 0xcb, 0x07, 0xed, 0x2d, 0x0a, 0x98, 0x1f, 0xc7, 0x48])

    static func seal(_ plaintext: Data, keys: DataKeys, keyID: UInt8, peerID: UInt32, packetID: UInt32) throws -> Data {
        var header = Data([Opcode.dataV2.rawValue << 3 | (keyID & 7),
                           UInt8((peerID >> 16) & 0xff), UInt8((peerID >> 8) & 0xff), UInt8(peerID & 0xff)])
        header.appendUInt32(packetID)
        var nonce = Data(); nonce.appendUInt32(packetID); nonce.append(keys.sealIV)
        let sealed = try GCM.seal(key: keys.sealKey, nonce: nonce, ad: header, plaintext: plaintext)
        return header + sealed.tag + sealed.ciphertext
    }

    /// Returns the packet ID and plaintext, or nil if the packet does not authenticate.
    static func open(_ datagram: Data, keys: DataKeys) -> (packetID: UInt32, plaintext: Data)? {
        let b = [UInt8](datagram)
        guard let first = b.first else { return nil }
        let headerLength = (first >> 3) == Opcode.dataV2.rawValue ? 4 : 1
        guard b.count >= headerLength + 4 + 16 else { return nil }
        let id = UInt32(b[headerLength]) << 24 | UInt32(b[headerLength + 1]) << 16 | UInt32(b[headerLength + 2]) << 8 | UInt32(b[headerLength + 3])
        let ad = Data(b[0..<headerLength + 4])
        let tag = Data(b[headerLength + 4..<headerLength + 20])
        let ciphertext = Data(b[(headerLength + 20)...])
        var nonce = Data(b[headerLength..<headerLength + 4]); nonce.append(keys.openIV)
        guard let plain = GCM.open(key: keys.openKey, nonce: nonce, ad: ad, ciphertext: ciphertext, tag: tag) else { return nil }
        return (id, plain)
    }
}
