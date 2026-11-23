//
//  MLKEM768Exchange.swift
//
//  Client half of the ML-KEM-768 (FIPS 203) exchange that produces the
//  WireGuard preshared key. Server half: server/api/internal/wg/mlkem.go.
//
//    1. The device creates a fresh ML-KEM-768 key pair for each provision
//       and sends only the encapsulation (public) key with POST /v1/device.
//    2. The region's concentrator encapsulates against it, installs the
//       derived key as this peer's WireGuard PSK, and returns the ciphertext.
//    3. The device decapsulates and derives the same key:
//
//         PSK = HKDF-SHA256(ikm  = ML-KEM shared secret,
//                           salt = client WG public key || server WG public key,
//                           info = "lattice-vpn/mlkem768-wg-psk/v1")
//
//  The private key lives only in memory for the duration of one provision.
//  Compiled for macOS only for now; iOS keeps the Rosenpass path until its
//  own migration.
//

#if os(macOS)
import CryptoKit
import Foundation

enum MLKEM768ExchangeError: Error {
    case badCiphertext
    case badWireGuardKey
}

struct MLKEM768Exchange {
    /// Value the server puts in `PQKEM` when it used this path.
    static let pqKEMName = "ML-KEM-768"

    private static let info = Data("lattice-vpn/mlkem768-wg-psk/v1".utf8)
    private static let ciphertextSize = 1088

    private let privateKey: MLKEM768.PrivateKey

    init() throws {
        privateKey = try MLKEM768.PrivateKey()
    }

    /// Base64 of the 1184-byte encapsulation key to send to the server.
    var publicKeyB64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Decapsulate the server's ciphertext and derive the WireGuard PSK.
    /// Returns base64 of exactly 32 bytes.
    func presharedKeyB64(ciphertextB64: String,
                         clientWGPublicKeyB64: String,
                         serverWGPublicKeyB64: String) throws -> String {
        guard let ciphertext = Data(base64Encoded: ciphertextB64),
              ciphertext.count == Self.ciphertextSize else {
            throw MLKEM768ExchangeError.badCiphertext
        }
        guard let clientWG = Data(base64Encoded: clientWGPublicKeyB64), clientWG.count == 32,
              let serverWG = Data(base64Encoded: serverWGPublicKeyB64), serverWG.count == 32 else {
            throw MLKEM768ExchangeError.badWireGuardKey
        }
        let sharedSecret = try privateKey.decapsulate(ciphertext)
        let psk = HKDF<SHA256>.deriveKey(inputKeyMaterial: sharedSecret,
                                         salt: clientWG + serverWG,
                                         info: Self.info,
                                         outputByteCount: 32)
        return psk.withUnsafeBytes { Data($0) }.base64EncodedString()
    }
}
#endif
