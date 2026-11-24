package ai.latticevpn.android.vpn.cnsa2

import ai.latticevpn.android.data.AccountClient
import android.content.Context
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import ai.latticevpn.android.data.Cnsa2Gateway
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * Enrolls this device for CNSA 2.0 mode through the account API.
 *
 * The device's ML-DSA-87 key is made here and never leaves the phone. Only a
 * certificate request goes out. What comes back is accepted only if:
 *  - the root certificate is the Lattice root this build was compiled with, and
 *  - the device certificate carries this device's own public key.
 *
 * The certificate lasts 30 days and is renewed from day 20 with the same key.
 */
class Cnsa2Enroller(context: Context, private val api: AccountClient) {
    private val context = context.applicationContext
    private val identity = Cnsa2IdentityStore(this.context)
    private val stateFile = File(this.context.filesDir, "cnsa2/enrollment.json")

    /** True when the device cannot connect without enrolling first. */
    fun needsEnrollment(nowMillis: Long = System.currentTimeMillis()): Boolean {
        if (identity.certificate() == null || Cnsa2Config.load(context) == null) return true
        val expiry = expiryMillis() ?: return true
        return nowMillis >= expiry
    }

    /** True when the certificate still works but is inside the renewal window. */
    fun shouldRenew(nowMillis: Long = System.currentTimeMillis()): Boolean {
        val expiry = expiryMillis() ?: return false
        return nowMillis in (expiry - RENEW_BEFORE_MILLIS) until expiry
    }

    /**
     * Enrolls, or renews with the existing key. Stores the certificate and the
     * gateway to use, and returns that gateway's settings.
     */
    suspend fun enroll(accountNumber: String): Cnsa2Config = lock.withLock { enrollLocked(accountNumber) }

    /** True when a certificate exists and is inside the renewal window or past its expiry. */
    fun renewalDue(nowMillis: Long = System.currentTimeMillis()): Boolean {
        if (identity.certificate() == null) return false
        return isDue(expiryMillis(), nowMillis)
    }

    /**
     * Renews if still due once it holds the lock, so the daily job and the app
     * cannot both renew at the same moment. Returns true if a new certificate was stored.
     */
    suspend fun renewIfDue(accountNumber: String): Boolean = lock.withLock {
        if (!renewalDue()) return@withLock false
        enrollLocked(accountNumber)
        true
    }

    private suspend fun enrollLocked(accountNumber: String): Cnsa2Config {
        // The name in the request is ignored by the server, which names the device itself.
        val request = identity.certificateRequest("lattice-device")
        val reply = api.enrollCnsa2(accountNumber, request)
        if (!isLatticeRoot(reply.root)) {
            throw Cnsa2EnrollmentException("The server's certificate authority is not the one this app trusts.")
        }
        val expiry = parseExpiry(reply.notAfter)
            ?: throw Cnsa2EnrollmentException("The server sent a certificate without a usable expiry.")
        val gateway = reply.gateways.firstOrNull()
            ?: throw Cnsa2EnrollmentException("No CNSA 2.0 gateway is available yet.")
        try {
            identity.storeCertificate(reply.certificate)
        } catch (e: IllegalArgumentException) {
            throw Cnsa2EnrollmentException("The server sent a certificate for a different device.")
        }
        val config = Cnsa2Config(
            host = gateway.host,
            port = gateway.port,
            gatewayId = gateway.name,
            clientId = "",
            caDer = reply.root,
            rekeySeconds = REKEY_SECONDS,
        )
        Cnsa2Config.save(context, config.toJson())
        stateFile.apply { parentFile?.mkdirs() }.writeText(
            JSONObject()
                .put("not_after", reply.notAfter)
                .put("not_after_millis", expiry)
                .put("device_id", reply.deviceId)
                .put("uid", reply.deviceUid)
                .put("gateway", gateway.id)
                .put("gateways", toJson(reply.gateways))
                .toString()
        )
        return config
    }

    /**
     * Sign-out: removes this device from the account (which revokes its certificate on
     * every gateway), then erases the key, the certificate and everything saved here.
     * The local erase happens even if the server cannot be reached; the certificate then
     * simply runs out, and its key no longer exists anywhere.
     */
    suspend fun forget(accountNumber: String) = lock.withLock {
        deviceId()?.let { id -> runCatching { api.removeCnsa2Device(accountNumber, id) } }
        identity.reset()
        stateFile.delete()
        File(context.filesDir, "cnsa2/gateway.json").delete()
    }

