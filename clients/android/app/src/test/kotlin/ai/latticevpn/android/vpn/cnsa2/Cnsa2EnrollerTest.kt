package ai.latticevpn.android.vpn.cnsa2

import ai.latticevpn.android.data.Cnsa2Gateway
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

    @Test fun renewalWindowIsTheLastTenDays() {
        val day = 24L * 60 * 60 * 1000
        val expiry = 30 * day
        assertFalse(Cnsa2Enroller.isDue(null, expiry))
        assertFalse(Cnsa2Enroller.isDue(expiry, 0))
        assertFalse(Cnsa2Enroller.isDue(expiry, 20 * day - 1))
        assertTrue(Cnsa2Enroller.isDue(expiry, 20 * day))
        assertTrue(Cnsa2Enroller.isDue(expiry, 29 * day))
        assertTrue("an expired certificate is still renewed", Cnsa2Enroller.isDue(expiry, 31 * day))
    }

    @Test fun gatewayFollowsTheRegion() {
        val mx = Cnsa2Gateway("mx1", "198.51.100.1", 1194, "mx1.gw.example")
        val dallas = Cnsa2Gateway("us-central-1", "198.51.100.2", 1194, "us-central-1.gw.example")
        val all = listOf(mx, dallas)
        assertEquals(dallas, Cnsa2Enroller.choose(all, "us-central-1"))
        assertEquals(mx, Cnsa2Enroller.choose(all, "mx1"))
        assertEquals("no region chosen: first offered", mx, Cnsa2Enroller.choose(all, null))
        assertNull("a region without a gateway gets none, not a substitute", Cnsa2Enroller.choose(all, "fi1"))
        assertNull(Cnsa2Enroller.choose(emptyList(), null))
    }
}
