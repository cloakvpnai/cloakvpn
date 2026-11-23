import CryptoKit
import Foundation

/// Minimal DER reader: enough to pull the signed body, signature, subject,
/// issuer, validity, public key and DNS names out of an ML-DSA-87 certificate.
struct DER {
    struct Node { let tag: UInt8; let value: Data; let raw: Data }

    static func read(_ d: Data, _ o: inout Int) throws -> Node {
        let start = o
        let tag = try d.rU8(o); o += 1
        var len = Int(try d.rU8(o)); o += 1
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n >= 1, n <= 4 else { throw IKEError.malformed("DER length") }
            len = 0
            for _ in 0..<n { len = (len << 8) | Int(try d.rU8(o)); o += 1 }
        }
        let value = try d.slice(o, len); o += len
        return Node(tag: tag, value: value, raw: try d.slice(start, o - start))
    }
    static func children(_ d: Data) throws -> [Node] {
        var o = 0, out: [Node] = []
        while o < d.count { out.append(try read(d, &o)) }
        return out
    }
}

public struct MLDSACertificate {
    static let oidMLDSA87 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x13])
    static let oidSAN = Data([0x55, 0x1d, 0x11])

    public let der: Data
    let tbs: Data
    let signature: Data
    let issuer: Data
    let subject: Data
    public let notBefore: Date
    public let notAfter: Date
    public let publicKey: MLDSA87.PublicKey
    public let dnsNames: [String]

    public init(der: Data) throws {
        self.der = der
        var o = 0
        let cert = try DER.read(der, &o)
        let parts = try DER.children(cert.value)
        guard cert.tag == 0x30, parts.count == 3 else { throw IKEError.malformed("certificate structure") }
        tbs = parts[0].raw
        guard try Self.algorithmOID(parts[1]) == Self.oidMLDSA87 else { throw IKEError.policy("certificate is not signed with ML-DSA-87") }
        guard parts[2].tag == 0x03, parts[2].value.first == 0 else { throw IKEError.malformed("certificate signature") }
        signature = Data(parts[2].value.dropFirst())

        var f = try DER.children(parts[0].value)
        if f.first?.tag == 0xa0 { f.removeFirst() }
        guard f.count >= 6 else { throw IKEError.malformed("certificate body") }
        issuer = f[2].raw
        let validity = try DER.children(f[3].value)
        guard validity.count == 2 else { throw IKEError.malformed("certificate validity") }
        notBefore = try Self.time(validity[0]); notAfter = try Self.time(validity[1])
        subject = f[4].raw
        let spki = try DER.children(f[5].value)
        guard spki.count == 2, try Self.algorithmOID(spki[0]) == Self.oidMLDSA87 else { throw IKEError.policy("certificate key is not ML-DSA-87") }
        guard spki[1].tag == 0x03, spki[1].value.first == 0 else { throw IKEError.malformed("certificate public key") }
        publicKey = try MLDSA87.PublicKey(rawRepresentation: Data(spki[1].value.dropFirst()))

        var names: [String] = []
        if let ext = f.dropFirst(6).first(where: { $0.tag == 0xa3 }), let list = try DER.children(ext.value).first {
            for e in try DER.children(list.value) {
                let kv = try DER.children(e.value)
                guard kv.first?.tag == 0x06, kv.first?.value == Self.oidSAN, let octets = kv.last, octets.tag == 0x04 else { continue }
                if let seq = try DER.children(octets.value).first {
                    for gn in try DER.children(seq.value) where gn.tag == 0x82 {
                        names.append(String(decoding: gn.value, as: UTF8.self))
                    }
                }
            }
        }
        dnsNames = names
    }

    static func algorithmOID(_ n: DER.Node) throws -> Data {
        guard n.tag == 0x30, let oid = try DER.children(n.value).first, oid.tag == 0x06 else { throw IKEError.malformed("algorithm identifier") }
        return oid.value
    }
    static func time(_ n: DER.Node) throws -> Date {
        let s = String(decoding: n.value, as: UTF8.self)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = n.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        guard let d = f.date(from: s) else { throw IKEError.malformed("certificate time") }
        return d
    }

    /// Checks that `self` was issued by `ca`, is inside its validity period, and names `host`.
    public func verify(issuedBy ca: MLDSACertificate, expectedDNSName host: String, now: Date = Date()) throws {
        guard issuer == ca.subject else { throw IKEError.authentication("gateway certificate was not issued by the Lattice CA") }
        guard ca.publicKey.isValidSignature(signature, for: tbs) else { throw IKEError.authentication("gateway certificate signature is invalid") }
        guard now >= notBefore, now <= notAfter else { throw IKEError.authentication("gateway certificate is outside its validity period") }
        guard now >= ca.notBefore, now <= ca.notAfter else { throw IKEError.authentication("CA certificate is outside its validity period") }
        guard dnsNames.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) else {
            throw IKEError.authentication("gateway certificate does not name \(host)")
        }
    }
}

/// Pulls the 32-byte seed out of an OpenSSL/strongSwan PKCS#8 ML-DSA-87 key (lab use).
public func mldsa87Seed(fromPKCS8 der: Data) throws -> Data {
    var o = 0
    let top = try DER.read(der, &o)
    let parts = try DER.children(top.value)
    guard parts.count >= 3, parts[2].tag == 0x04 else { throw IKEError.malformed("PKCS#8 structure") }
    var p = 0
    let inner = try DER.read(parts[2].value, &p)
    if inner.tag == 0x80, inner.value.count == 32 { return inner.value }
    if inner.tag == 0x30, let seed = try DER.children(inner.value).first, seed.tag == 0x04, seed.value.count == 32 { return seed.value }
    throw IKEError.malformed("PKCS#8 key has no seed")
}
