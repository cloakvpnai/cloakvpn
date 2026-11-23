package ai.latticevpn.android.vpn.cnsa2.tls

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.random.Random

/** The platform's AES-GCM stands in for OpenSSL here, which also cross-checks the packet layout. */
private object JceCrypto : TunnelCrypto {
    override fun seal(key: ByteArray, nonce: ByteArray, ad: ByteArray, plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(ad)
        val out = c.doFinal(plain) // ciphertext then tag
        return out.copyOfRange(out.size - 16, out.size) + out.copyOfRange(0, out.size - 16)
    }

    override fun open(key: ByteArray, nonce: ByteArray, ad: ByteArray, sealed: ByteArray): ByteArray? = try {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(ad)
        c.doFinal(sealed.copyOfRange(16, sealed.size) + sealed.copyOfRange(0, 16))
    } catch (_: Exception) {
        null
    }

    override fun random(length: Int) = ByteArray(length).also { SecureRandom().nextBytes(it) }
}

class WireTest {
    @Test fun controlPacketRoundTrip() {
        val p = ControlPacket(Opcode.CONTROL, 3, ByteArray(8) { 7 }, packetId = 42, payload = byteArrayOf(1, 2, 3))
        val q = ControlPacket.parse(p.encoded())
        assertEquals(Opcode.CONTROL, q.opcode); assertEquals(3, q.keyId)
        assertEquals(42L, q.packetId); assertArrayEquals(byteArrayOf(1, 2, 3), q.payload)

        val ack = ControlPacket(Opcode.ACK, 0, ByteArray(8) { 1 }, listOf(5L, 0xfffffffeL), ByteArray(8) { 2 })
        val back = ControlPacket.parse(ack.encoded())
        assertEquals(listOf(5L, 0xfffffffeL), back.acks); assertArrayEquals(ByteArray(8) { 2 }, back.remoteSessionId); assertNull(back.packetId)
    }

    @Test fun truncatedAndHostilePacketsAreRejected() {
        val good = ControlPacket(Opcode.CONTROL, 0, ByteArray(8) { 7 }, listOf(1L), ByteArray(8) { 9 }, 1, byteArrayOf(9)).encoded()
        for (cut in 0 until good.size - 1) {
            assertTrue("cut at $cut", runCatching { ControlPacket.parse(good.copyOf(cut)) }.exceptionOrNull() is TunnelException)
        }
        val manyAcks = byteArrayOf((Opcode.CONTROL shl 3).toByte()) + ByteArray(8) + byteArrayOf(-1)
        assertTrue(runCatching { ControlPacket.parse(manyAcks) }.exceptionOrNull() is TunnelException)
        assertTrue(runCatching { ControlPacket.parse(byteArrayOf((31 shl 3).toByte()) + ByteArray(9)) }.exceptionOrNull() is TunnelException)
        repeat(2000) {
            val junk = Random.nextBytes(Random.nextInt(0, 81))
            val failure = runCatching { ControlPacket.parse(junk) }.exceptionOrNull()
            assertTrue(failure == null || failure is TunnelException)
        }
    }

    @Test fun dataChannelRoundTripAndTamper() {
        val material = ByteArray(256) { it.toByte() }
        val a = DataKeys(material)
        val b = DataKeys(material.copyOfRange(128, 256) + material.copyOfRange(0, 128)) // the other end
        val packet = DataChannel.seal(JceCrypto, "hello".toByteArray(), a, 2, 77, 9)
        // layout: opcode and key, peer id (3), packet id (4), tag (16), ciphertext
        assertEquals((Opcode.DATA_V2 shl 3) or 2, packet[0].toInt() and 0xff)
        assertArrayEquals(byteArrayOf(0, 0, 77, 0, 0, 0, 9), packet.copyOfRange(1, 8))
        assertEquals(8 + 16 + 5, packet.size)
        val opened = DataChannel.open(JceCrypto, packet, b)
        assertEquals(9L, opened?.first); assertArrayEquals("hello".toByteArray(), opened?.second)
        for (i in packet.indices) {
            val bad = packet.copyOf(); bad[i] = (bad[i].toInt() xor 1).toByte()
            assertNull("byte $i not protected", DataChannel.open(JceCrypto, bad, b))
        }
        assertNull(DataChannel.open(JceCrypto, packet.copyOf(20), b))
        assertNull(DataChannel.open(JceCrypto, packet, a))
    }

    @Test fun replayWindow() {
        val w = ReplayWindow()
        assertFalse(w.accept(0))
        assertTrue(w.accept(1)); assertFalse(w.accept(1))
        assertTrue(w.accept(5)); assertTrue(w.accept(3)); assertFalse(w.accept(3))
        assertTrue(w.accept(200)); assertFalse(w.accept(100)); assertTrue(w.accept(150)); assertFalse(w.accept(150))
    }
}
