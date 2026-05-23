package ai.latticevpn.android.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException

/** UDP transport failures surfaced to the rotation loop. */
class RosenpassTransportException(message: String, cause: Throwable? = null) :
    Exception(message, cause)

/**
 * UDP transport for the Rosenpass handshake — a [DatagramSocket] to the
 * concentrator's Rosenpass listener (`<region>:9999`).
 *
 * ## The socket is routed OUTSIDE the WireGuard tunnel
 *
 * The Rosenpass handshake must not depend on the health of the WireGuard
 * tunnel. If it travelled *inside* the tunnel (the pre-2026-05-23
 * behaviour) a PSK desync would black the tunnel and trap the very
 * handshake that would re-key and recover it — a circular dependency
 * that made live PSK rotation deadlock.
 *
 * So [connect] binds this socket to the device's underlying physical
 * network (WiFi / cellular) via [ConnectivityManager] — the Android
 * analogue of the iOS client's `excludedRoutes`. Handshake packets then
 * go straight to the concentrator's public `:9999` listener, bypassing
 * the tunnel, so a rotation always completes regardless of tunnel state
 * and a desync self-heals on the next cycle. DNS for [host] is resolved
 * on that same underlying network. If no non-VPN network is found the
 * socket is left unbound and falls back to the in-tunnel path.
 *
 * This leaks no new metadata: an observer already sees the device
 * talking to the concentrator's public IP for WireGuard transport
 * (`:51820`); a Rosenpass `:9999` flow to the same host adds nothing.
 *
 * ## Why the socket is left *unconnected*
 *
 * The socket is deliberately not `connect()`-ed. The Cloak concentrator
 * receives the handshake addressed to its public IP, but the Linux
 * kernel may source the *reply* from a different local address. A
 * `connect()`-ed [DatagramSocket] only accepts datagrams from the exact
 * peer it dialed, so it would silently drop that reply and every
 * handshake would time out (the symptom debugged on 2026-05-23). An
 * unconnected socket accepts the reply whatever its source address;
 * Rosenpass's own cryptographic session validation is the real
 * authentication, so source-IP filtering here would add nothing.
 *
 * ## Lifecycle
 *
 * One-shot, single-handshake. The rotation loop builds a fresh transport
 * for each handshake and [close]s it afterwards. A fresh ephemeral
 * source port plus an empty receive buffer each time prevents a stale
 * datagram from a previous handshake being consumed by the next one.
 *
 * All methods are blocking and must be called off the main thread.
 */
class RosenpassTransport(
    private val context: Context,
    private val host: String,
    private val port: Int,
) {

    private var socket: DatagramSocket? = null
    private var remote: InetSocketAddress? = null

    /**
     * Resolve [host] and open a fresh UDP socket, bound to the underlying
     * non-VPN network so the handshake bypasses the WireGuard tunnel (see
     * the class doc). Any prior socket on this instance is closed first.
     */
    fun connect() {
        close()
        try {
            val underlying = underlyingNonVpnNetwork()
            val addr = resolveHost(host, underlying)
            remote = InetSocketAddress(addr, port)
            val s = DatagramSocket() // binds a fresh ephemeral local port
            if (underlying != null) {
                try {
                    underlying.bindSocket(s)
                    Log.i(TAG, "Rosenpass socket bound to underlying network — out of tunnel")
                } catch (e: Exception) {
                    // The network vanished between query and bind — proceed
                    // unbound rather than fail; the handshake can still work
                    // while the tunnel is healthy.
                    Log.w(TAG, "could not bind Rosenpass socket out of tunnel: ${e.message}")
                }
            } else {
                Log.w(TAG, "no non-VPN network found — Rosenpass socket will use the tunnel")
            }
            socket = s
        } catch (e: Exception) {
            throw RosenpassTransportException("failed to open UDP socket to $host:$port", e)
        }
    }

    /**
     * The device's underlying physical (non-VPN) network with internet,
     * or null if none is available.
     */
    @Suppress("DEPRECATION") // getAllNetworks: still the simplest cross-version query
    private fun underlyingNonVpnNetwork(): Network? {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return null
        return cm.allNetworks.firstOrNull { n ->
            val caps = cm.getNetworkCapabilities(n) ?: return@firstOrNull false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
    }

    /** Resolve [host] on [network] when available, else with the default resolver. */
    private fun resolveHost(host: String, network: Network?): InetAddress =
        if (network != null) {
            try {
                network.getByName(host)
            } catch (e: Exception) {
                InetAddress.getByName(host)
            }
        } else {
            InetAddress.getByName(host)
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
        private const val TAG = "RosenpassTransport"

        // Generous enough for any Rosenpass datagram (the large McEliece
        // public keys are exchanged out-of-band at provisioning time;
        // handshake messages only carry small KEM ciphertexts).
        private const val MAX_DATAGRAM = 65535
    }
}
