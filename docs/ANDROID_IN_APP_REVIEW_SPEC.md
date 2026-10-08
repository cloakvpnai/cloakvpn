# Android In-App Review: implementation spec

Goal: prompt happy users to rate Lattice VPN on Google Play without leaving the app, using Google's official Play In-App Review API. More ratings is the single biggest lever for both Play ranking and install conversion. No em-dashes anywhere.

## What this is

The In-App Review API shows the native Google Play rating card directly inside the app. The user rates and writes a review without ever leaving Lattice. You do not get to read the result, and Google decides whether to actually show the card (there is a per-user quota), so the rule is simple: ask at a good moment and never nag.

## 1. Add the dependency

In `clients/android/app/build.gradle.kts`:

```kotlin
dependencies {
    // Google Play In-App Review (Kotlin extensions)
    implementation("com.google.android.play:review-ktx:2.0.2")
}
```

(2.0.2 is the current stable line. Use the latest 2.0.x if a newer one exists.)

## 2. Add a small helper

Create `clients/android/app/src/main/kotlin/ai/latticevpn/android/review/ReviewPrompter.kt`:

```kotlin
package ai.latticevpn.android.review

import android.app.Activity
import com.google.android.play.core.review.ReviewManagerFactory
import com.google.android.play.core.review.ReviewManager
import kotlinx.coroutines.tasks.await

/**
 * Thin wrapper around the Play In-App Review API. Requests a review flow and,
 * if Google decides to show it, launches the native rating card. Safe to call
 * from a happy-path moment; Google rate-limits how often the card appears, so
 * a no-op is the expected common case.
 */
class ReviewPrompter(private val manager: ReviewManager) {

    suspend fun maybeAsk(activity: Activity) {
        runCatching {
            val info = manager.requestReviewFlow().await()
            manager.launchReviewFlow(activity, info).await()
        }
        // Intentionally ignore failures. We must never block the user or surface
        // an error: a failed or rate-limited review request is normal.
    }

    companion object {
        fun from(activity: Activity) =
            ReviewPrompter(ReviewManagerFactory.create(activity))
    }
}
```

Requires the coroutines Play Services adapter for `.await()`:

```kotlin
implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.8.1")
```

## 3. When to trigger (the important part)

Trigger after a genuine positive moment, not on launch and never after an error. Good signal for Lattice: the user has connected successfully (with PQC established) a few separate times.

Recommended rule:
- Count successful connections in `LatticeViewModel` (persist a counter in DataStore or SharedPreferences).
- On the 3rd successful, PQC-established connection, and only once ever, call `ReviewPrompter.maybeAsk(activity)`.
- Store a boolean `hasRequestedReview` so it never fires again, regardless of whether Google showed the card.

Sketch, wired off the existing connection-state flow:

```kotlin
// In LatticeViewModel, where you already observe a successful, PQC-up connection:
private suspend fun onHealthyConnection(activity: Activity) {
    if (prefs.hasRequestedReview) return
    val n = prefs.incrementSuccessfulConnections()
    if (n >= 3) {
        prefs.hasRequestedReview = true
        ReviewPrompter.from(activity).maybeAsk(activity)
    }
}
```

Anchor "healthy connection" to the same state you already use to show PQC as established (rotations greater than 0), so you never prompt during the brief handshake or a failed connect.

## 4. Hard rules (Google policy)

- Do not prompt on first launch, on app open, or after an error or disconnect.
- Do not ask repeatedly. Once per user is the right default for now.
- Do not put your own "Rate us" button next to it, and do not pre-ask "Do you like the app?" before launching the flow. Google forbids gating the card behind a custom yes/no prompt.
- Do not offer rewards for reviewing.
- You cannot detect whether the user reviewed or what score they gave. Do not try.

## 5. Testing

The card does not show in normal debug runs. Two ways to verify:
- Internal App Sharing or the Internal testing track: upload the build, install via the shared link, and the real card appears (subject to quota).
- `FakeReviewManager` for unit and flow testing without the real UI:

```kotlin
import com.google.android.play.core.review.testing.FakeReviewManager
val prompter = ReviewPrompter(FakeReviewManager(context))
```

## 6. Outside the API: ask directly too

The in-app card is quota-limited, so also ask your earliest users by hand. A short message to anyone who has tried Lattice ("if it is working well for you, a quick Play Store rating genuinely helps a new app") will get you the first 10 to 20 ratings faster than the API alone. Just never ask for positive reviews specifically, only honest ones, to stay within Google policy.

## Effort estimate

About half a day: add two dependencies, the helper, a small persisted counter, and one call site in the view model, then verify via Internal App Sharing. I can implement this directly when you want.
