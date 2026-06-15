package ai.latticevpn.android.ui.screens

import ai.latticevpn.android.billing.BillingManager
import ai.latticevpn.android.ui.LatticeViewModel
import ai.latticevpn.android.ui.Screen
import ai.latticevpn.android.ui.components.LatticeLogo
import ai.latticevpn.android.ui.theme.LatticeNavy
import ai.latticevpn.android.ui.theme.LatticeNavyElevated
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * In-app subscription paywall (Google Play Billing).
 *
 * Reached from the sign-in screen for customers who don't yet have an account
 * number. A purchase is verified server-side, which mints the account number
 * and signs the customer in automatically — they never type anything. The web
 * checkout at latticevpn.ai remains available as a secondary path (dual
 * billing), so this screen also offers a "subscribe on the web" link.
 */
@Composable
fun PaywallScreen(vm: LatticeViewModel) {
    BackHandler { vm.navigateTo(Screen.SIGN_IN) }

    val context = LocalContext.current
    val activity = remember(context) { context.findActivity() }

    val plans by vm.plans.collectAsState()
    val ready by vm.billingReady.collectAsState()
    val purchaseBusy by vm.purchaseBusy.collectAsState()
    val billingError by vm.billingError.collectAsState()
    val purchaseError by vm.purchaseError.collectAsState()

    var yearly by remember { mutableStateOf(false) }

    // Connect to Play and load plans when the screen appears.
    androidx.compose.runtime.LaunchedEffect(Unit) { vm.startBilling() }

    val period = if (yearly) BillingManager.PLAN_YEARLY else BillingManager.PLAN_MONTHLY
    val visible = plans.filter { it.period == period }
    val basic = visible.firstOrNull { it.tier == BillingManager.PRODUCT_BASIC }
    val pro = visible.firstOrNull { it.tier == BillingManager.PRODUCT_PRO }

    Box(
        Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(LatticeNavyElevated, LatticeNavy))),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            LatticeLogo(Modifier.size(52.dp))
            Spacer(Modifier.height(16.dp))
            Text(
                text = "Choose your plan",
                color = MaterialTheme.colorScheme.onSurface,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                text = "No email, no account. Subscribe and you're signed in " +
                    "automatically — your account number is created for you.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 13.sp,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(20.dp))
            BillingPeriodToggle(yearly = yearly, onChange = { yearly = it })
            Spacer(Modifier.height(20.dp))

            when {
                !ready && plans.isEmpty() -> {
                    Spacer(Modifier.height(24.dp))
                    CircularProgressIndicator(strokeWidth = 2.5.dp)
                    Spacer(Modifier.height(12.dp))
                    Text(
                        "Loading plans from Google Play…",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 13.sp,
                    )
                }

                else -> {
                    PlanCard(
                        title = "Basic",
                        price = basic?.let { priceLabel(it.formattedPrice, yearly) } ?: "—",
                        subtitle = "Post-quantum privacy for everyday use.",
                        features = listOf(
                            "3 devices",
                            "Post-quantum encryption",
                            "No-logs guarantee",
                            "Kill switch",
                            "Email support",
                        ),
                        highlighted = false,
                        enabled = basic != null && !purchaseBusy,
                        onSubscribe = { if (activity != null && basic != null) vm.launchPurchase(activity, basic) },
                    )
                    Spacer(Modifier.height(14.dp))
                    PlanCard(
                        title = "Pro",
                        price = pro?.let { priceLabel(it.formattedPrice, yearly) } ?: "—",
                        subtitle = "For users who need more.",
                        features = listOf(
                            "Up to 10 devices",
                            "Post-quantum encryption",
                            "No-logs guarantee",
                            "Kill switch",
                            "Priority email support",
                            "Pro app icon variant",
                        ),
                        highlighted = true,
                        enabled = pro != null && !purchaseBusy,
                        onSubscribe = { if (activity != null && pro != null) vm.launchPurchase(activity, pro) },
                    )
                }
            }

            if (purchaseBusy) {
                Spacer(Modifier.height(18.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.height(0.dp))
                    Text(
                        "  Confirming your purchase…",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 13.sp,
                    )
                }
            }

            (purchaseError ?: billingError)?.let { msg ->
                Spacer(Modifier.height(14.dp))
                Text(
                    text = msg,
                    color = MaterialTheme.colorScheme.error,
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Spacer(Modifier.height(20.dp))

            TextButton(onClick = { vm.restorePurchases() }, enabled = !purchaseBusy) {
                Text("Restore purchases")
            }
            TextButton(onClick = { vm.navigateTo(Screen.SIGN_IN) }) {
                Text("Already have an account number? Sign in")
            }
            TextButton(onClick = { openUrl(context, "https://latticevpn.ai/pricing") }) {
                Text("Or subscribe on the web")
            }

            Spacer(Modifier.height(16.dp))
            Text(
                text = "Subscriptions auto-renew until canceled. Manage or cancel " +
                    "anytime in Google Play. By subscribing you agree to our Terms " +
                    "and Privacy Policy.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 11.sp,
                textAlign = TextAlign.Center,
            )
            Row(horizontalArrangement = Arrangement.Center) {
                TextButton(onClick = { openUrl(context, "https://latticevpn.ai/terms") }) {
                    Text("Terms", fontSize = 12.sp)
                }
                TextButton(onClick = { openUrl(context, "https://latticevpn.ai/privacy") }) {
                    Text("Privacy", fontSize = 12.sp)
                }
            }
        }
    }
}

