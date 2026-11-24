package ai.latticevpn.android.vpn.cnsa2

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Base64

class Cnsa2EnrollerTest {
    @Test fun expiryParsesServerFormat() {
        // 2026-12-24T09:34:11Z
        assertEquals(1798104851000L, Cnsa2Enroller.parseExpiry("2026-12-24T09:34:11Z"))
    }

    @Test fun expiryRejectsAnythingElse() {
        for (bad in listOf("", "tomorrow", "2026-12-24", "2026-13-40T99:99:99Z", "2026-12-24T09:34:11+01:00")) {
            assertNull(bad, Cnsa2Enroller.parseExpiry(bad))
        }
    }

    @Test fun rootPinRejectsOtherCertificates() {
        assertFalse(Cnsa2Enroller.isLatticeRoot(ByteArray(0)))
        assertFalse(Cnsa2Enroller.isLatticeRoot(ByteArray(7592) { 0x30 }))
    }

    @Test fun rootPinAcceptsTheLatticeRoot() {
        // The root certificate kept in the repository, as signed in AWS KMS on Nov 23, 2026.
        val pem = File("../../../server/cnsa2-ca/certs/root-ca.pem").readText()
        val der = Base64.getDecoder().decode(pem.lines().filterNot { it.startsWith("-----") }.joinToString(""))
        assertTrue(Cnsa2Enroller.isLatticeRoot(der))
        der[der.size - 1] = (der[der.size - 1].toInt() xor 1).toByte()
        assertFalse(Cnsa2Enroller.isLatticeRoot(der))
    }
}