    /** The gateways the server offered last time it was asked. */
    fun gateways(): List<Cnsa2Gateway> {
        val arr = state()?.optJSONArray("gateways") ?: return emptyList()
        return (0 until arr.length()).mapNotNull { i ->
            val g = arr.optJSONObject(i) ?: return@mapNotNull null
            Cnsa2Gateway(g.optString("id"), g.optString("host"), g.optInt("port", 1194), g.optString("name"))
                .takeIf { it.host.isNotEmpty() && it.name.isNotEmpty() }
        }
    }

    /** Asks the server for the current gateway list. Nothing else about the enrollment changes. */
    suspend fun refreshGateways(accountNumber: String) {
        val fresh = api.fetchCnsa2Gateways(accountNumber)
        if (fresh.isEmpty()) return
        lock.withLock {
            val current = state() ?: return@withLock
            stateFile.writeText(current.put("gateways", toJson(fresh)).toString())
        }
    }

    /**
     * Settings for the gateway of [regionId], or null when that region has none.
     * With no region chosen, or before the gateway list has ever been fetched, the
     * gateway saved at enrollment is used. There is no silent substitute otherwise.
     */
    fun configFor(regionId: String?): Cnsa2Config? {
        val base = Cnsa2Config.load(context) ?: return null
        val offered = gateways()
        if (offered.isEmpty()) return base
        val gateway = choose(offered, regionId) ?: return null
        return Cnsa2Config(
            host = gateway.host,
            port = gateway.port,
            gatewayId = gateway.name,
            clientId = base.clientId,
            caDer = base.caDer,
            rekeySeconds = base.rekeySeconds,
        )
    }

    private fun toJson(list: List<Cnsa2Gateway>): JSONArray = JSONArray().apply {
        list.forEach { put(JSONObject().put("id", it.id).put("host", it.host).put("port", it.port).put("name", it.name)) }
    }

    /** The server's id for this device, needed to remove it from the account. */
    fun deviceId(): Long? = state()?.optLong("device_id")?.takeIf { it > 0 }

    private fun expiryMillis(): Long? = state()?.optLong("not_after_millis")?.takeIf { it > 0 }

    private fun state(): JSONObject? = try {
        stateFile.takeIf { it.exists() }?.let { JSONObject(it.readText()) }
    } catch (_: Exception) {
        null
    }

    companion object {
        /** SHA-256 of the Lattice VPN CNSA2 Root CA G1 certificate (signed Nov 23, 2026). */
        const val ROOT_SHA256 = "03f0a61239af18dcacf6753422c004d04674e324d7b10baa1b4f9eb49150f5bc"
        const val REKEY_SECONDS = 600
        const val RENEW_BEFORE_MILLIS = 10L * 24 * 60 * 60 * 1000

        /** One at a time across the app and the background job. */
        private val lock = Mutex()

        /** The gateway for a region; with no region chosen, the first one offered. */
        fun choose(gateways: List<Cnsa2Gateway>, regionId: String?): Cnsa2Gateway? =
            if (regionId == null) gateways.firstOrNull() else gateways.firstOrNull { it.id == regionId }

        fun isDue(expiryMillis: Long?, nowMillis: Long): Boolean =
            expiryMillis != null && nowMillis >= expiryMillis - RENEW_BEFORE_MILLIS

        fun isLatticeRoot(der: ByteArray): Boolean {
            val digest = MessageDigest.getInstance("SHA-256").digest(der)
            val hex = digest.joinToString("") { "%02x".format(it) }
            return MessageDigest.isEqual(hex.toByteArray(), ROOT_SHA256.toByteArray())
        }

        /** Parses the server's expiry, for example 2026-12-24T09:34:11Z. */
        fun parseExpiry(text: String): Long? = try {
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
                .apply { timeZone = TimeZone.getTimeZone("UTC"); isLenient = false }
                .parse(text)?.time
        } catch (_: Exception) {
            null
        }
    }
}

class Cnsa2EnrollmentException(message: String) : Exception(message)
