import CryptoKit
import Foundation

/// The only PRF in the profile: HMAC-SHA-384.
enum PRF {
    static let size = 48
    static func mac(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA384>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
    /// prf+ from RFC 7296 section 2.13.
    static func plus(key: Data, seed: Data, length: Int) -> Data {
        var out = Data(), t = Data(), i: UInt8 = 1
        while out.count < length {
            t = mac(key: key, t + seed + Data([i]))
            out.append(t)
            i += 1
        }
        return out.prefix(length)
    }
}

/// AES-256-GCM with a 16-byte tag, as used by both IKE (RFC 5282) and ESP (RFC 4106):
/// nonce = 4-byte salt from the key material followed by the 8-byte explicit IV.
struct GCMKey {
    let key: SymmetricKey
    let salt: Data
    init(material: Data) {
        precondition(material.count == 36)
        key = SymmetricKey(data: material.prefix(32))
        salt = Data(material.suffix(4))
    }
    func seal(_ plaintext: Data, iv: Data, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: salt + iv), authenticating: aad)
        return box.ciphertext + box.tag
    }
    func open(_ sealed: Data, iv: Data, aad: Data) throws -> Data {
        guard sealed.count >= 16 else { throw IKEError.malformed("ciphertext shorter than tag") }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: salt + iv),
                                        ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }
}

func randomBytes(_ n: Int) -> Data {
    var d = Data(count: n)
    let rc = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
    precondition(rc == errSecSuccess)
    return d
}
