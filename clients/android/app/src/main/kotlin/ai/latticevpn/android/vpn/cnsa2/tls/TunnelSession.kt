package ai.latticevpn.android.vpn.cnsa2.tls

import java.io.ByteArrayOutputStream

/** What the gateway assigned to this device. */
data class TunnelSettings(
    var address: String = "",
    var netmask: String = "",
    var gateway: String = "",
    val dns: MutableList<String> = ArrayList(),
    val routes: MutableList<String> = ArrayList(),
    var redirectGateway: Boolean = false,
    var mtu: Int = 1500,
    var pingIntervalMs: Long = 10_000,
    var pingRestartMs: Long = 60_000,
    internal var peerId: Int = 0,
)

/** One negotiation: its own reliable control channel, TLS handshake and data keys. */
internal class KeyState(val keyId: Int, val resetOpcode: Int, identity: TunnelIdentity, val startedAt: Long) {
    class Sent(val opcode: Int, val payload: ByteArray, var sentAt: Long, var wait: Long)

    val tls = TlsSession(identity)

    // reliable control channel
    var nextSendId = 0L
    val queue = ArrayDeque<Pair<Int, ByteArray>>()
    val inflight = HashMap<Long, Sent>()
    var nextReceiveId = 0L
    val receiveBuffer = HashMap<Long, Pair<Int, ByteArray>>()

    // progress
    var peerResetSeen = false
    var tlsDone = false
    var keyExchangeReceived = false
    var keys: DataKeys? = null
    var establishedAt = 0L

    // data channel counters
    var sendPacketId = 0L
    val replay = ReplayWindow()

    init {
        queue.addLast(resetOpcode to ByteArray(0))
    }

    fun close() {
        keys?.wipe()
        tls.close()
    }
}

/**
 * The CNSA 2.0 tunnel client. A plain state machine: the owner feeds it
 * datagrams and clock ticks and sends what it hands back. Not thread safe;
 * call everything from one thread. Mirrors the Apple client's TunnelSession.
 *
 * rekeyIntervalMs: time between full new handshakes started by this device;
 * 0 leaves the timing to the gateway.
 */
