package ai.latticevpn.android.vpn

import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMExtractor
import org.bouncycastle.pqc.crypto.mlkem.MLKEMKeyGenerationParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMKeyPairGenerator
import org.bouncycastle.pqc.crypto.mlkem.MLKEMParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMPrivateKeyParameters
import java.security.SecureRandom
import java.util.Base64

/**
 * Client half of the ML-KEM-768 (FIPS 203) exchange that produces the
 * WireGuard preshared key. Server half: server/api/internal/wg/mlkem.go.
 * The iOS and macOS apps do the same thing in MLKEM768Exchange.swift.
 *
 *  1. The device creates a fresh ML-KEM-768 key pair for each provision and
 *     sends only the encapsulation (public) key with POST /v1/device.
 *  2. The region's concentrator encapsulates against it, installs the derived
 *     key as this peer's WireGuard PSK, and returns the ciphertext.
 *  3. The device decapsulates and derives the same key:
 *
 *       PSK = HKDF-SHA256(ikm  = ML-KEM shared secret,
 *                         salt = client WG public key || server WG public key,
 *                         info = "lattice-vpn/mlkem768-wg-psk/v1")
 *
 * The private key lives only in memory for the duration of one provision.
 */
class MlKem768Exchange private constructor(
    private val privateKey: MLKEMPrivateKeyParameters,
) {

    /** A fresh key pair from the system CSPRNG. */
    constructor() : this(generate())

    /** Base64 of the 1184-byte encapsulation key to send to the server. */
    val publicKeyB64: String = Base64.getEncoder()
        .encodeToString(privateKey.publicKeyParameters.encoded)

    /**
     * Decapsulate the server's ciphertext and derive the 32-byte WireGuard
     * preshared key. Throws [IllegalArgumentException] on malformed input.
     */
    fun presharedKey(
        ciphertextB64: String,
        clientWgPublicKeyB64: String,
        serverWgPublicKeyB64: String,
    ): ByteArray {
        val ciphertext = Base64.getDecoder().decode(ciphertextB64)
        require(ciphertext.size == CIPHERTEXT_SIZE) { "ML-KEM-768 ciphertext must be $CIPHERTEXT_SIZE bytes" }
        val clientWg = Base64.getDecoder().decode(clientWgPublicKeyB64)
        val serverWg = Base64.getDecoder().decode(serverWgPublicKeyB64)
        require(clientWg.size == 32 && serverWg.size == 32) { "WireGuard public keys must be 32 bytes" }

        val sharedSecret = MLKEMExtractor(privateKey).extractSecret(ciphertext)
        try {
            val hkdf = HKDFBytesGenerator(SHA256Digest())
            hkdf.init(HKDFParameters(sharedSecret, clientWg + serverWg, INFO))
            val psk = ByteArray(32)
            hkdf.generateBytes(psk, 0, psk.size)
            return psk
        } finally {
            sharedSecret.fill(0)
        }
    }

    companion object {
        private fun generate(): MLKEMPrivateKeyParameters {
            val generator = MLKEMKeyPairGenerator()
            generator.init(MLKEMKeyGenerationParameters(SecureRandom(), MLKEMParameters.ml_kem_768))
            return generator.generateKeyPair().private as MLKEMPrivateKeyParameters
        }

        /** Deterministic key pair from a 64-byte FIPS 203 seed (d || z). Tests only. */
        internal fun fromSeed(seed: ByteArray): MlKem768Exchange {
            require(seed.size == 64) { "ML-KEM seed must be 64 bytes" }
            return MlKem768Exchange(MLKEMPrivateKeyParameters(MLKEMParameters.ml_kem_768, seed))
        }

        /** Value the server puts in `PQKEM` when it used this path. */
        const val PQ_KEM_NAME = "ML-KEM-768"
        private const val CIPHERTEXT_SIZE = 1088
        private val INFO = "lattice-vpn/mlkem768-wg-psk/v1".toByteArray(Charsets.US_ASCII)
    }
}
