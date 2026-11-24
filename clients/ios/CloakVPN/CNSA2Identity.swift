import CryptoKit
import Foundation
import Security

/// The device's CNSA 2.0 identity: an ML-DSA-87 key (FIPS 204) made on this device.
///
/// The whole key derives from a 32 byte seed, which is the only secret. It is created
/// here, kept in the keychain as a this-device-only item (never in a backup, never
/// synced), and never leaves the device. Only the certificate request does.
/// Shared by the app (enrollment) and the tunnel extension (reads the identity).
enum CNSA2Identity {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static let service = "ai.cloakvpn.cnsa2.identity"
    #if os(macOS)
    /// Team keychain group both the Mac app and its tunnel extension are entitled to.
    private static let accessGroup = "5HYY2YP2G9.ai.cloakvpn.CloakVPN"
    #else
    /// On iOS the shared App Group doubles as the keychain access group.
    private static let accessGroup = "group.ai.cloakvpn.CloakVPN"
    #endif

    static var isEnrolled: Bool { read("seed") != nil && read("certificate") != nil }

    /// PKCS#10 request for this device, signed with its key. Creates the key on first use.
    static func certificateRequest(commonName: String) throws -> Data {
        guard commonName.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil else {
            throw Failure(description: "invalid device name")
        }
        let key = try privateKey(create: true)
        let info = DER.sequence(
            DER.integerZero
            + DER.sequence(DER.set(DER.sequence(DER.commonNameOID + DER.utf8(commonName))))
            + publicKeyInfo(key)
            + Data([0xa0, 0x00]))   // no attributes
        let signature = try key.signature(for: info)
        return DER.sequence(info + DER.mlDSA87 + DER.bitString(signature))
    }

    /// Accepts a certificate only if it carries this device's public key.
    static func storeCertificate(_ der: Data) throws {
        let key = try privateKey(create: false)
        guard der.range(of: publicKeyInfo(key)) != nil else { throw Failure(description: "certificate is for a different key") }
        try write("certificate", der)
    }

    static func certificate() -> Data? { read("certificate") }

    /// When the stored certificate expires, as the server reported it. Kept beside the
    /// certificate so the app and the tunnel extension agree on when to renew.
    static var certificateExpiry: Date? {
        guard let data = read("expiry"), let text = String(data: data, encoding: .utf8),
              let seconds = TimeInterval(text), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func setCertificateExpiry(_ date: Date) throws {
        try write("expiry", Data(String(Int(date.timeIntervalSince1970)).utf8))
    }

    /// PKCS#8 in the seed-only form, as OpenSSL 3.5 reads it.
    static func privateKeyPKCS8() throws -> Data {
        guard let seed = read("seed") else { throw Failure(description: "this device is not enrolled") }
        return Data([0x30, 0x34, 0x02, 0x01, 0x00]) + DER.mlDSA87 + Data([0x04, 0x22, 0x80, 0x20]) + seed
    }

    static func reset() {
        for account in ["seed", "certificate", "expiry"] { SecItemDelete(query(account) as CFDictionary) }
    }

    // MARK: key

    private static func privateKey(create: Bool) throws -> MLDSA87.PrivateKey {
        if let seed = read("seed") { return try MLDSA87.PrivateKey(seedRepresentation: seed, publicKey: nil) }
        guard create else { throw Failure(description: "this device has no key yet") }
        var seed = Data(count: 32)
        let status = seed.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure(description: "no randomness") }
        let key = try MLDSA87.PrivateKey(seedRepresentation: seed, publicKey: nil)
        try write("seed", seed)
        SecItemDelete(query("certificate") as CFDictionary)
        SecItemDelete(query("expiry") as CFDictionary)
        return key
    }

    private static func publicKeyInfo(_ key: MLDSA87.PrivateKey) -> Data {
        DER.sequence(DER.mlDSA87 + DER.bitString(key.publicKey.rawRepresentation))
    }

    // MARK: keychain

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup,
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func write(_ account: String, _ value: Data) throws {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = value
        // readable by the tunnel while the device is locked, never copied to another device
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(description: "keychain refused the item (\(status))") }
    }

    // MARK: DER

    private enum DER {
        /// AlgorithmIdentifier for id-ml-dsa-87 (2.16.840.1.101.3.4.3.19), no parameters.
        static let mlDSA87 = Data([0x30, 0x0b, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x13])
        static let commonNameOID = Data([0x06, 0x03, 0x55, 0x04, 0x03])
        static let integerZero = Data([0x02, 0x01, 0x00])

        static func length(_ n: Int) -> Data {
            if n < 0x80 { return Data([UInt8(n)]) }
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        static func tagged(_ tag: UInt8, _ content: Data) -> Data { Data([tag]) + length(content.count) + content }
        static func sequence(_ content: Data) -> Data { tagged(0x30, content) }
        static func set(_ content: Data) -> Data { tagged(0x31, content) }
        static func utf8(_ s: String) -> Data { tagged(0x0c, Data(s.utf8)) }
        static func bitString(_ content: Data) -> Data { tagged(0x03, Data([0x00]) + content) }
    }
}
