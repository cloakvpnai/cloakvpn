package ai.latticevpn.android.data

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Auth failures surfaced to the tunnel manager / UI. */
class AuthException(message: String) : Exception(message)

/**
 * Auth client — Kotlin port of the iOS CloakAuthClient.
 *
 * Gets (and caches) a JWT that authorizes peer-provisioning calls
 * against cloak-api-server. Two-step flow:
 *
 *   1. Cache check — if a stored JWT is still more than
 *      [REFRESH_BUFFER_SEC] from expiry, use it as-is.
 *   2. Otherwise POST /api/v1/auth/exchange with the per-install UUID
 *      and the bootstrap key header; the server returns a fresh 24h
 *      JWT which is persisted and returned.
 *
 * The JWT is region-agnostic (every region shares JWT_SECRET), so we
 * only bootstrap against one region — the user's currently-selected
 * one, for locality.
 *
 * Storage: the JWT + its expiry + the install UUID live in the
 * "lattice" SharedPreferences (same store TunnelRepository uses).
 * That's the Android counterpart of the iOS AppGroupKeyStore.
 *
 * Phase 2 (when StoreKit/Play Billing entitlement ships): drop the
 * bootstrap-key path and send a signed purchase token instead of an
 * install UUID — the calling code (fetchAuthToken) does not change.
 */
class AuthClient(private val appCtx: Context) {

    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    private val prefs by lazy {
        appCtx.getSharedPreferences("lattice", Context.MODE_PRIVATE)
    }

    /**
     * Return a usable JWT, refreshing from the server if the cached one
     * is missing or near expiry. [regionServerBase] is the HTTPS base
     * URL to bootstrap against, e.g. "https://cloak-de1.cloakvpn.ai".
     */
    suspend fun fetchAuthToken(regionServerBase: String): String {
        val cachedJwt = prefs.getString(KEY_JWT, null)
        val cachedExp = prefs.getLong(KEY_JWT_EXP, 0L)
        val nowSec = System.currentTimeMillis() / 1000L
        if (cachedJwt != null && cachedExp - nowSec > REFRESH_BUFFER_SEC) {
            return cachedJwt
        }
        return bootstrapJwt(regionServerBase, installUuid())
    }

    /** Drop the cached JWT so the next fetch re-bootstraps. */
    fun invalidateCache() {
        prefs.edit().remove(KEY_JWT).remove(KEY_JWT_EXP).apply()
    }

    // MARK: - Internals

    /**
     * POST /api/v1/auth/exchange. Persists the returned JWT + expiry
     * and returns the token. Runs the blocking OkHttp call on the IO
     * dispatcher.
     */
    private suspend fun bootstrapJwt(
        regionServerBase: String,
        installUuid: String,
    ): String = withContext(Dispatchers.IO) {
        val base = regionServerBase.trim().trimEnd('/')
        val url = "$base/api/v1/auth/exchange"

        val bodyJson = JSONObject().put("install_uuid", installUuid).toString()
        val request = Request.Builder()
            .url(url)
            .post(bodyJson.toRequestBody("application/json".toMediaType()))
            .header("X-Cloak-Bootstrap-Key", LatticeRegion.bootstrapKey)
            .build()

        http.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw AuthException(
                    "bootstrap HTTP ${response.code}: ${text.take(200)}"
                )
            }
            val obj = runCatching { JSONObject(text) }.getOrNull()
                ?: throw AuthException("server response malformed: not JSON")
            val jwt = obj.optString("jwt").takeIf { it.isNotEmpty() }
                ?: throw AuthException("server response malformed: missing jwt")
            // exp may arrive as a number; optLong handles it.
            val exp = obj.optLong("exp", 0L)
            if (exp <= 0L) throw AuthException("server response malformed: missing exp")

            prefs.edit()
                .putString(KEY_JWT, jwt)
                .putLong(KEY_JWT_EXP, exp)
                .apply()
            jwt
        }
    }

    /**
     * The stable per-install identifier. Created once on first call and
     * persisted; identifies this install to the auth endpoint until a
     * real purchase-token identity replaces it.
     */
    private fun installUuid(): String {
        prefs.getString(KEY_INSTALL_UUID, null)?.let { return it }
        val fresh = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_INSTALL_UUID, fresh).apply()
        return fresh
    }

    companion object {
        /** Re-fetch a JWT this many seconds before its stated expiry. */
        private const val REFRESH_BUFFER_SEC = 60L * 60L   // 1 hour

        private const val KEY_JWT = "auth_jwt"
        private const val KEY_JWT_EXP = "auth_jwt_exp"
        private const val KEY_INSTALL_UUID = "install_uuid"
    }
}
