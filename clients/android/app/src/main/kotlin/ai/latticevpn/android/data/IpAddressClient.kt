package ai.latticevpn.android.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/** Failure looking up the device's public IP address. */
class IpLookupException(message: String) : Exception(message)

/**
 * Looks up the device's current public IPv4 address.
 *
 * Hits ipify (`https://api.ipify.org`), which returns the caller's IP
 * as plain text and nothing else. The result depends on the current
 * route: with the VPN down it returns the user's real ISP address;
 * with the tunnel up the request travels through WireGuard, so ipify
 * sees — and returns — the Cloak concentrator's exit address. The home
 * screen relies on exactly that to show "your IP" before connecting and
 * the server's IP afterwards.
 */
class IpAddressClient {

    private val http = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .build()

    /** Return the current public IP. Throws [IpLookupException] on failure. */
    suspend fun fetchPublicIp(): String = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(ENDPOINT)
            .header("User-Agent", "LatticeVPN-Android")
            .build()
        try {
            http.newCall(request).execute().use { response ->
                val body = response.body?.string()?.trim().orEmpty()
                if (!response.isSuccessful) {
                    throw IpLookupException("IP lookup failed (HTTP ${response.code})")
                }
                if (!looksLikeIp(body)) {
                    throw IpLookupException("IP lookup returned an unexpected response")
                }
                body
            }
        } catch (e: IpLookupException) {
            throw e
        } catch (e: Exception) {
            throw IpLookupException(e.message ?: "IP lookup failed")
        }
    }

    /**
     * Loose sanity check — an IPv4 dotted quad or an IPv6 literal. ipify
     * returns bare IPv4 by default; v6 is tolerated for v6-only networks.
     */
    private fun looksLikeIp(s: String): Boolean {
        if (s.isEmpty() || s.length > 45) return false
        return s.all { c ->
            c.isDigit() || c == '.' || c == ':' || c in 'a'..'f' || c in 'A'..'F'
        }
    }

    companion object {
        private const val ENDPOINT = "https://api.ipify.org"
    }
}
