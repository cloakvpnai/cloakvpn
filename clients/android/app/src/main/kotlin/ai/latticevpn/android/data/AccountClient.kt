package ai.latticevpn.android.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Dns
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.net.InetAddress
import java.net.Socket
import java.util.concurrent.TimeUnit
import javax.net.SocketFactory

/**
 * A failure talking to the Lattice account API, classified so the UI can
 * react appropriately (retry vs. re-enter the number vs. renew).
 */
class AccountException(
    message: String,
    val kind: Kind = Kind.OTHER,
) : Exception(message) {
    enum class Kind {
        /** The account number was not recognized (HTTP 401). */
        UNAUTHORIZED,

        /** Recognized, but the subscription is not active (HTTP 402). */
        NO_SUBSCRIPTION,

        /** Every device slot for this subscription is in use (HTTP 403). */
        DEVICE_LIMIT,

        /** The server could not be reached at all. */
        NETWORK,

        /** Anything else (5xx, malformed response, …). */
        OTHER,
    }
}

/** The server's view of a subscription — backs the Account screen. */
data class AccountStatus(
    val tier: String,
    val deviceLimit: Int,
    val deviceCount: Int,
    /** RFC3339 instant the subscription is paid through. */
    val activeUntil: String,
    val devices: List<AccountDevice>,
) {
    /** True when the subscription currently entitles the customer. */
    val isActive: Boolean get() = tier.isNotEmpty()
}

/** One provisioned device in an [AccountStatus]. */
data class AccountDevice(
    val id: Long,
    val ip: String,
    /** RFC3339 instant the device was provisioned. */
    val createdAt: String,
)

/**
 * The WireGuard + Rosenpass material the server returns on provisioning.
 * Mirrors `wg.ClientConfig` on the server (JSON keys are PascalCase, and
 * the private-key fields are intentionally absent — the device keeps its
 * own secrets).
 */
data class ProvisionedConfig(
    val interfacePublicKey: String,
    val interfaceAddress: String,
    val interfaceDNS: String,
    val peerPublicKey: String,
    val peerEndpoint: String,
    val peerAllowedIPs: String,
    val rosenpassPeerPub: String,
    val rosenpassListen: String,
    val rosenpassClientPK: String,
    val assignedIP: String,
)

/** Result of a successful POST /v1/device. */
data class DeviceProvision(
    val config: ProvisionedConfig,
    val tier: String,
    val deviceId: Long,
)

/**
 * Talks to the central Lattice account API ([LatticeApi.BASE_URL]).
 *
 * Every call authenticates with the customer's account number as an
 * `Authorization: Bearer` token — there are no user accounts, JWTs, or
 * bootstrap keys. This replaces the old AuthClient + ProvisioningClient
 * pair.
 */
class AccountClient(private val context: Context) {

    /**
     * The device's underlying physical (non-VPN) network with internet,
     * or null if none is found (then calls fall back to the default
     * route — fine when no tunnel is up).
     */
    @Suppress("DEPRECATION") // getAllNetworks: simplest cross-version query
    private fun underlyingNonVpnNetwork(): Network? {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return null
        return cm.allNetworks.firstOrNull { n ->
            val caps = cm.getNetworkCapabilities(n) ?: return@firstOrNull false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
    }

    /**
     * DNS that resolves on the underlying network, so even the name
     * lookup for the API bypasses the tunnel. Falls back to the system
     * resolver when no non-VPN network is available.
     */
    private val underlyingDns = object : Dns {
        override fun lookup(hostname: String): List<InetAddress> =
            underlyingNonVpnNetwork()?.let { net ->
                runCatching { net.getAllByName(hostname).toList() }.getOrNull()
            } ?: Dns.SYSTEM.lookup(hostname)
    }

    /**
     * SocketFactory whose sockets are bound to the underlying non-VPN
     * network, so OkHttp connections never enter the WireGuard tunnel.
     * Delegates to the default factory when no such network is found.
     */
    private inner class UnderlyingSocketFactory : SocketFactory() {
        private fun delegate(): SocketFactory =
            underlyingNonVpnNetwork()?.socketFactory ?: SocketFactory.getDefault()
        override fun createSocket(): Socket = delegate().createSocket()
        override fun createSocket(host: String, port: Int): Socket =
            delegate().createSocket(host, port)
        override fun createSocket(
            host: String, port: Int, localHost: InetAddress, localPort: Int,
        ): Socket = delegate().createSocket(host, port, localHost, localPort)
        override fun createSocket(host: InetAddress, port: Int): Socket =
            delegate().createSocket(host, port)
        override fun createSocket(
            address: InetAddress, port: Int, localAddress: InetAddress, localPort: Int,
        ): Socket = delegate().createSocket(address, port, localAddress, localPort)
    }

    // Provisioning runs add-peer + a rosenpass restart server-side, so it
    // needs generous read headroom; capped so a hung server cannot block
    // the UI indefinitely.
    //
    // CRITICAL: every call here is pinned to the device's underlying
    // physical network (WiFi / cellular), NOT the WireGuard tunnel. A
    // region switch is POST /v1/device, and the server tears down the
    // *current* tunnel as part of that switch — so a request riding the
    // tunnel would be killed mid-flight (the response can't get back) and
    // the switch could never finish. Pinning the socket out-of-tunnel —
    // the same approach RosenpassTransport uses for the PQ handshake —
    // lets the request survive the very tunnel it is replacing.
    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .socketFactory(UnderlyingSocketFactory())
        .dns(underlyingDns)
        .build()

    /**
     * GET /v1/account — fetch subscription state. Used both to validate
     * an account number at sign-in and to populate the Account screen.
     * Throws [AccountException] (UNAUTHORIZED) if the number is unknown.
     */
    suspend fun fetchAccount(accountNumber: String): AccountStatus =
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url("${LatticeApi.BASE_URL}/v1/account")
                .header("Authorization", bearer(accountNumber))
                .get()
                .build()
            parseAccount(execute(request))
        }