/** Monthly / Yearly segmented toggle. */
@Composable
private fun BillingPeriodToggle(yearly: Boolean, onChange: (Boolean) -> Unit) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Row(Modifier.padding(4.dp)) {
            ToggleChip("Monthly", selected = !yearly) { onChange(false) }
            ToggleChip("Yearly · 2 months free", selected = yearly) { onChange(true) }
        }
    }
}

@Composable
private fun ToggleChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(9.dp),
        color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant,
        onClick = onClick,
    ) {
        Text(
            text = label,
            color = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun PlanCard(
    title: String,
    price: String,
    subtitle: String,
    features: List<String>,
    highlighted: Boolean,
    enabled: Boolean,
    onSubscribe: () -> Unit,
) {
    val border = if (highlighted) {
        Modifier.border(1.5.dp, MaterialTheme.colorScheme.primary, RoundedCornerShape(16.dp))
    } else {
        Modifier
    }
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        modifier = Modifier
            .fillMaxWidth()
            .then(border),
    ) {
        Column(Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = title,
                    color = MaterialTheme.colorScheme.onSurface,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f),
                )
                if (highlighted) {
                    Surface(
                        shape = RoundedCornerShape(6.dp),
                        color = MaterialTheme.colorScheme.primaryContainer,
                    ) {
                        Text(
                            "Most popular",
                            color = MaterialTheme.colorScheme.primary,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                }
            }
            Spacer(Modifier.height(4.dp))
            Text(
                text = price,
                color = MaterialTheme.colorScheme.onSurface,
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = subtitle,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 13.sp,
            )
            Spacer(Modifier.height(12.dp))
            features.forEach { f ->
                Row(Modifier.padding(vertical = 2.dp)) {
                    Text("✓ ", color = MaterialTheme.colorScheme.primary, fontSize = 13.sp)
                    Text(f, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                }
            }
            Spacer(Modifier.height(14.dp))
            Button(
                onClick = onSubscribe,
                enabled = enabled,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp),
                colors = if (highlighted) {
                    ButtonDefaults.buttonColors()
                } else {
                    ButtonDefaults.outlinedButtonColors(
                        contentColor = MaterialTheme.colorScheme.primary,
                    )
                },
            ) {
                Text("Subscribe to $title", fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/** Append a "/mo" or "/yr" suffix to Play's localized formatted price. */
private fun priceLabel(formattedPrice: String, yearly: Boolean): String =
    formattedPrice + if (yearly) " / year" else " / month"

/** Unwrap a Compose [Context] to its hosting [Activity], or null. */
private fun Context.findActivity(): Activity? {
    var ctx: Context? = this
    while (ctx is ContextWrapper) {
        if (ctx is Activity) return ctx
        ctx = ctx.baseContext
    }
    return null
}

/** Open [url] in the device browser; silently no-ops if nothing handles it. */
private fun openUrl(context: Context, url: String) {
    runCatching {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
