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

import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.security.PrivateKey

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
    private var worker: Thread? = null
    @Volatile private var running = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopConnection()
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG)
                if (config != null) {
                    startConnection(Profile(JSONObject(config)))
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        stopConnection()
    }

    override fun onDestroy() {
        stopConnection()
        super.onDestroy()
    }

    private fun startConnection(p: Profile) {
        synchronized(this) {
            if (running) return
            running = true
            profile = p
        }
        worker = Thread({
            val log = File(filesDir, LOG_FILE)
            log.delete()
            report("starting")
            if (!initializeCharon(builderAdapter, log.absolutePath, filesDir.absolutePath, false, false)) {
                report("error: engine failed to start")
                running = false
                stopSelf()
                return@Thread
            }
            initiate(settings(p))
        }, "cnsa2-charon").also { it.start() }
    }

    private fun stopConnection() {
        synchronized(this) {
            if (!running) return
            running = false
        }
        Thread({
            deinitializeCharon()
            builderAdapter.close()
            report("stopped")
            stopSelf()
        }, "cnsa2-stop").start()
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
        report(when (status) {
            1 -> "child_sa_up"
            2 -> "child_sa_down"
            3 -> "error: authentication failed"
            4 -> "error: gateway authentication failed"
            5 -> "error: gateway address lookup failed"
            6 -> "error: gateway unreachable"
            7 -> "error: client certificate unavailable"
            else -> "error: generic ($status)"
        })
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

        @Synchronized fun close() {
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
