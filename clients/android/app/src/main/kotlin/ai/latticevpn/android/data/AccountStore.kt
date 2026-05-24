package ai.latticevpn.android.data

import android.content.Context

/**
 * Persists the customer's account number — the single credential in the
 * no-account billing model (docs/BILLING_INTEGRATION.md). There is no
 * email, password, or user record; the account number alone authorizes
 * every call to the Lattice account API.
 *
 * Stored in the shared "lattice" SharedPreferences, the same store
 * TunnelManager / TunnelRepository use. This replaces the old
 * AuthClient's install-UUID + JWT cache.
 */
class AccountStore(appCtx: Context) {

    private val prefs =
        appCtx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The stored account number in canonical hyphenated form, or null. */
    fun accountNumber(): String? = prefs.getString(KEY_ACCOUNT_NUMBER, null)

    /** True once a validated account number has been stored (signed in). */
    fun isSignedIn(): Boolean = !accountNumber().isNullOrEmpty()

    /** Persist [number], normalized to the canonical hyphenated form. */
    fun save(number: String) {
        prefs.edit()
            .putString(KEY_ACCOUNT_NUMBER, LatticeApi.formatAccountNumber(number))
            .apply()
    }

    /** Forget the account number — used on sign-out. */
    fun clear() {
        prefs.edit().remove(KEY_ACCOUNT_NUMBER).apply()
    }

    private companion object {
        const val PREFS = "lattice"
        const val KEY_ACCOUNT_NUMBER = "account_number"
    }
}
