package ai.latticevpn.android.vpn.cnsa2.tls

import java.io.ByteArrayOutputStream

// The tunnel framing is the OpenVPN wire protocol (control channel carrying
// TLS, AEAD data channel), so the gateway can be a stock OpenVPN 2.6 server.
// This file mirrors clients/apple-tls/Sources/LatticeTLS/Wire.swift.

internal object Opcode {
    const val SOFT_RESET = 3         // P_CONTROL_SOFT_RESET_V1
    const val CONTROL = 4            // P_CONTROL_V1
    const val ACK = 5                // P_ACK_V1
    const val DATA_V1 = 6            // P_DATA_V1
    const val HARD_RESET_CLIENT = 7  // P_CONTROL_HARD_RESET_CLIENT_V2
    const val HARD_RESET_SERVER = 8  // P_CONTROL_HARD_RESET_SERVER_V2
    const val DATA_V2 = 9            // P_DATA_V2

    fun isControl(op: Int) = op == SOFT_RESET || op == CONTROL || op == ACK || op == HARD_RESET_CLIENT || op == HARD_RESET_SERVER
}

internal fun ByteArrayOutputStream.u16(v: Int) { write(v ushr 8 and 0xff); write(v and 0xff) }
internal fun ByteArrayOutputStream.u32(v: Long) {
    write((v ushr 24 and 0xff).toInt()); write((v ushr 16 and 0xff).toInt()); write((v ushr 8 and 0xff).toInt()); write((v and 0xff).toInt())
}

/** Bounds-checked reader. Every parse of gateway input goes through this. */
internal class Reader(private val bytes: ByteArray) {
    private var offset = 0
    val remaining: Int get() = bytes.size - offset

    fun byte(): Int {
        if (remaining < 1) throw TunnelException("truncated packet")
        return bytes[offset++].toInt() and 0xff
    }

    fun u16(): Int = (byte() shl 8) or byte()

    fun u32(): Long = (byte().toLong() shl 24) or (byte().toLong() shl 16) or (byte().toLong() shl 8) or byte().toLong()

    fun take(count: Int): ByteArray {
        if (count < 0 || remaining < count) throw TunnelException("truncated packet")
        return bytes.copyOfRange(offset, offset + count).also { offset += count }
    }

    fun rest(): ByteArray = take(remaining)
}

internal class ControlPacket(
    val opcode: Int,
    val keyId: Int,
    val sessionId: ByteArray,
    val acks: List<Long> = emptyList(),
    val remoteSessionId: ByteArray? = null,
    val packetId: Long? = null,
    val payload: ByteArray = ByteArray(0),
) {
    fun encoded(): ByteArray {
        val out = ByteArrayOutputStream(16 + payload.size)
        out.write((opcode shl 3) or (keyId and 7))
        out.write(sessionId)
        out.write(acks.size)
        acks.forEach { out.u32(it) }
        if (acks.isNotEmpty() && remoteSessionId != null) out.write(remoteSessionId)
        if (packetId != null) out.u32(packetId)
        out.write(payload)
        return out.toByteArray()
    }

    companion object {
        const val MAX_ACKS = 8

        fun parse(datagram: ByteArray): ControlPacket {
            val r = Reader(datagram)
            val first = r.byte()
            val op = first ushr 3
            if (!Opcode.isControl(op)) throw TunnelException("unknown packet type")
            val sessionId = r.take(8)
            val count = r.byte()
            if (count > MAX_ACKS) throw TunnelException("too many acknowledgements")
            val acks = List(count) { r.u32() }
            val remote = if (count > 0) r.take(8) else null
            return if (op == Opcode.ACK) ControlPacket(op, first and 7, sessionId, acks, remote)
            else ControlPacket(op, first and 7, sessionId, acks, remote, r.u32(), r.rest())
        }
    }
}

/** Keys for one direction pair, taken from the TLS exporter. */
internal class DataKeys(exported: ByteArray) {
    val sealKey: ByteArray; val sealIv: ByteArray   // device -> gateway
    val openKey: ByteArray; val openIv: ByteArray   // gateway -> device

    init {
        if (exported.size != EXPORTER_LENGTH) throw TunnelException("bad key material")
        // Two keys, each 64 bytes of cipher key then 64 bytes of HMAC key. AES-256-GCM
        // uses the first 32 cipher bytes, and the first 8 HMAC bytes as the fixed part
        // of the nonce. The client sends with the first key.
        sealKey = exported.copyOfRange(0, 32); sealIv = exported.copyOfRange(64, 72)
        openKey = exported.copyOfRange(128, 160); openIv = exported.copyOfRange(192, 200)
    }

    fun wipe() { sealKey.fill(0); openKey.fill(0) }

    companion object {
        const val EXPORTER_LABEL = "EXPORTER-OpenVPN-datakeys"
        const val EXPORTER_LENGTH = 256
    }
}

/** Sliding window against replayed data packets. */
internal class ReplayWindow {
    private var highest = 0L
    private var seen = 0L

    fun accept(id: Long): Boolean {
        if (id <= 0) return false
        if (id > highest) {
            val shift = id - highest
            seen = if (shift >= 64) 0 else seen shl shift.toInt()
            seen = seen or 1
            highest = id
            return true
        }
        val behind = highest - id
        if (behind >= 64) return false
        val bit = 1L shl behind.toInt()
        if (seen and bit != 0L) return false
        seen = seen or bit
        return true
    }
}

internal object DataChannel {
    /** OpenVPN's keepalive payload. */
    val PING = byteArrayOf(0x2a, 0x18, 0x7b, 0xf3.toByte(), 0x64, 0x1e, 0xb4.toByte(), 0xcb.toByte(),
        0x07, 0xed.toByte(), 0x2d, 0x0a, 0x98.toByte(), 0x1f, 0xc7.toByte(), 0x48)

    fun seal(crypto: TunnelCrypto, plain: ByteArray, keys: DataKeys, keyId: Int, peerId: Int, packetId: Long): ByteArray {
        val header = ByteArrayOutputStream(8)
        header.write((Opcode.DATA_V2 shl 3) or (keyId and 7))
        header.write(peerId ushr 16 and 0xff); header.write(peerId ushr 8 and 0xff); header.write(peerId and 0xff)
        header.u32(packetId)
        val ad = header.toByteArray()
        val nonce = ad.copyOfRange(4, 8) + keys.sealIv
        return ad + crypto.seal(keys.sealKey, nonce, ad, plain)
    }

    /** Packet ID and plaintext, or null if the packet does not authenticate. */
    fun open(crypto: TunnelCrypto, datagram: ByteArray, keys: DataKeys): Pair<Long, ByteArray>? {
        if (datagram.isEmpty()) return null
        val headerLength = if ((datagram[0].toInt() and 0xff) ushr 3 == Opcode.DATA_V2) 4 else 1
        if (datagram.size < headerLength + 4 + 16) return null
        val ad = datagram.copyOfRange(0, headerLength + 4)
        val idBytes = datagram.copyOfRange(headerLength, headerLength + 4)
        val id = Reader(idBytes).u32()
        val plain = crypto.open(keys.openKey, idBytes + keys.openIv, ad, datagram.copyOfRange(headerLength + 4, datagram.size))
            ?: return null
        return id to plain
    }
}
