import Foundation

/// One pair of ESP security associations in UDP encapsulation (RFC 3948),
/// AES-256-GCM only. Replay protection is a simple highest-sequence check for now.
public final class ESPTunnel {
    let outSPI: Data
    public let inSPI: Data
    let outKey: GCMKey, inKey: GCMKey
    private var outSeq: UInt32 = 0
    private var highestIn: UInt32 = 0

    init(outSPI: Data, inSPI: Data, keymat: Data) {
        self.outSPI = outSPI; self.inSPI = inSPI
        outKey = GCMKey(material: keymat.prefix(36))
        inKey = GCMKey(material: Data(keymat.dropFirst(36).prefix(36)))
    }

    /// Wraps one IPv4 packet for the gateway.
    public func seal(_ packet: Data) throws -> Data {
        outSeq += 1
        var head = Data(); head.append(outSPI); head.u32(outSeq)
        var iv = Data(); iv.u64(UInt64(outSeq))
        var plain = packet
        let pad = (4 - ((packet.count + 2) % 4)) % 4
        for i in 0..<pad { plain.u8(UInt8(i + 1)) }
        plain.u8(UInt8(pad)); plain.u8(4)   // next header: IPv4
        return head + iv + (try outKey.seal(plain, iv: iv, aad: head))
    }

    /// Unwraps one ESP datagram from the gateway. Returns nil for keepalives or other SPIs.
    public func open(_ datagram: Data) throws -> Data? {
        guard datagram.count >= 4 + 4 + 8 + 16, try datagram.slice(0, 4) == inSPI else { return nil }
        let seq = try datagram.rU32(4)
        guard seq > highestIn else { return nil }
        let plain = try inKey.open(try datagram.slice(16, datagram.count - 16), iv: try datagram.slice(8, 8), aad: try datagram.slice(0, 8))
        highestIn = seq
        guard plain.count >= 2 else { throw IKEError.malformed("ESP trailer") }
        let pad = Int(plain[plain.count - 2])
        guard plain.count >= pad + 2 else { throw IKEError.malformed("ESP padding") }
        return Data(plain.prefix(plain.count - pad - 2))
    }
}
