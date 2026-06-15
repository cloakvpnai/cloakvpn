package ai.latticevpn.android.billing

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Owns the Google Play Billing client and exposes the Lattice subscription
 * plans plus a one-shot purchase flow.
 *
 * Billing model (matches the no-account system used by Stripe and the iOS
 * IAP): a purchase never grants entitlement on its own. When Play reports a
 * successful purchase we hand the opaque purchase token to [onPurchase]; the
 * view model posts it to the server (POST /v1/googleplay), which verifies it
 * against the Play Developer API and mints/extends the customer's account
 * number. The token — not the Google account — is the identity the server
 * keys on, so the resulting account number works across platforms.
 *
 * Play product layout (see docs/GOOGLE_PLAY_BILLING_SETUP.md): two
 * subscriptions, [PRODUCT_BASIC] and [PRODUCT_PRO], each with a [PLAN_MONTHLY]
 * and a [PLAN_YEARLY] base plan. The four [SubPlan]s the UI shows are the
 * cross-product of those.
 */
class BillingManager(
    appContext: Context,
    /** Invoked on the main thread when Play confirms a purchase. */
    private val onPurchase: (purchaseToken: String, productId: String) -> Unit,
) {

    /** One purchasable option shown on the paywall. */
    data class SubPlan(
        val tier: String,        // PRODUCT_BASIC / PRODUCT_PRO
        val period: String,      // PLAN_MONTHLY / PLAN_YEARLY
        val productId: String,
        val offerToken: String,
        val formattedPrice: String,
        val billingPeriod: String, // ISO-8601 e.g. "P1M" / "P1Y"
        val details: ProductDetails,
    )

    private val _plans = MutableStateFlow<List<SubPlan>>(emptyList())
    /** The available plans, populated once Play returns product details. */
    val plans: StateFlow<List<SubPlan>> = _plans.asStateFlow()

    private val _ready = MutableStateFlow(false)
    /** True once the billing client is connected and product details loaded. */
    val ready: StateFlow<Boolean> = _ready.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    /** A user-facing billing error (connection / flow failure), or null. */
    val error: StateFlow<String?> = _error.asStateFlow()

    fun clearError() { _error.value = null }

    private val purchasesListener =
        PurchasesUpdatedListener { result: BillingResult, purchases: List<Purchase>? ->
            when (result.responseCode) {
                BillingClient.BillingResponseCode.OK -> {
                    purchases?.forEach { handlePurchase(it) }
                }
                BillingClient.BillingResponseCode.USER_CANCELED -> {
                    // No-op: the user backed out of the Play sheet.
                }
                else -> {
                    _error.value = "Purchase failed (${result.responseCode}). Please try again."
                }
            }
        }

    private val client: BillingClient =
        BillingClient.newBuilder(appContext)
            .setListener(purchasesListener)
            .enablePendingPurchases(
                PendingPurchasesParams.newBuilder()
                    .enableOneTimeProducts()
                    .build(),
            )
            .build()

    /** Connect to Play and load product details. Safe to call repeatedly. */
    fun start() {
        if (client.isReady) {
            queryProducts()
            return
        }
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    queryProducts()
                } else {
                    _error.value = "Couldn't reach Google Play billing (${result.responseCode})."
                }
            }

            override fun onBillingServiceDisconnected() {
                _ready.value = false
                // Play will reconnect on the next start(); nothing to do here.
            }
        })
    }

    private fun queryProducts() {
        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(
                listOf(PRODUCT_BASIC, PRODUCT_PRO).map { id ->
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(id)
                        .setProductType(BillingClient.ProductType.SUBS)
                        .build()
                },
            )
            .build()

        client.queryProductDetailsAsync(params) { result, productDetailsList ->
            if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                _error.value = "Couldn't load plans from Google Play (${result.responseCode})."
                return@queryProductDetailsAsync
            }
            val out = mutableListOf<SubPlan>()
            for (pd in productDetailsList) {
                val offers = pd.subscriptionOfferDetails ?: continue
                // For each base plan, prefer the plain base-plan offer (no
                // offerId, i.e. no intro/free-trial offer) so the displayed
                // price is the recurring price.
                val byPlan = offers.groupBy { it.basePlanId }
                for ((basePlanId, planOffers) in byPlan) {
                    val offer = planOffers.firstOrNull { it.offerId == null } ?: planOffers.first()
                    val phases = offer.pricingPhases.pricingPhaseList
                    val recurring = phases.lastOrNull() ?: continue
                    out += SubPlan(
                        tier = pd.productId,
                        period = basePlanId,
                        productId = pd.productId,
                        offerToken = offer.offerToken,
                        formattedPrice = recurring.formattedPrice,
                        billingPeriod = recurring.billingPeriod,
                        details = pd,
                    )
                }
            }
            // Stable display order: Basic before Pro, monthly before yearly.
            out.sortWith(
                compareBy({ if (it.tier == PRODUCT_PRO) 1 else 0 },
                    { if (it.period == PLAN_YEARLY) 1 else 0 }),
            )
            _plans.value = out
            _ready.value = true
        }
    }

    /** Launch the Play purchase sheet for [plan]. */
    fun launchPurchase(activity: Activity, plan: SubPlan) {
        val productParams = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(plan.details)
            .setOfferToken(plan.offerToken)
            .build()
        val flowParams = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(listOf(productParams))
            .build()
        val result = client.launchBillingFlow(activity, flowParams)
        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
            _error.value = "Couldn't start the purchase (${result.responseCode})."
        }
    }

    /**
     * Re-deliver any subscription this Google account already owns — used for
     * "Restore purchases" on a fresh install. Each owned purchase is routed
     * through [handlePurchase] exactly as a new purchase would be.
     */
    fun restorePurchases(onDone: (found: Boolean) -> Unit = {}) {
        val params = QueryPurchasesParams.newBuilder()
            .setProductType(BillingClient.ProductType.SUBS)
            .build()
        client.queryPurchasesAsync(params) { result, purchases ->
            if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                _error.value = "Couldn't check your Google Play purchases (${result.responseCode})."
                onDone(false)
                return@queryPurchasesAsync
            }
            val active = purchases.filter {
                it.purchaseState == Purchase.PurchaseState.PURCHASED
            }
            active.forEach { handlePurchase(it) }
            onDone(active.isNotEmpty())
        }
    }

    private fun handlePurchase(purchase: Purchase) {
        if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) {
            // PENDING (e.g. cash / slow card) — entitlement waits for the
            // RTDN-driven server update; nothing to deliver yet.
            return
        }
        val productId = purchase.products.firstOrNull().orEmpty()
        onPurchase(purchase.purchaseToken, productId)
        // NOTE: acknowledgement is performed server-side after the token is
        // verified (POST /v1/googleplay), so we deliberately do NOT acknowledge
        // here — doing both is harmless but the server is the source of truth.
    }

    /** Tear down the billing connection (call from the owner's onCleared). */
    fun dispose() {
        runCatching { client.endConnection() }
    }

    companion object {
        // Play Console subscription IDs and base-plan IDs. Must match the
        // products created in the Play Console and the server's
        // GOOGLE_PLAY_PRODUCT_* env (which default to "basic"/"pro").
        const val PRODUCT_BASIC = "basic"
        const val PRODUCT_PRO = "pro"
        const val PLAN_MONTHLY = "monthly"
        const val PLAN_YEARLY = "yearly"
    }
}