    /**
     * POST /v1/device — register this device as a WireGuard + Rosenpass
     * peer in [region]. Only the device's *public* keys are sent; the
     * private keys are generated on-device and never leave it.
     *
     * The central API routes the peer onto the chosen region's
     * concentrator; switching [region] for a device already provisioned
     * elsewhere tears down the old peer and re-provisions on the new box.
     */
    suspend fun provisionDevice(
        accountNumber: String,
        wgPubkeyB64: String,
        rosenpassPubkeyB64: String,
        region: String,
    ): DeviceProvision = withContext(Dispatchers.IO) {
        val payload = JSONObject()
            .put("wg_pubkey", wgPubkeyB64)
            .put("rosenpass_pubkey", rosenpassPubkeyB64)
            .put("region", region)
            .toString()
        val request = Request.Builder()
            .url("${LatticeApi.BASE_URL}/v1/device")
            .header("Authorization", bearer(accountNumber))
            .post(payload.toRequestBody(JSON))
            .build()
        parseProvision(execute(request))
    }

    /**
     * DELETE /v1/device?id=… — release a device slot, so a customer at
     * their device limit can free one from the Account screen.
     */
    suspend fun revokeDevice(accountNumber: String, deviceId: Long) {
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url("${LatticeApi.BASE_URL}/v1/device?id=$deviceId")
                .header("Authorization", bearer(accountNumber))
                .delete()
                .build()
            execute(request) // 204 No Content — body unused
        }
    }

    // ---- internals ------------------------------------------------------

    private fun bearer(accountNumber: String): String =
        "Bearer " + LatticeApi.formatAccountNumber(accountNumber)

    /**
     * Run [request], returning the response body text on a 2xx, or
     * throwing a classified [AccountException] otherwise.
     */
    private fun execute(request: Request): String {
        val response = try {
            http.newCall(request).execute()
        } catch (e: IOException) {
            throw AccountException(
                "Couldn't reach Lattice. Check your connection and try again.",
                AccountException.Kind.NETWORK,
            )
        }
        response.use {
            val text = it.body?.string().orEmpty()
            if (it.isSuccessful) return text
            throw when (it.code) {
                401 -> AccountException(
                    "That account number wasn't recognized. Check it and try again.",
                    AccountException.Kind.UNAUTHORIZED,
                )
                402 -> AccountException(
                    "This subscription isn't active. Renew it at latticevpn.ai to continue.",
                    AccountException.Kind.NO_SUBSCRIPTION,
                )
                403 -> AccountException(
                    "You've reached your device limit. Remove a device to add this one.",
                    AccountException.Kind.DEVICE_LIMIT,
                )
                else -> AccountException(
                    "Lattice server error (${it.code}). Please try again in a moment.",
                    AccountException.Kind.OTHER,
                )
            }
        }
    }

    private fun parseAccount(body: String): AccountStatus {
        val j = jsonOf(body)
        val devices = mutableListOf<AccountDevice>()
        j.optJSONArray("devices")?.let { arr ->
            for (i in 0 until arr.length()) {
                val d = arr.optJSONObject(i) ?: continue
                devices += AccountDevice(
                    id = d.optLong("id"),
                    ip = d.optString("ip"),
                    createdAt = d.optString("created_at"),
                )
            }
        }
        return AccountStatus(
            tier = j.optString("tier"),
            deviceLimit = j.optInt("device_limit"),
            deviceCount = j.optInt("device_count"),
            activeUntil = j.optString("active_until"),
            devices = devices,
        )
    }

    private fun parseProvision(body: String): DeviceProvision {
        val j = jsonOf(body)
        val c = j.optJSONObject("config")
            ?: throw AccountException("The server response was missing the tunnel config.")
        val device = j.optJSONObject("device")
        return DeviceProvision(
            config = ProvisionedConfig(
                interfacePublicKey = c.optString("InterfacePublicKey"),
                interfaceAddress = c.optString("InterfaceAddress"),
                interfaceDNS = c.optString("InterfaceDNS"),
                peerPublicKey = c.optString("PeerPublicKey"),
                peerEndpoint = c.optString("PeerEndpoint"),
                peerAllowedIPs = c.optString("PeerAllowedIPs"),
                rosenpassPeerPub = c.optString("RosenpassPeerPub"),
                rosenpassListen = c.optString("RosenpassListen"),
                rosenpassClientPK = c.optString("RosenpassClientPK"),
                assignedIP = c.optString("AssignedIP"),
            ),
            tier = j.optString("tier"),
            deviceId = device?.optLong("ID") ?: 0L,
        )
    }

    private fun jsonOf(body: String): JSONObject =
        try {
            JSONObject(body)
        } catch (e: Exception) {
            throw AccountException("The server sent a response we couldn't read.")
        }

    private companion object {
        val JSON = "application/json".toMediaType()
    }
}
