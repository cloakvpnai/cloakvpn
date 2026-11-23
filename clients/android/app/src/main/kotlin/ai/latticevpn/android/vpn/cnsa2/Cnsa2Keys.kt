package ai.latticevpn.android.vpn.cnsa2

import org.bouncycastle.asn1.DERBitString
import org.bouncycastle.asn1.DEROctetString
import org.bouncycastle.asn1.DERSet
import org.bouncycastle.asn1.DERTaggedObject
import org.bouncycastle.asn1.nist.NISTObjectIdentifiers
import org.bouncycastle.asn1.pkcs.CertificationRequest
import org.bouncycastle.asn1.pkcs.CertificationRequestInfo
import org.bouncycastle.asn1.pkcs.PrivateKeyInfo
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.AlgorithmIdentifier
import org.bouncycastle.crypto.AsymmetricCipherKeyPair
import org.bouncycastle.pqc.crypto.mldsa.MLDSAKeyGenerationParameters
import org.bouncycastle.pqc.crypto.mldsa.MLDSAKeyPairGenerator
import org.bouncycastle.pqc.crypto.mldsa.MLDSAParameters
import org.bouncycastle.pqc.crypto.mldsa.MLDSAPrivateKeyParameters
import org.bouncycastle.pqc.crypto.mldsa.MLDSAPublicKeyParameters
import org.bouncycastle.pqc.crypto.mldsa.MLDSASigner
import org.bouncycastle.pqc.crypto.util.SubjectPublicKeyInfoFactory
import java.security.SecureRandom

/**
 * The device's CNSA 2.0 identity key: ML-DSA-87 (FIPS 204).
 *
 * The whole key is derived from a 32 byte seed, so the seed is the only
 * secret that has to be kept. Nothing here touches Android, which keeps it
 * testable on the build machine.
 */
object Cnsa2Keys {
    const val SEED_BYTES = 32

    private val ALGORITHM = AlgorithmIdentifier(NISTObjectIdentifiers.id_ml_dsa_87)

    fun newSeed(): ByteArray = ByteArray(SEED_BYTES).also { SecureRandom().nextBytes(it) }

    /** Public key as an X.509 SubjectPublicKeyInfo. */
    fun publicKeyInfo(seed: ByteArray): ByteArray =
        SubjectPublicKeyInfoFactory.createSubjectPublicKeyInfo(keyPair(seed).public).encoded

    /**
     * PKCS#8 in the seed-only form: the private key field holds
     * [0] IMPLICIT OCTET STRING (the seed). Read by OpenSSL 3.5 and later.
     */
    fun pkcs8(seed: ByteArray): ByteArray {
        requireSeed(seed)
        return PrivateKeyInfo(ALGORITHM, DERTaggedObject(false, 0, DEROctetString(seed))).encoded
    }

    /** PKCS#10 certificate request for [commonName], signed with the key. */
    fun certificateRequest(seed: ByteArray, commonName: String): ByteArray {
        require(commonName.matches(Regex("[A-Za-z0-9._-]{1,64}"))) { "invalid name" }
        val pair = keyPair(seed)
        val info = CertificationRequestInfo(
            X500Name("CN=$commonName"),
            SubjectPublicKeyInfoFactory.createSubjectPublicKeyInfo(pair.public),
            DERSet(),
        )
        val signature = sign(pair.private as MLDSAPrivateKeyParameters, info.getEncoded("DER"))
        return CertificationRequest(info, ALGORITHM, DERBitString(signature)).getEncoded("DER")
    }

    fun sign(key: MLDSAPrivateKeyParameters, message: ByteArray): ByteArray {
        val signer = MLDSASigner()
        signer.init(true, key)
        signer.update(message, 0, message.size)
        return signer.generateSignature()
    }

    fun verify(key: MLDSAPublicKeyParameters, message: ByteArray, signature: ByteArray): Boolean {
        val signer = MLDSASigner()
        signer.init(false, key)
        signer.update(message, 0, message.size)
        return signer.verifySignature(signature)
    }

    fun keyPair(seed: ByteArray): AsymmetricCipherKeyPair {
        requireSeed(seed)
        val generator = MLDSAKeyPairGenerator()
        generator.init(MLDSAKeyGenerationParameters(SeedOnce(seed), MLDSAParameters.ml_dsa_87))
        return generator.generateKeyPair()
    }

    private fun requireSeed(seed: ByteArray) = require(seed.size == SEED_BYTES) { "seed must be 32 bytes" }

    /** Hands the key generator exactly the seed, once, and nothing else. */
    private class SeedOnce(private val seed: ByteArray) : SecureRandom() {
        private var used = false
        override fun nextBytes(bytes: ByteArray) {
            check(!used && bytes.size == seed.size) { "unexpected randomness request" }
            used = true
            seed.copyInto(bytes)
        }
    }
}