class TunnelSession(
    private val identity: TunnelIdentity,
    private val rekeyIntervalMs: Long = 300_000,
    private val crypto: TunnelCrypto = NativeCrypto,
) {
    sealed class State {
        object Idle : State()
        object Connecting : State()
        object Connected : State()
        data class Failed(val reason: String) : State()
        object Closed : State()
    }

    var state: State = State.Idle
        private set
    var settings = TunnelSettings()
        private set
    /** "TLSv1.3 TLS_AES_256_GCM_SHA384 MLKEM1024 mldsa87" for the keys now in use. */
    var suite = ""
        private set
    var rekeyCount = 0
        private set

    /** Datagram to send to the gateway. */
    var send: (ByteArray) -> Unit = {}
    /** IP packet received through the tunnel. */
    var onPacket: (ByteArray) -> Unit = {}
    var onStateChange: (State) -> Unit = {}
    var log: (String) -> Unit = {}

    private val sessionId = crypto.random(8)
    private var remoteSessionId: ByteArray? = null

    private var pending: KeyState? = null
    private var current: KeyState? = null
    private var previous: KeyState? = null

    private var pushReplySeen = false
    private var lastPushRequest = Long.MIN_VALUE / 2
    private var lastSent = 0L
    private var lastReceived = 0L
    private var exitNotify = false

    private val isLive: Boolean get() = state == State.Connecting || state == State.Connected

    // ---- lifecycle ---------------------------------------------------------

    fun start(now: Long) {
        if (state != State.Idle) return
        try {
            val ks = KeyState(0, Opcode.HARD_RESET_CLIENT, identity, now)
            pending = ks
            lastReceived = now
            setState(State.Connecting)
            flush(ks, now)
        } catch (e: TunnelException) {
            fail(e.message ?: "could not start")
        }
    }

    /** Tell the gateway we are leaving, then stop. */
    fun close(now: Long) {
        val ks = current
        if (state == State.Connected && exitNotify && ks != null) {
            try {
                ks.tls.write("EXIT".toByteArray() + 0)
                enqueueTlsOutput(ks)
                flush(ks, now)
            } catch (_: TunnelException) {
            }
        }
        release()
        if (state !is State.Failed) setState(State.Closed)
    }

    private fun release() {
        listOf(pending, current, previous).forEach { it?.close() }
        pending = null; current = null; previous = null
    }

    private fun fail(reason: String) {
        release()
        setState(State.Failed(reason))
    }

    private fun setState(new: State) {
        if (new == state) return
        state = new
        onStateChange(new)
    }

    // ---- input -------------------------------------------------------------

    fun receive(datagram: ByteArray, now: Long) {
        if (!isLive || datagram.isEmpty()) return
        val first = datagram[0].toInt() and 0xff
        val opcode = first ushr 3
        if (opcode == Opcode.DATA_V2 || opcode == Opcode.DATA_V1) {
            receiveData(datagram, first and 7, now)
            return
        }
        try {
            receiveControl(ControlPacket.parse(datagram), now)
        } catch (e: TunnelException) {
            // a malformed or unexpected control packet is dropped, never trusted
            log("dropped control packet: ${e.message}")
        }
    }

    private fun receiveData(datagram: ByteArray, keyId: Int, now: Long) {
        val ks = listOfNotNull(current, previous).firstOrNull { it.keyId == keyId } ?: return
        val keys = ks.keys ?: return
        val (id, plain) = DataChannel.open(crypto, datagram, keys) ?: return
        if (!ks.replay.accept(id)) return
        lastReceived = now
        if (plain.contentEquals(DataChannel.PING)) return
        onPacket(plain)
    }

    private fun keyState(keyId: Int): KeyState? = listOfNotNull(pending, current, previous).firstOrNull { it.keyId == keyId }

    private fun receiveControl(packet: ControlPacket, now: Long) {
        val known = remoteSessionId
        if (known != null) {
            if (!packet.sessionId.contentEquals(known)) throw TunnelException("wrong session")
        } else {
            if (packet.opcode != Opcode.HARD_RESET_SERVER) throw TunnelException("unexpected first packet")
            remoteSessionId = packet.sessionId
        }
        if (packet.acks.isNotEmpty() && packet.remoteSessionId?.contentEquals(sessionId) != true) {
            throw TunnelException("acknowledgement for another session")
        }
        lastReceived = now

        var ks = keyState(packet.keyId)
        if (ks == null) {
            // the gateway is asking for new keys
            if (packet.opcode != Opcode.SOFT_RESET || state != State.Connected || pending != null ||
                packet.keyId == 0 || packet.packetId != 0L) throw TunnelException("no such negotiation")
            ks = KeyState(packet.keyId, Opcode.SOFT_RESET, identity, now)
            pending = ks
            log("gateway requested new keys (key ${packet.keyId})")
        }

        packet.acks.forEach { ks.inflight.remove(it) }

        val id = packet.packetId
        if (id != null) {
            acknowledge(id, ks.keyId)
            if (id >= ks.nextReceiveId && id - ks.nextReceiveId < RECEIVE_AHEAD) {
                ks.receiveBuffer[id] = packet.opcode to packet.payload
            }
            while (true) {
                val (opcode, payload) = ks.receiveBuffer.remove(ks.nextReceiveId) ?: break
                ks.nextReceiveId++
                deliver(opcode, payload, ks)
            }
        }
        try {
            advance(ks, now)
        } catch (e: TunnelException) {
            negotiationFailed(ks, e.message ?: "negotiation failed")
            return
        }
        flush(ks, now)
    }

    private fun acknowledge(id: Long, keyId: Int) {
        val remote = remoteSessionId ?: return
        send(ControlPacket(Opcode.ACK, keyId, sessionId, listOf(id), remote).encoded())
    }

    private fun deliver(opcode: Int, payload: ByteArray, ks: KeyState) {
        when (opcode) {
            Opcode.HARD_RESET_SERVER, Opcode.SOFT_RESET -> ks.peerResetSeen = true
            Opcode.CONTROL -> {
                if (!ks.peerResetSeen) throw TunnelException("data before reset")
                ks.tls.feed(payload)
            }
            else -> throw TunnelException("unexpected control packet")
        }
    }

    // ---- negotiation -------------------------------------------------------

    private fun advance(ks: KeyState, now: Long) {
        if (!ks.peerResetSeen) return
        if (!ks.tlsDone) {
            val done = ks.tls.handshake()
            enqueueTlsOutput(ks)
            if (!done) return
            ks.tlsDone = true
            log("handshake complete: ${ks.tls.summary}")
            ks.tls.write(keyExchangeMessage())
            enqueueTlsOutput(ks)
        }
        for (record in ks.tls.readRecords()) {
            if (!ks.keyExchangeReceived) {
                parseKeyExchange(record)
                ks.keyExchangeReceived = true
            } else {
                handleControlMessage(record)
                if (!isLive) return
            }
        }
        enqueueTlsOutput(ks)
        if (!ks.keyExchangeReceived || ks.keys != null) return
        if (ks.keyId == 0 && !pushReplySeen) {
            if (now - lastPushRequest >= 2_000) {
                lastPushRequest = now
                ks.tls.write("PUSH_REQUEST".toByteArray() + 0)
                enqueueTlsOutput(ks)
            }
            return
        }
        activate(ks, now)
    }

    private fun activate(ks: KeyState, now: Long) {
        val exported = ks.tls.export(DataKeys.EXPORTER_LABEL, DataKeys.EXPORTER_LENGTH)
        ks.keys = DataKeys(exported)
        exported.fill(0)
        ks.establishedAt = now
        val first = current == null
        previous?.close()
        previous = current
        current = ks
        if (pending === ks) pending = null
        suite = ks.tls.summary
        if (first) {
            setState(State.Connected)
        } else {
            rekeyCount++
            log("new keys in use (key ${ks.keyId}, rekey $rekeyCount)")
        }
    }

    private fun negotiationFailed(ks: KeyState, reason: String) {
        if (current == null) {
            fail(reason)
        } else {
            // keep the current keys; the gateway enforces their lifetime
            log("rekey failed: $reason")
            if (pending === ks) pending = null
            ks.close()
        }
    }

    /**
     * The client half of OpenVPN's key method 2 message. With exported keys
     * the random fields are not used for key derivation but are still sent.
     */
    private fun keyExchangeMessage(): ByteArray {
        val m = ByteArrayOutputStream()
        m.write(byteArrayOf(0, 0, 0, 0, 2))
        m.write(crypto.random(48 + 32 + 32))
        m.string("V4,dev-type tun,link-mtu 1549,tun-mtu 1500,proto UDPv4,cipher AES-256-GCM,auth [null-digest],keysize 256,key-method 2,tls-client")
        m.u16(0) // no username
        m.u16(0) // no password
        // IV_PROTO: data v2 (2) + exported keys (8) + exit notification (128)
        m.string("IV_VER=2.6.14\nIV_PLAT=lattice\nIV_PROTO=138\nIV_NCP=2\nIV_CIPHERS=AES-256-GCM\n")
        return m.toByteArray()
    }

    private fun ByteArrayOutputStream.string(s: String) {
        val bytes = s.toByteArray() + 0
        u16(bytes.size)
        write(bytes)
    }

    private fun parseKeyExchange(record: ByteArray) {
        val r = Reader(record)
        if (r.u32() != 0L || r.byte() != 2) throw TunnelException("unexpected key exchange message")
        r.take(64)
        r.take(r.u16())
    }

    private fun handleControlMessage(record: ByteArray) {
        val end = record.indexOf(0).let { if (it < 0) record.size else it }
        val text = String(record, 0, end, Charsets.UTF_8)
        when {
            text.startsWith("PUSH_REPLY") -> if (!pushReplySeen) {
                applyPushReply(text)
                pushReplySeen = true
            }
            text.startsWith("AUTH_FAILED") -> throw TunnelException("gateway refused this device")
            text.startsWith("RESTART") || text.startsWith("HALT") || text.startsWith("EXIT") -> fail("gateway ended the session")
        }
    }

    private fun applyPushReply(text: String) {
        val s = TunnelSettings()
        var exportedKeys = false
        for (option in text.split(",").drop(1)) {
            val parts = option.trim().split(" ").filter { it.isNotEmpty() }
            when (parts.firstOrNull()) {
                "ifconfig" -> if (parts.size >= 3) { s.address = parts[1]; s.netmask = parts[2] }
                "route-gateway" -> if (parts.size >= 2) s.gateway = parts[1]
                "route" -> if (parts.size >= 2) s.routes.add(parts.drop(1).joinToString(" "))
                "redirect-gateway" -> s.redirectGateway = true
                "dhcp-option" -> if (parts.size >= 3 && parts[1] == "DNS") s.dns.add(parts[2])
                "tun-mtu" -> if (parts.size >= 2) s.mtu = parts[1].toIntOrNull() ?: 1500
                "ping" -> if (parts.size >= 2) s.pingIntervalMs = (parts[1].toLongOrNull() ?: 10) * 1000
                "ping-restart" -> if (parts.size >= 2) s.pingRestartMs = (parts[1].toLongOrNull() ?: 60) * 1000
                "peer-id" -> if (parts.size >= 2) s.peerId = parts[1].toIntOrNull() ?: 0
                "cipher" -> if (parts.size >= 2 && parts[1] != "AES-256-GCM") throw TunnelException("gateway chose cipher ${parts[1]}")
                "key-derivation" -> if (parts.size >= 2 && parts[1] == "tls-ekm") exportedKeys = true
                "protocol-flags" -> {
                    if ("tls-ekm" in parts) exportedKeys = true
                    exitNotify = "cc-exit" in parts
                }
                "comp-lzo", "compress" -> throw TunnelException("gateway asked for compression")
            }
        }
        if (!exportedKeys) throw TunnelException("gateway did not agree to TLS-exported keys")
        if (s.address.isEmpty()) throw TunnelException("gateway assigned no address")
        settings = s
    }

    // ---- output ------------------------------------------------------------

    private fun enqueueTlsOutput(ks: KeyState) {
        val out = ks.tls.drain()
        var offset = 0
        while (offset < out.size) {
            val end = minOf(offset + CONTROL_CHUNK, out.size)
            ks.queue.addLast(Opcode.CONTROL to out.copyOfRange(offset, end))
            offset = end
        }
    }

    private fun flush(ks: KeyState, now: Long) {
        while (ks.inflight.size < SEND_WINDOW && ks.queue.isNotEmpty()) {
            val (opcode, payload) = ks.queue.removeFirst()
            val id = ks.nextSendId++
            ks.inflight[id] = KeyState.Sent(opcode, payload, now, 1_000)
            transmit(ks, id, opcode, payload)
        }
    }

    private fun transmit(ks: KeyState, id: Long, opcode: Int, payload: ByteArray) {
        send(ControlPacket(opcode, ks.keyId, sessionId, packetId = id, payload = payload).encoded())
    }

    /** Send one IP packet through the tunnel. */
    fun sendPacket(packet: ByteArray, now: Long) {
        if (state == State.Connected) seal(packet, now)
    }

    private fun seal(plain: ByteArray, now: Long) {
        val ks = current ?: return
        val keys = ks.keys ?: return
        if (ks.sendPacketId >= 0xfffffff0L) return
        ks.sendPacketId++
        val datagram = try {
            DataChannel.seal(crypto, plain, keys, ks.keyId, settings.peerId, ks.sendPacketId)
        } catch (_: TunnelException) {
            return
        }
        lastSent = now
        send(datagram)
    }

    // ---- clock -------------------------------------------------------------

    /** Call a few times a second. */
    fun tick(now: Long) {
        if (!isLive) return
        for (ks in listOfNotNull(pending, current)) {
            for ((id, entry) in ks.inflight) {
                if (now - entry.sentAt >= entry.wait) {
                    entry.sentAt = now
                    entry.wait = minOf(entry.wait * 2, 8_000)
                    transmit(ks, id, entry.opcode, entry.payload)
                }
            }
            try {
                advance(ks, now)
            } catch (e: TunnelException) {
                negotiationFailed(ks, e.message ?: "negotiation failed")
                if (!isLive) return
                continue
            }
            if (!isLive) return
            flush(ks, now)
        }
        pending?.let { if (now - it.startedAt > HANDSHAKE_TIMEOUT_MS) negotiationFailed(it, "handshake timed out") }
        if (state != State.Connected) return
        val ks = current ?: return
        if (now - lastReceived > settings.pingRestartMs) {
            fail("gateway stopped answering")
            return
        }
        if (now - lastSent >= settings.pingIntervalMs) seal(DataChannel.PING, now)
        if (rekeyIntervalMs > 0 && pending == null && now - ks.establishedAt >= rekeyIntervalMs) {
            val next = if (ks.keyId >= 7) 1 else ks.keyId + 1
            try {
                val fresh = KeyState(next, Opcode.SOFT_RESET, identity, now)
                pending = fresh
                flush(fresh, now)
            } catch (e: TunnelException) {
                log("rekey could not start: ${e.message}")
            }
        }
    }

    private companion object {
        const val SEND_WINDOW = 4
        const val CONTROL_CHUNK = 1100
        const val HANDSHAKE_TIMEOUT_MS = 30_000L
        const val RECEIVE_AHEAD = 32L
    }
}
