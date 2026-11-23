package ai.latticevpn.android.vpn.cnsa2

import org.bouncycastle.asn1.pkcs.CertificationRequest
import org.bouncycastle.pqc.crypto.mldsa.MLDSAPublicKeyParameters
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class Cnsa2KeysTest {
    private val seed = ByteArray(32) { (it * 7 + 1).toByte() }

    @Test fun sameSeedGivesSameKey() {
        assertArrayEquals(Cnsa2Keys.publicKeyInfo(seed), Cnsa2Keys.publicKeyInfo(seed.copyOf()))
        assertFalse(Cnsa2Keys.publicKeyInfo(seed).contentEquals(Cnsa2Keys.publicKeyInfo(Cnsa2Keys.newSeed())))
    }

    @Test fun publicKeyIsMlDsa87() {
        val key = Cnsa2Keys.keyPair(seed).public as MLDSAPublicKeyParameters
        assertEquals(2592, key.encoded.size) // FIPS 204, ML-DSA-87 public key
    }

    @Test fun pkcs8IsSeedOnly() {
        val der = Cnsa2Keys.pkcs8(seed)
        // ... OCTET STRING (34) { [0] (32) seed }
        val tail = der.copyOfRange(der.size - 36, der.size)
        assertArrayEquals(byteArrayOf(0x04, 0x22, 0x80.toByte(), 0x20) + seed, tail)
    }

    @Test fun requestIsSignedByTheKey() {
        val der = Cnsa2Keys.certificateRequest(seed, "device-test.lattice.lab")
        val request = CertificationRequest.getInstance(der)
        val info = request.certificationRequestInfo
        assertEquals("CN=device-test.lattice.lab", info.subject.toString())
        assertArrayEquals(Cnsa2Keys.publicKeyInfo(seed), info.subjectPublicKeyInfo.encoded)
        val key = Cnsa2Keys.keyPair(seed).public as MLDSAPublicKeyParameters
        val signature = request.signature.bytes
        assertEquals(4627, signature.size) // FIPS 204, ML-DSA-87 signature
        assertTrue(Cnsa2Keys.verify(key, info.getEncoded("DER"), signature))
        val tampered = info.getEncoded("DER").also { it[it.size - 1] = (it[it.size - 1] + 1).toByte() }
        assertFalse(Cnsa2Keys.verify(key, tampered, signature))

        // left for the cross-check against strongSwan and OpenSSL (see strongswan/README)
        System.getProperty("cnsa2.out")?.let { out ->
            File(out).mkdirs()
            File(out, "test.csr.der").writeBytes(der)
            File(out, "test.key.der").writeBytes(Cnsa2Keys.pkcs8(seed))
        }
    }

    @Test(expected = IllegalArgumentException::class) fun rejectsOddNames() {
        Cnsa2Keys.certificateRequest(seed, "a, O=Other")
    }
}
