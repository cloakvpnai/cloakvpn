package ai.latticevpn.android.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** Peer-provisioning failures surfaced to the tunnel manager / UI. */
class ProvisioningException(message: String) : Exception(message)

/**
 * Peer-provisioning client — Kotlin port of the iOS
 * `TunnelManager.provisionFromAPIRaw`.
 *
 * Registers this device as a WireGuard + Rosenpass peer against a Cloak
 * region by POSTing both locally generated *public* keys to that
 * region's cloak-api-server. The server runs `add-peer.sh`, restarts
 * `cloak-rosenpass.service`, and returns a complete INI-style client
 * config block (without `private_key` — the device already holds the WG
 * secret locally). The caller imports that block.
 *
 * Privacy: only public keys cross the wire. The device's WireGuard and
 * Rosenpass private keys never leave it.
 *
 * Authorization: every call carries a short-lived JWT obtained from
 * [AuthClient]. The JWT is region-agnostic (all regions share
 * `JWT_SECRET`), so [AuthClient] bootstraps it against whichever region
 * is being provisioned. A `401` means the cached JWT was rejected — we
 * drop the cache so the next attempt re-bootstraps, then surface a
 * retryable error.
 */
class ProvisioningClient(private val authClient: AuthClient) {

    // Provisioning runs add-peer.sh + a service restart server-side, so
    // it needs more headroom than a plain API call. Capped so a hung
    // server cannot block the UI indefinitely. Mirrors the iOS
    // URLRequest.timeoutInterval = 30.
    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    /**
     * Provision (or idempotently re-register) this device against the
     * region whose API lives at [serverBase], e.g.
     * `https://cloak-de1.cloakvpn.ai`. Returns the raw config block text.
     *
     * Idempotent server-side: `add-peer.sh` derives the peer name from a
     * hash of the Rosenpass public key, so repeated calls re-register the
     * same peer rather than creating duplicates.
     *
     * @param peerName optional human-readable label; when null the server
     *   auto-derives one from the Rosenpass pubkey hash.
     */
    suspend fun provision(
        serverBase: String,
        wgPubkeyB64: String,
        rosenpassPubkeyB64: String,
        peerName: String? = null,
    ): String = withContext(Dispatchers.IO) {
        val base = serverBase.trim().trimEnd('/')
        if (base.isEmpty()) throw ProvisioningException("empty region serverBase URL")
        val url = "$base/api/v1/peers"

        // Bootstrap (or reuse a cached) JWT against this same region.
        val jwt = try {
            authClient.fetchAuthToken(base)
        } catch (e: AuthException) {
            throw ProvisioningException("auth failed before provisioning: ${e.message}")
        }

        val bodyJson = JSONObject().apply {
            put("wg_pubkey_b64", wgPubkeyB64)
            put("rosenpass_pubkey_b64", rosenpassPubkeyB64)
            if (!peerName.isNullOrEmpty()) put("peer_name", peerName)
        }.toString()

        val request = Request.Builder()
            .url(url)
            .post(bodyJson.toRequestBody("application/json".toMediaType()))
            .header("Authorization", "Bearer $jwt")
            .build()

        http.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty()
            when {
                response.code == 401 -> {
                    // JWT was rejected — likely a stale token the server
                    // lost trust in (e.g. JWT secret rotated). Drop the
                    // cache so the next attempt re-bootstraps.
                    authClient.invalidateCache()
                    throw ProvisioningException(
                        "provisioning rejected (HTTP 401); cleared JWT cache, please retry"
                    )
                }
                !response.isSuccessful -> {
                    throw ProvisioningException(
                        "provisioning failed HTTP ${response.code}: ${text.take(200)}"
                    )
                }
                text.isBlank() -> {
                    throw ProvisioningException("provisioning returned an empty config block")
                }
                else -> text
            }
        }
    }
}
