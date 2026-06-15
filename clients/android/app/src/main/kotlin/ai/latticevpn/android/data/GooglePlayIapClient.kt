package ai.latticevpn.android.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/** What the server returns after verifying a Play purchase token. */
data class IapResult(
    /**
     * The minted (first purchase) or re-issued (restore) account number, or
     * null on a plain renewal re-verify where the app already holds one.
     */
    val accountNumber: String?,
    val tier: String,
    /** RFC3339 instant the subscription is paid through. */
    val activeUntil: String,
)

/**
 * Posts a Google Play purchase token to the Lattice server (POST
 * /v1/googleplay) for server-side verification against the Play Developer API.
 * On success the server mints or extends the customer's account number and
 * returns it, so an in-app purchase signs the user in without them ever typing
 * a number — the same no-account model as Stripe and the iOS IAP.
 *
 * Unlike [AccountClient] this uses a plain HTTP client: purchase verification
 * does not tear down the tunnel (the way a region switch does), so it can ride
 * whatever the default route is.
 */
class GooglePlayIapClient {

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    /**
     * Verify [purchaseToken] with the server. Set [restore] when the app has
     * no stored account number (fresh install / Restore purchases) so the
     * server re-issues one. Throws [AccountException] on failure.
     */
    suspend fun verify(purchaseToken: String, restore: Boolean): IapResult =
        withContext(Dispatchers.IO) {
            val payload = JSONObject()
                .put("purchase_token", purchaseToken)
                .put("restore", restore)
                .toString()
            val request = Request.Builder()
                .url("${LatticeApi.BASE_URL}/v1/googleplay")
                .post(payload.toRequestBody(JSON))
                .build()
            parse(execute(request))
        }

    private fun execute(request: Request): String {
        val response = try {
            http.newCall(request).execute()
        } catch (e: IOException) {
            throw AccountException(
                "Couldn't reach Lattice to confirm your purchase. Check your connection and try again.",
                AccountException.Kind.NETWORK,
            )
        }
        response.use {
            val text = it.body?.string().orEmpty()
            if (it.isSuccessful) return text
            throw when (it.code) {
                402 -> AccountException(
                    "Google Play reports this subscription isn't active yet. " +
                        "If you just purchased, give it a moment and try again.",
                    AccountException.Kind.NO_SUBSCRIPTION,
                )
                400 -> AccountException(
                    "We couldn't verify that purchase with Google Play. Please try again.",
                    AccountException.Kind.OTHER,
                )
                else -> AccountException(
                    "Lattice server error (${it.code}) confirming your purchase. Please try again.",
                    AccountException.Kind.OTHER,
                )
            }
        }
    }

    private fun parse(body: String): IapResult {
        val j = try {
            JSONObject(body)
        } catch (e: Exception) {
            throw AccountException("The server sent a response we couldn't read.")
        }
        val number = j.optString("account_number").takeIf { it.isNotEmpty() }
        return IapResult(
            accountNumber = number,
            tier = j.optString("tier"),
            activeUntil = j.optString("active_until"),
        )
    }

    private companion object {
        val JSON = "application/json".toMediaType()
    }
}
