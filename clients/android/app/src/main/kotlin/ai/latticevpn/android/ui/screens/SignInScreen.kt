package ai.latticevpn.android.ui.screens

import ai.latticevpn.android.data.LatticeApi
import ai.latticevpn.android.ui.LatticeViewModel
import ai.latticevpn.android.ui.Screen
import ai.latticevpn.android.ui.components.LatticeLogo
import ai.latticevpn.android.ui.theme.LatticeNavy
import ai.latticevpn.android.ui.theme.LatticeNavyElevated
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * First-launch sign-in.
 *
 * In the no-account model the customer's only credential is the account
 * number they received after subscribing at latticevpn.ai — there is no
 * email and no password. The number is validated against the Lattice
 * account API (GET /v1/account) before it is stored, so a typo is caught
 * here rather than at the first connect.
 *
 * This is the app root whenever no account number is stored, so it has
 * no back affordance.
 */
@Composable
fun SignInScreen(vm: LatticeViewModel) {
    val context = LocalContext.current
    val busy by vm.signInBusy.collectAsState()

    var input by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    val complete = LatticeApi.isCompleteAccountNumber(input)

    val submit: () -> Unit = {
        if (complete && !busy) {
            error = null
            vm.signIn(input) { err -> error = err }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(LatticeNavyElevated, LatticeNavy))),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 28.dp, vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            LatticeLogo(Modifier.size(64.dp))
            Spacer(Modifier.height(20.dp))
            Text(
                text = "Lattice VPN",
                color = MaterialTheme.colorScheme.onSurface,
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(10.dp))
            Text(
                text = "Enter your account number to get started. No email, " +
                    "no password — your account number is the only key you need.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 14.sp,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(28.dp))

            OutlinedTextField(
                value = input,
                onValueChange = {
                    // Keep only valid symbols, cap at the full length, and
                    // re-group into hyphenated fives as the customer types.
                    input = LatticeApi.normalizeAccountNumber(it)
                        .take(LatticeApi.ACCOUNT_NUMBER_LENGTH)
                        .chunked(5)
                        .joinToString("-")
                    error = null
                },
                label = { Text("Account number") },
                placeholder = { Text("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX") },
                singleLine = true,
                isError = error != null,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.Characters,
                    keyboardType = KeyboardType.Ascii,
                    imeAction = ImeAction.Done,
                ),
                keyboardActions = KeyboardActions(onDone = { submit() }),
                modifier = Modifier.fillMaxWidth(),
            )

            if (error != null) {
                Spacer(Modifier.height(8.dp))
                Text(
                    text = error ?: "",
                    color = MaterialTheme.colorScheme.error,
                    fontSize = 13.sp,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Spacer(Modifier.height(20.dp))

            Button(
                onClick = submit,
                enabled = complete && !busy,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
            ) {
                if (busy) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(22.dp),
                        strokeWidth = 2.5.dp,
                        color = MaterialTheme.colorScheme.onPrimary,
                    )
                } else {
                    Text("Continue", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }

            Spacer(Modifier.height(18.dp))

            TextButton(onClick = { vm.navigateTo(Screen.PAYWALL) }) {
                Text("Don't have an account? See plans")
            }
            TextButton(onClick = { openUrl(context, "https://latticevpn.ai/recover") }) {
                Text("Lost your account number?")
            }
        }
    }
}

/** Open [url] in the device browser; silently no-ops if nothing can handle it. */
private fun openUrl(context: Context, url: String) {
    runCatching {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
