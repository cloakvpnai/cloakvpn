import CLatticeTLS
import Foundation

public struct LatticeTunnelError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The device's CNSA 2.0 identity and the gateway it trusts. All DER.
public struct TunnelIdentity {
    public var caDER: Data
    public var certificateDER: Data
    public var privateKeyPKCS8: Data
    public var gatewayName: String

    public init(caDER: Data, certificateDER: Data, privateKeyPKCS8: Data, gatewayName: String) {
        self.caDER = caDER
        self.certificateDER = certificateDER
        self.privateKeyPKCS8 = privateKeyPKCS8
        self.gatewayName = gatewayName
    }
}

/// One TLS 1.3 handshake and session, restricted to the CNSA 2.0 suite by OpenSSL.
final class TLSSession {
    private let handle: OpaquePointer

    init(identity: TunnelIdentity) throws {
        var err = [CChar](repeating: 0, count: 256)
        let made = identity.caDER.withUnsafeBytes { ca in
            identity.certificateDER.withUnsafeBytes { cert in
                identity.privateKeyPKCS8.withUnsafeBytes { key in
                    ltls_new(ca.bindMemory(to: UInt8.self).baseAddress, ca.count,
                             cert.bindMemory(to: UInt8.self).baseAddress, cert.count,
                             key.bindMemory(to: UInt8.self).baseAddress, key.count,
                             identity.gatewayName, &err, err.count)
                }
            }
        }
        guard let made else { throw LatticeTunnelError(String(cString: err)) }
        handle = made
    }

    deinit { ltls_free(handle) }

    var summary: String { String(cString: ltls_describe(handle)) }
    private var lastError: LatticeTunnelError { LatticeTunnelError(String(cString: ltls_error(handle))) }

    func feed(_ data: Data) throws {
        let r = data.withUnsafeBytes { ltls_feed(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        if r != 0 { throw LatticeTunnelError("TLS input failed") }
    }

    /// True once the handshake is complete and the negotiated suite has been checked.
    func handshake() throws -> Bool {
        switch ltls_handshake(handle) {
        case 1: return true
        case 0: return false
        default: throw lastError
        }
    }

    func drain() -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = ltls_drain(handle, &buffer, buffer.count)
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<Int(n)])
        }
        return out
    }

    func write(_ data: Data) throws {
        let r = data.withUnsafeBytes { ltls_write(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        if r != 0 { throw LatticeTunnelError("TLS write failed") }
    }

    /// Application data, one element per TLS record (the gateway sends one message per record).
    func readRecords() throws -> [Data] {
        var out: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 17408)
        while true {
            let n = ltls_read(handle, &buffer, buffer.count)
            if n < 0 { throw lastError }
            if n == 0 { break }
            out.append(Data(buffer[0..<Int(n)]))
        }
        return out
    }

    func export(label: String, length: Int) throws -> Data {
        var out = [UInt8](repeating: 0, count: length)
        guard ltls_export(handle, label, &out, length) == 0 else { throw LatticeTunnelError("key export failed") }
        return Data(out)
    }
}

/// AES-256-GCM for the data channel, from the same OpenSSL as the handshake.
enum GCM {
    static func seal(key: Data, nonce: Data, ad: Data, plaintext: Data) throws -> (ciphertext: Data, tag: Data) {
        var out = [UInt8](repeating: 0, count: max(plaintext.count, 1))
        var tag = [UInt8](repeating: 0, count: 16)
        let r = key.withUnsafeBytes { k in nonce.withUnsafeBytes { n in ad.withUnsafeBytes { a in plaintext.withUnsafeBytes { p in
            ltls_gcm_seal(k.bindMemory(to: UInt8.self).baseAddress, n.bindMemory(to: UInt8.self).baseAddress,
                          a.bindMemory(to: UInt8.self).baseAddress, a.count,
                          p.bindMemory(to: UInt8.self).baseAddress, p.count, &out, &tag)
        } } } }
        guard r == 0 else { throw LatticeTunnelError("encryption failed") }
        return (Data(out[0..<plaintext.count]), Data(tag))
    }

    static func open(key: Data, nonce: Data, ad: Data, ciphertext: Data, tag: Data) -> Data? {
        var out = [UInt8](repeating: 0, count: max(ciphertext.count, 1))
        let r = key.withUnsafeBytes { k in nonce.withUnsafeBytes { n in ad.withUnsafeBytes { a in ciphertext.withUnsafeBytes { c in tag.withUnsafeBytes { t in
            ltls_gcm_open(k.bindMemory(to: UInt8.self).baseAddress, n.bindMemory(to: UInt8.self).baseAddress,
                          a.bindMemory(to: UInt8.self).baseAddress, a.count,
                          c.bindMemory(to: UInt8.self).baseAddress, c.count,
                          t.bindMemory(to: UInt8.self).baseAddress, &out)
        } } } } }
        return r == 0 ? Data(out[0..<ciphertext.count]) : nil
    }
}

func randomBytes(_ count: Int) -> Data {
    var out = [UInt8](repeating: 0, count: count)
    precondition(ltls_random(&out, count) == 0, "no randomness")
    return Data(out)
}
