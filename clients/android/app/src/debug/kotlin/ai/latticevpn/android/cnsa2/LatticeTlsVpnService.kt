package ai.latticevpn.android.cnsa2

import ai.latticevpn.android.vpn.cnsa2.Cnsa2Config
import ai.latticevpn.android.vpn.cnsa2.Cnsa2IdentityStore
import ai.latticevpn.android.vpn.cnsa2.Cnsa2State
import ai.latticevpn.android.vpn.cnsa2.tls.TunnelException
import ai.latticevpn.android.vpn.cnsa2.tls.TunnelIdentity
import ai.latticevpn.android.vpn.cnsa2.tls.TunnelSession
import ai.latticevpn.android.vpn.cnsa2.tls.TunnelSettings
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Runs the CNSA 2.0 tunnel (TLS 1.3 client in vpn/cnsa2/tls) as a VPN service.
 * Debug builds only until there is a production gateway.
 *
 * The TUN device stays in place for as long as the mode is on. While the
 * tunnel is down its packets are dropped, so nothing leaves outside the tunnel.
 */
class LatticeTlsVpnService : VpnService() {

    /** Every call into the session happens on this one thread. */
    private val engine = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "cnsa2-engine") }

    private var config: Cnsa2Config? = null
    private var running = false
    private var session: TunnelSession? = null
    private var socket: DatagramSocket? = null
    private var ticker: ScheduledFuture<*>? = null
    private var retry: ScheduledFuture<*>? = null
    private var retryDelay = RETRY_FIRST_MS
    private var generation = 0
    private var sessionKey: ByteArray? = null

    private var tun: ParcelFileDescriptor? = null
    private var tunOut: FileOutputStream? = null
    private var tunSettings: TunnelSettings? = null

    private var network: Network? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> engine.execute { stop(null) }
            ACTION_START -> {
                showNotification("Connecting") // promptly after startForegroundService()
                val json = intent.getStringExtra(EXTRA_CONFIG)
                engine.execute {
                    try {
                        start(Cnsa2Config.parse(json ?: throw TunnelException("no gateway settings")))
                    } catch (e: Exception) {
                        stop(e.message ?: "bad gateway settings")
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        engine.execute { stop(null) }
    }

    override fun onDestroy() {
        engine.execute { stop(null) }
        engine.shutdown()
        super.onDestroy()
    }

    // ---- everything below runs on the engine thread ------------------------

    private fun start(cfg: Cnsa2Config) {
        if (running) return
        running = true
        config = cfg
        retryDelay = RETRY_FIRST_MS
        File(filesDir, STATUS_FILE).delete()
        report("starting")
        publish(Cnsa2State.CONNECTING)
        watchNetwork()
        connect()
    }

    private fun connect() {
        val cfg = config ?: return
        if (!running) return
        val mine = ++generation
        try {
            val store = Cnsa2IdentityStore(this)
            val certificate = store.certificate() ?: throw PermanentFailure("This device is not enrolled")
            val key = store.privateKeyPkcs8()
            val identity = TunnelIdentity(cfg.caDer, certificate, key, cfg.gatewayId)

            val s = DatagramSocket()
            if (!protect(s)) throw TunnelException("could not protect the socket")
            s.connect(InetSocketAddress(InetAddress.getByName(cfg.host), cfg.port))
            socket = s

            // every re-key is a new handshake, so the key is needed for as long as the session lives
            sessionKey = key
            val t = TunnelSession(identity, cfg.rekeySeconds * 1000L)
            t.send = { datagram ->
                try {
                    s.send(DatagramPacket(datagram, datagram.size))
                } catch (_: Exception) {
                    // no route right now; the keepalive timeout decides
                }
            }
            t.onPacket = { packet ->
                try {
                    tunOut?.write(packet)
                } catch (_: Exception) {
                }
            }
            t.log = { report(it) }
            t.onStateChange = { state -> if (mine == generation) onSessionState(t, state) }
            session = t

            Thread({ receiveLoop(s, t, mine) }, "cnsa2-receive").start()
            ticker = engine.scheduleWithFixedDelay({ if (mine == generation) t.tick(now()) }, TICK_MS, TICK_MS, TimeUnit.MILLISECONDS)
            t.start(now())
        } catch (e: PermanentFailure) {
            stop(e.message)
        } catch (e: Exception) {
            dropConnection()
            scheduleRetry(e.message ?: "could not connect")
        }
    }

    private fun receiveLoop(s: DatagramSocket, t: TunnelSession, mine: Int) {
        val buffer = ByteArray(65536)
        val packet = DatagramPacket(buffer, buffer.size)
        try {
            while (true) {
                packet.setLength(buffer.size)
                s.receive(packet)
                val data = buffer.copyOf(packet.length)
                engine.execute { if (mine == generation) t.receive(data, now()) }
            }
        } catch (_: Exception) {
            // socket closed
        }
    }

    private fun onSessionState(t: TunnelSession, state: TunnelSession.State) {
        when (state) {
            is TunnelSession.State.Connected -> {
                if (!establishTun(t.settings)) {
                    stop("Android refused the VPN interface")
                    return
                }
                retryDelay = RETRY_FIRST_MS
                report("connected ${t.suite} address ${t.settings.address}")
                publish(Cnsa2State.CONNECTED)
                showNotification("Connected with the CNSA 2.0 suite")
            }
            is TunnelSession.State.Failed -> {
                dropConnection()
                if (PERMANENT.any { state.reason.contains(it, ignoreCase = true) }) stop(state.reason)
                else scheduleRetry(state.reason)
            }
            else -> {}
        }
    }

    private fun scheduleRetry(reason: String) {
        if (!running || retry != null) return
        val delay = retryDelay
        retryDelay = minOf(retryDelay * 2, RETRY_MAX_MS)
        report("down: $reason; retrying in ${delay / 1000}s")
        publish(Cnsa2State.RECONNECTING)
        showNotification("Reconnecting. Traffic is blocked until the tunnel is back.")
        retry = engine.schedule({
            retry = null
            connect()
        }, delay, TimeUnit.MILLISECONDS)
    }

    /** The path changed under us: reconnect at once instead of waiting for the keepalive to notice. */
    private fun networkChanged() {
        if (!running || tunSettings == null) return
        report("network changed")
        session?.close(now())
        dropConnection()
        retry?.cancel(false)
        retry = null
        retryDelay = RETRY_FIRST_MS
        publish(Cnsa2State.RECONNECTING)
        connect()
    }

    private fun dropConnection() {
        generation++
        ticker?.cancel(false)
        ticker = null
        session = null
        sessionKey?.fill(0)
        sessionKey = null
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
    }

    private fun stop(failure: String?) {
        if (!running && failure == null) return
        running = false
        retry?.cancel(false)
        retry = null
        session?.close(now())
        dropConnection()
        unwatchNetwork()
        closeTun()
        report(if (failure == null) "stopped" else "failed: $failure")
        if (failure == null) publish(Cnsa2State.OFF) else publish(Cnsa2State.FAILED, failure)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION") stopForeground(true)
        }
        stopSelf()
    }

    // ---- TUN device --------------------------------------------------------

    private fun establishTun(s: TunnelSettings): Boolean {
        if (tun != null && tunSettings == s) return true
        return try {
            val prefix = prefixLength(s.netmask)
            val b = Builder().setSession("Lattice VPN: CNSA 2.0").setMtu(minOf(s.mtu, TUN_MTU)).setBlocking(true)
            b.addAddress(s.address, prefix)
            if (s.redirectGateway) b.addRoute("0.0.0.0", 0) else b.addRoute(network(s.address, prefix), prefix)
            for (route in s.routes) {
                val parts = route.split(" ")
                val bits = prefixLength(parts.getOrElse(1) { "255.255.255.255" })
                b.addRoute(network(parts[0], bits), bits)
            }
            s.dns.forEach { b.addDnsServer(it) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) b.setMetered(false)
            val fresh = b.establish() ?: return false
            closeTun()
            tun = fresh
            tunOut = FileOutputStream(fresh.fileDescriptor)
            tunSettings = s
            Thread({ tunLoop(fresh) }, "cnsa2-tun").start()
            true
        } catch (e: Exception) {
            Log.e(TAG, "TUN device failed", e)
            false
        }
    }

    /** Reads outgoing packets for as long as the device exists; they are dropped unless the tunnel is up. */
    private fun tunLoop(device: ParcelFileDescriptor) {
        val buffer = ByteArray(65536)
        try {
            FileInputStream(device.fileDescriptor).use { input ->
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    if (n == 0) continue
                    val packet = buffer.copyOf(n)
                    engine.execute { session?.sendPacket(packet, now()) }
                }
            }
        } catch (_: Exception) {
            // device closed
        }
    }

    private fun closeTun() {
        try {
            tun?.close()
        } catch (_: Exception) {
        }
        tun = null; tunOut = null; tunSettings = null
    }

    private fun prefixLength(netmask: String): Int =
        InetAddress.getByName(netmask).address.sumOf { Integer.bitCount(it.toInt() and 0xff) }

    private fun network(address: String, prefix: Int): String {
        val a = InetAddress.getByName(address).address
        val value = ((a[0].toLong() and 0xff) shl 24) or ((a[1].toLong() and 0xff) shl 16) or ((a[2].toLong() and 0xff) shl 8) or (a[3].toLong() and 0xff)
        val masked = if (prefix == 0) 0L else value and (0xffffffffL shl (32 - prefix) and 0xffffffffL)
        return "${masked ushr 24 and 0xff}.${masked ushr 16 and 0xff}.${masked ushr 8 and 0xff}.${masked and 0xff}"
    }

    // ---- network changes ---------------------------------------------------

    private fun watchNetwork() {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(available: Network) {
                engine.execute {
                    val previous = network
                    network = available
                    if (previous != available && (previous != null || retry != null)) networkChanged()
                }
            }

            override fun onLost(lost: Network) {
                engine.execute { if (network == lost) network = null }
            }
        }
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        try {
            manager.registerBestMatchingNetworkCallbackCompat(request, callback)
            networkCallback = callback
        } catch (e: Exception) {
            Log.w(TAG, "network watch unavailable", e)
        }
    }

    private fun ConnectivityManager.registerBestMatchingNetworkCallbackCompat(request: NetworkRequest, callback: ConnectivityManager.NetworkCallback) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            registerBestMatchingNetworkCallback(request, callback, android.os.Handler(mainLooper))
        } else {
            registerNetworkCallback(request, callback)
        }
    }

    private fun unwatchNetwork() {
        val callback = networkCallback ?: return
        networkCallback = null
        network = null
        try {
            getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(callback)
        } catch (_: Exception) {
        }
    }

    // ---- reporting ---------------------------------------------------------

    private fun now(): Long = SystemClock.elapsedRealtime()

    private fun report(text: String) {
        Log.i(TAG, text)
        try {
            File(filesDir, STATUS_FILE).appendText("${System.currentTimeMillis() / 1000} $text\n")
        } catch (_: Exception) {
        }
    }

    private fun publish(newState: Cnsa2State, reason: String? = null) {
        _detail.value = reason
        _state.value = newState
    }

    private fun showNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // The connection status is always showing while the tunnel is up, so it must
            // not put an unread badge on the app icon. A channel's badge setting cannot be
            // changed once created, hence the new channel id and removal of the old one.
            manager.deleteNotificationChannel(OLD_CHANNEL)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "VPN connection", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("Lattice VPN: CNSA 2.0 mode")
            .setContentText(text)
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "foreground notification failed", e)
        }
    }

    private class PermanentFailure(message: String) : Exception(message)

    companion object {
        private val _state = MutableStateFlow(Cnsa2State.OFF)
        private val _detail = MutableStateFlow<String?>(null)
        val state: StateFlow<Cnsa2State> = _state.asStateFlow()
        val detail: StateFlow<String?> = _detail.asStateFlow()

        const val ACTION_START = "ai.latticevpn.android.cnsa2.START"
        const val ACTION_STOP = "ai.latticevpn.android.cnsa2.STOP"
        const val EXTRA_CONFIG = "config"
        const val STATUS_FILE = "cnsa2-status.txt"
        private const val TAG = "LatticeCNSA2"
        private const val CHANNEL = "cnsa2_status"
        private const val OLD_CHANNEL = "cnsa2"
        private const val NOTIFICATION_ID = 7702
        private const val RETRY_FIRST_MS = 1000L
        private const val RETRY_MAX_MS = 30000L
        private const val TICK_MS = 200L
        private const val TUN_MTU = 1400

        /** Failures that trying again cannot fix. */
        private val PERMANENT = listOf("certificate rejected", "refused this device", "outside the CNSA", "chose cipher",
            "compression", "did not agree", "device certificate", "device key")
    }
}
