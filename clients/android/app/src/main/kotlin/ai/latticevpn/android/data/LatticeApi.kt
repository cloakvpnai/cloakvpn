package ai.latticevpn.android.data

/**
 * The central Lattice account + provisioning API.
 *
 * Unlike the per-region WireGuard concentrators, account validation and
 * device provisioning go through ONE endpoint. The billing/account
 * service is central — it owns the account store the Stripe webhook
 * writes to — so the app talks to a single host for everything
 * account-related. See docs/DEPLOY_API.md and docs/BILLING_INTEGRATION.md.
 *
 * (Provisioning a peer onto a *specific* concentrator across all regions
 * is the deferred multi-region work — BILLING_INTEGRATION.md §7. Until
 * then this single API provisions against the region it fronts.)
 */
object LatticeApi {

    /**
     * HTTPS base URL of the Lattice account API. In production this is a
     * Caddy reverse proxy terminating TLS in front of `cloakvpn-api`
     * (see docs/DEPLOY_API.md §6). No trailing slash.
     */
    const val BASE_URL = "https://api.latticevpn.ai"

    /** Symbol count of a complete account number (see server/internal/account). */
    const val ACCOUNT_NUMBER_LENGTH = 25

    // Crockford base-32 alphabet — excludes I, L, O, U. Must match
    // server/api/internal/account/account.go exactly.
    private const val CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    /**
     * Strip an account number to its bare symbols: uppercase, with all
     * hyphens, whitespace and any non-alphabet characters removed. The
     * server hashes the normalized form (account.Normalize), so this
     * just has to agree with it.
     */
    fun normalizeAccountNumber(input: String): String =
        buildString {
            for (c in input.uppercase()) if (c in CROCKFORD) append(c)
        }

    /**
     * Canonical display form: the symbols regrouped into hyphenated
     * groups of five, e.g. "36ASS-06QHX-877TR-8T1D0-6DV38". Safe to
     * send to the server as-is — it normalizes before hashing.
     */
    fun formatAccountNumber(input: String): String =
        normalizeAccountNumber(input).chunked(5).joinToString("-")

    /** True when [input] has the full complement of account-number symbols. */
    fun isCompleteAccountNumber(input: String): Boolean =
        normalizeAccountNumber(input).length == ACCOUNT_NUMBER_LENGTH
}
