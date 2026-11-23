import Foundation

/// IKEv2 wire constants used by the profile (RFC 7296, 7383, 7427, 9242, 9370).
enum Wire {
    static let saInit: UInt8 = 34, auth: UInt8 = 35, createChild: UInt8 = 36, informational: UInt8 = 37, intermediate: UInt8 = 43
    static let pSA: UInt8 = 33, pKE: UInt8 = 34, pIDi: UInt8 = 35, pIDr: UInt8 = 36, pCERT: UInt8 = 37, pCERTREQ: UInt8 = 38, pAUTH: UInt8 = 39
    static let pNonce: UInt8 = 40, pNotify: UInt8 = 41, pDelete: UInt8 = 42, pTSi: UInt8 = 44, pTSr: UInt8 = 45
    static let pSK: UInt8 = 46, pCP: UInt8 = 47, pSKF: UInt8 = 53
    static let flagInitiator: UInt8 = 0x08, flagResponse: UInt8 = 0x20

    // Transform types and the single allowed value for each.
    static let tENCR: UInt8 = 1, tPRF: UInt8 = 2, tKE: UInt8 = 4, tESN: UInt8 = 5, tADDKE1: UInt8 = 6
    static let encrAESGCM16: UInt16 = 20, prfHMACSHA384: UInt16 = 6, groupECP384: UInt16 = 20, groupMLKEM1024: UInt16 = 37

    static let nNATSrc: UInt16 = 16388, nNATDst: UInt16 = 16389, nFragmentation: UInt16 = 16430
    static let nSignatureHashAlgorithms: UInt16 = 16431, nIntermediate: UInt16 = 16438

    /// DER AlgorithmIdentifier for ML-DSA-87 (2.16.840.1.101.3.4.3.19, no parameters).
    static let mldsa87AlgorithmID = Data([0x30, 0x0b, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x13])

    static let errorNames: [UInt16: String] = [
        7: "INVALID_SYNTAX", 14: "NO_PROPOSAL_CHOSEN", 17: "INVALID_KE_PAYLOAD", 24: "AUTHENTICATION_FAILED",
        34: "SINGLE_PAIR_REQUIRED", 35: "NO_ADDITIONAL_SAS", 36: "INTERNAL_ADDRESS_FAILURE", 37: "FAILED_CP_REQUIRED",
        38: "TS_UNACCEPTABLE", 43: "TEMPORARY_FAILURE", 44: "CHILD_SA_NOT_FOUND",
    ]
}

struct Payload {
    let type: UInt8
    let body: Data

    static func encode(_ ps: [Payload]) -> Data {
        var d = Data()
        for (i, p) in ps.enumerated() {
            d.u8(i + 1 < ps.count ? ps[i + 1].type : 0); d.u8(0); d.u16(UInt16(p.body.count + 4)); d.append(p.body)
        }
        return d
    }
    static func decode(first: UInt8, _ d: Data) throws -> [Payload] {
        var out: [Payload] = [], t = first, o = 0
        while t != 0 {
            let next = try d.rU8(o), len = Int(try d.rU16(o + 2))
            guard len >= 4 else { throw IKEError.malformed("payload length") }
            out.append(Payload(type: t, body: try d.slice(o + 4, len - 4)))
            o += len; t = next
        }
        return out
    }
    static func notify(_ type: UInt16, _ data: Data = Data()) -> Payload {
        var d = Data(); d.u8(0); d.u8(0); d.u16(type); d.append(data)
        return Payload(type: Wire.pNotify, body: d)
    }
}

struct Transform: Hashable {
    let type: UInt8, id: UInt16, keyLength: UInt16?
    func encoded(last: Bool) -> Data {
        var d = Data(); d.u8(last ? 0 : 3); d.u8(0); d.u16(keyLength == nil ? 8 : 12); d.u8(type); d.u8(0); d.u16(id)
        if let k = keyLength { d.u16(0x800e); d.u16(k) }
        return d
    }
}

enum Proposal {
    static func encode(protocolID: UInt8, spi: Data, _ ts: [Transform]) -> Data {
        var body = Data()
        for (i, t) in ts.enumerated() { body.append(t.encoded(last: i == ts.count - 1)) }
        var d = Data(); d.u8(0); d.u8(0); d.u16(UInt16(8 + spi.count + body.count)); d.u8(1); d.u8(protocolID)
        d.u8(UInt8(spi.count)); d.u8(UInt8(ts.count)); d.append(spi); d.append(body)
        return d
    }
    /// Parses the single proposal a responder returns.
    static func decode(_ d: Data) throws -> (protocolID: UInt8, spi: Data, transforms: Set<Transform>) {
        guard try d.rU8(0) == 0 else { throw IKEError.malformed("responder returned more than one proposal") }
        let proto = try d.rU8(5), spiSize = Int(try d.rU8(6)), n = Int(try d.rU8(7))
        let spi = try d.slice(8, spiSize)
        var o = 8 + spiSize, out = Set<Transform>()
        for _ in 0..<n {
            let len = Int(try d.rU16(o + 2)), type = try d.rU8(o + 4), id = try d.rU16(o + 6)
            var key: UInt16?
            if len >= 12, try d.rU16(o + 8) == 0x800e { key = try d.rU16(o + 10) }
            out.insert(Transform(type: type, id: id, keyLength: key))
            o += len
        }
        return (proto, spi, out)
    }
}
