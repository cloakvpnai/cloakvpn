/*
 * Lattice VPN: CNSA 2.0 lab service for the strongSwan native engine.
 *
 * The class and method names here are fixed by strongSwan's libandroidbridge,
 * which looks them up by name over JNI. This is a small replacement for the
 * upstream service of the same name: one connection, certificate
 * authentication only, credentials handed in by the app.
 *
 * Links against strongSwan (GPLv2 or later); this file is distributed under
 * the same terms. Debug builds only.
 */
package org.strongswan.android.logic

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.security.PrivateKey
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class CharonVpnService : VpnService() {

    /** One lab connection, as handed over by the app. */
    class Profile(json: JSONObject) {
        val host: String = json.getString("host")
        val port: Int = json.optInt("port", 4500)
        val gatewayId: String = json.getString("gatewayID")
        val clientId: String = json.getString("clientID")
        val caDer: ByteArray = Base64.decode(json.getString("caDER"), Base64.DEFAULT)
        val clientCertDer: ByteArray = Base64.decode(json.getString("clientCertDER"), Base64.DEFAULT)
        val clientKeyPkcs8: ByteArray = Base64.decode(json.getString("clientKeyPKCS8"), Base64.DEFAULT)
        val rekeySeconds: Int = json.optInt("rekeySeconds", 300)
    }

    private val builderAdapter = BuilderAdapter()
    private var profile: Profile? = null

    /** All engine start, stop and retry steps run here, never on an engine thread. */
    private val control = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "cnsa2-control") }
    @Volatile private var running = false
    private var engineUp = false
    private var retryDelay = RETRY_FIRST_MS
    private var retryPending: ScheduledFuture<*>? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> control.execute { stopConnection() }
            ACTION_START -> {
                // must be called promptly after startForegroundService()
                showNotification("Connecting")
                val config = intent.getStringExtra(EXTRA_CONFIG)
                if (config != null) {
                    val p = Profile(JSONObject(config))
                    control.execute { startConnection(p) }
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        control.execute { stopConnection() }
    }

    override fun onDestroy() {
        control.execute { stopConnection() }
        control.shutdown()
        super.onDestroy()
    }

    private fun startConnection(p: Profile) {
        if (running) return
        running = true
        profile = p
        retryDelay = RETRY_FIRST_MS
        File(filesDir, LOG_FILE).delete()
        report("starting")
        startEngine()
    }

    private fun startEngine() {
        val p = profile ?: return
        if (!running) return
        val log = File(filesDir, LOG_FILE)
        if (!initializeCharon(builderAdapter, log.absolutePath, filesDir.absolutePath, false, false)) {
            report("error: engine failed to start")
            stopConnection()
            return
        }
        engineUp = true
        initiate(settings(p))
    }

    /**
     * The connection attempt failed for a reason that may pass (network gone,
     * gateway unreachable). Traffic stays blocked while we wait and try again.
     */
    private fun retryConnection() {
        if (!running || retryPending != null) return
        builderAdapter.establishBlocking()
        stopEngine()
        val delay = retryDelay
        retryDelay = minOf(retryDelay * 2, RETRY_MAX_MS)
        report("retrying in ${delay / 1000}s")
        showNotification("Reconnecting. Traffic is blocked until the tunnel is back.")
        retryPending = control.schedule({
            retryPending = null
            startEngine()
        }, delay, TimeUnit.MILLISECONDS)
    }

    private fun stopEngine() {
        if (engineUp) {
            engineUp = false
            deinitializeCharon()
        }
    }

    private fun stopConnection() {
        if (!running) return
        running = false
        retryPending?.cancel(false)
        retryPending = null
        stopEngine()
        builderAdapter.close()
        report("stopped")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION") stopForeground(true)
        }
        stopSelf()
    }

    private fun showNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "VPN connection", NotificationManager.IMPORTANCE_LOW))
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

    /** strongSwan settings format: key="value" lines inside named sections. */
    private fun settings(p: Profile): String {
        fun section(name: String, values: Map<String, String>) =
            values.entries.joinToString("", "$name {\n", "}\n") { (k, v) ->
                k + "=\"" + v.replace("\\", "\\\\").replace("\"", "\\\"") + "\"\n"
            }
        return section("global", mapOf(
            "language" to "en",
            "mtu" to "1400",
            "nat_keepalive" to "20",
            "rsa_pss" to "0",
            "crl" to "0",
            "ocsp" to "0",
        )) + section("connection", mapOf(
            "type" to "ikev2-cert",
            "server" to p.host,
            "port" to p.port.toString(),
            "local_id" to p.clientId,
            "remote_id" to p.gatewayId,
            "certreq" to "1",
            "strict_revocation" to "0",
            "ike_proposal" to IKE_PROPOSAL,
            "esp_proposal" to ESP_PROPOSAL,
            "child_rekey" to p.rekeySeconds.toString(),
        ))
    }

    private fun report(text: String) {
        Log.i(TAG, text)
        try {
            File(filesDir, STATUS_FILE).appendText("${System.currentTimeMillis() / 1000} $text\n")
        } catch (_: Exception) {
        }
    }

    // ---- called by libandroidbridge over JNI -------------------------------

    fun updateStatus(status: Int) {
        when (status) {
            STATE_CHILD_SA_UP -> {
                report("child_sa_up")
                control.execute {
                    retryDelay = RETRY_FIRST_MS
                    builderAdapter.closeBlocking()
                    if (running) showNotification("Connected with the CNSA 2.0 suite")
                }
            }
            // the engine re-establishes a lost tunnel itself and tells us if that fails
            STATE_CHILD_SA_DOWN -> report("child_sa_down")
            STATE_LOOKUP_ERROR, STATE_UNREACHABLE_ERROR, STATE_GENERIC_ERROR -> {
                report(when (status) {
                    STATE_LOOKUP_ERROR -> "error: gateway address lookup failed"
                    STATE_UNREACHABLE_ERROR -> "error: gateway unreachable"
                    else -> "error: generic"
                })
                control.execute { retryConnection() }
            }
            else -> {
                // authentication and certificate failures do not fix themselves
                report(when (status) {
                    STATE_AUTH_ERROR -> "error: authentication failed"
                    STATE_PEER_AUTH_ERROR -> "error: gateway authentication failed"
                    STATE_CERTIFICATE_UNAVAILABLE -> "error: client certificate unavailable"
                    else -> "error: unknown ($status)"
                })
                control.execute { stopConnection() }
            }
        }
    }

    fun updateImcState(value: Int) {}

    fun addRemediationInstruction(xml: String) {}

    private fun getTrustedCertificates(): Array<ByteArray> =
        profile?.let { arrayOf(it.caDer) } ?: emptyArray()

    private fun getUserCertificate(): Array<ByteArray> =
        profile?.let { arrayOf(it.clientCertDer) } ?: emptyArray()

    /** The platform keystore has no ML-DSA, so the key is used natively. */
    private fun getUserKey(): PrivateKey? = null

    private fun getUserKeyEncoded(): ByteArray? = profile?.clientKeyPkcs8

    external fun initializeCharon(builder: BuilderAdapter, logfile: String, appdir: String, byod: Boolean, ipv6: Boolean): Boolean
    external fun deinitializeCharon()
    external fun initiate(config: String)

    /** Collects what the engine wants on the TUN device, then creates it. */
    inner class BuilderAdapter {
        private val addresses = ArrayList<Pair<String, Int>>()
        private val routes = ArrayList<Pair<String, Int>>()
        private val dns = ArrayList<String>()
        private var mtu = 1400
        private var established: Triple<List<Pair<String, Int>>, List<Pair<String, Int>>, Int>? = null
        private var blocking: ParcelFileDescriptor? = null

        @Synchronized fun addAddress(address: String, prefixLength: Int): Boolean {
            addresses.add(address to prefixLength); return true
        }

        @Synchronized fun addRoute(address: String, prefixLength: Int): Boolean {
            routes.add(address to prefixLength); return true
        }

        @Synchronized fun addDnsServer(address: String): Boolean {
            dns.add(address); return true
        }

        @Synchronized fun addSearchDomain(domain: String): Boolean = true

        @Synchronized fun setMtu(value: Int): Boolean {
            mtu = value; return true
        }

        @Synchronized fun establish(): Int {
            val fd = create(addresses, routes, dns, mtu)
            if (fd >= 0) {
                established = Triple(ArrayList(addresses), ArrayList(routes), mtu)
            }
            addresses.clear(); routes.clear(); dns.clear()
            return fd
        }

        @Synchronized fun establishNoDns(): Int {
            val last = established ?: return -1
            return create(last.first, last.second, emptyList(), last.third)
        }

        /**
         * Replace the tunnel with a device that keeps the same addresses and
         * routes but drops everything, so nothing leaves outside the tunnel
         * while the engine is down.
         */
        @Synchronized fun establishBlocking() {
            val last = established ?: return
            if (blocking != null) return
            try {
                val b = Builder().setSession("Lattice CNSA 2.0 lab (blocked)").setMtu(last.third).setBlocking(true)
                last.first.forEach { b.addAddress(it.first, it.second) }
                last.second.forEach { b.addRoute(it.first, it.second) }
                val pfd = b.establish() ?: return
                blocking = pfd
                Thread({
                    try {
                        FileInputStream(pfd.fileDescriptor).use { input ->
                            val buffer = ByteArray(2048)
                            while (input.read(buffer) >= 0) { /* dropped */ }
                        }
                    } catch (_: Exception) {
                    }
                }, "cnsa2-dropper").start()
            } catch (e: Exception) {
                Log.e(TAG, "blocking TUN device failed", e)
            }
        }

        @Synchronized fun closeBlocking() {
            try {
                blocking?.close()
            } catch (_: Exception) {
            }
            blocking = null
        }

        @Synchronized fun close() {
            closeBlocking()
            established = null
        }

        private fun create(addrs: List<Pair<String, Int>>, rts: List<Pair<String, Int>>, servers: List<String>, mtuValue: Int): Int {
            return try {
                val b = Builder().setSession("Lattice CNSA 2.0 lab").setMtu(mtuValue).setBlocking(true)
                addrs.forEach { b.addAddress(it.first, it.second) }
                rts.forEach { b.addRoute(it.first, it.second) }
                servers.forEach { b.addDnsServer(it) }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) b.setMetered(false)
                b.establish()?.detachFd() ?: -1
            } catch (e: Exception) {
                Log.e(TAG, "TUN device failed", e)
                -1
            }
        }
    }

    companion object {
        const val ACTION_START = "ai.latticevpn.android.cnsa2.START"
        const val ACTION_STOP = "ai.latticevpn.android.cnsa2.STOP"
        const val EXTRA_CONFIG = "config"
        const val STATUS_FILE = "cnsa2-status.txt"
        const val LOG_FILE = "cnsa2-charon.log"
        private const val TAG = "LatticeCNSA2"
        private const val CHANNEL = "cnsa2"
        private const val NOTIFICATION_ID = 7702
        private const val RETRY_FIRST_MS = 1000L
        private const val RETRY_MAX_MS = 30000L

        // values of android_vpn_state_t in libandroidbridge
        private const val STATE_CHILD_SA_UP = 1
        private const val STATE_CHILD_SA_DOWN = 2
        private const val STATE_AUTH_ERROR = 3
        private const val STATE_PEER_AUTH_ERROR = 4
        private const val STATE_LOOKUP_ERROR = 5
        private const val STATE_UNREACHABLE_ERROR = 6
        private const val STATE_CERTIFICATE_UNAVAILABLE = 7
        private const val STATE_GENERIC_ERROR = 8

        /** CNSA 2.0 suite, nothing else offered (draft-guthrie-cnsa2-ipsec-profile). */
        const val IKE_PROPOSAL = "aes256gcm16-prfsha384-ecp384-ke1_mlkem1024"
        const val ESP_PROPOSAL = "aes256gcm16-mlkem1024"

        @JvmStatic fun getAndroidVersion(): String =
            "Android ${Build.VERSION.RELEASE} - ${Build.DISPLAY}/${Build.VERSION.SECURITY_PATCH}"

        @JvmStatic fun getDeviceString(): String = "${Build.MODEL} - ${Build.BRAND}/${Build.PRODUCT}/${Build.MANUFACTURER}"

        init {
            System.loadLibrary("androidbridge")
        }
    }
}
