package ai.latticevpn.android.vpn

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException

/** UDP transport failures surfaced to the rotation loop. */
class RosenpassTransportException(message: String, cause: Throwable? = null) :
    Exception(message, cause)

/**
 * UDP transport for the Rosenpass handshake — a plain [DatagramSocket]
 * to the concentrator's Rosenpass listener (`<region>.cloakvpn.ai:9999`).
 *
 * ## Why this is a plain, *un-protected* socket
 *
 * The iOS client relays Rosenpass UDP through its NetworkExtension
 * process and carves the Rosenpass server IP out of the tunnel
 * (`excludedRoutes`). It has to: under `includeAllNetworks = true`,
 * iOS's NECP forbids host-app sockets from bypassing the tunnel.
 *
 * Android's constraints are different. The tunnel is driven by
 * wireguard-android's `GoBackend`, which owns its own `VpnService`.
 * Only that service can `protect()` a socket, and it is not exposed to
 * app code — so we cannot make this socket bypass the tunnel.
 *
 * Instead, this socket deliberately routes *through* the tunnel:
 *
 *   - Rosenpass packets are addressed to the concentrator's public IP
 *     on UDP/9999.
 *   - Under full-tunnel routing (`AllowedIPs = 0.0.0.0/0, ::/0`) that
 *     traffic is encrypted and delivered to the concentrator over
 *     WireGuard.
 *   - The concentrator receives a packet destined to one of its own
 *     local addresses and delivers it to the Rosenpass listener
 *     locally. The reply travels back through the tunnel.
 *
 * This is correct and robust on a standard Linux WireGuard concentrator,
 * needs no native changes, and avoids the fragile route of reflecting
 * into `GoBackend`'s private `VpnService`. The only cost is that the
 * first rotation cannot run until the WireGuard tunnel is up — which is
 * already true on iOS too (Rosenpass refines an already-classical
 * tunnel; WireGuard works without a PSK in the meantime).
 *
 * ## Lifecycle
 *
 * One-shot, single-handshake. The rotation loop builds a fresh
 * transport for each handshake and [close]s it afterwards — exactly as
 * the iOS `RosenpassDriver` opens and closes its `NWConnection` per
 * handshake. A fresh ephemeral source port plus an empty receive buffer
 * each time prevents a stale datagram from a previous handshake being
 * consumed by the next one and failing session-ID validation.
 *
 * All methods are blocking and must be called off the main thread.
 */
class RosenpassTransport(private val host: String, private val port: Int) {

    private var socket: DatagramSocket? = null
    private var remote: InetSocketAddress? = null

    /**
     * Resolve [host] and open a fresh UDP socket. Any prior socket on
     * this instance is closed first.
     *
     * The socket is deliberately left **unconnected**. The Cloak
     * concentrator receives the handshake addressed to its *public* IP
     * (the packet travels inside the WireGuard tunnel), but the Linux
     * kernel sources the *reply* from the server's wg0 address
     * (10.99.0.1) — the route back to the client — not the public IP.
     * A `connect()`-ed [DatagramSocket] only accepts datagrams from the
     * exact peer it dialed, so it silently drops that reply and every
     * handshake times out (the symptom debugged on 2026-05-23). An
     * unconnected socket accepts the reply whatever its source address;
     * Rosenpass's own cryptographic session validation is the real
     * authentication, so source-IP filtering here would add nothing.
     */
    fun connect() {
        close()
        try {
            val addr = InetAddress.getByName(host)
            remote = InetSocketAddress(addr, port)
            socket = DatagramSocket() // binds a fresh ephemeral local port
        } catch (e: Exception) {
            throw RosenpassTransportException("failed to open UDP socket to $host:$port", e)
        }
    }

    /** Send one Rosenpass datagram to the configured server endpoint. */
    fun send(data: ByteArray) {
        val s = socket ?: throw RosenpassTransportException("transport not connected")
        val dest = remote ?: throw RosenpassTransportException("transport not connected")
        try {
            s.send(DatagramPacket(data, data.size, dest))
        } catch (e: Exception) {
            throw RosenpassTransportException("UDP send failed", e)
        }
    }

    /**
     * Block for up to [timeoutSeconds] (clamped to 1..255) waiting for a
     * single inbound Rosenpass datagram. Throws
     * [RosenpassTransportException] on timeout so the rotation loop's
     * exponential backoff handles it uniformly with other failures.
     */
    fun receive(timeoutSeconds: Int): ByteArray {
        val s = socket ?: throw RosenpassTransportException("transport not connected")
        val clamped = timeoutSeconds.coerceIn(1, 255)
        return try {
            s.soTimeout = clamped * 1000
            val buf = ByteArray(MAX_DATAGRAM)
            val packet = DatagramPacket(buf, buf.size)
            s.receive(packet)
            buf.copyOf(packet.length)
        } catch (e: SocketTimeoutException) {
            throw RosenpassTransportException("UDP receive timed out after ${clamped}s", e)
        } catch (e: Exception) {
            throw RosenpassTransportException("UDP receive failed", e)
        }
    }

    /** Close the underlying socket. Idempotent and never throws. */
    fun close() {
        socket?.let { runCatching { it.close() } }
        socket = null
    }

    companion object {
        // Generous enough for any Rosenpass datagram (the large McEliece
        // public keys are exchanged out-of-band at provisioning time;
        // handshake messages only carry small KEM ciphertexts).
        private const val MAX_DATAGRAM = 65535
    }
}
