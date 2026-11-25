import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Load build-time secrets (the release-signing credentials) from
// clients/android/secrets.properties. That file is gitignored — copy
// secrets.properties.example to secrets.properties and fill it in.
// There is no build-time API key: the app authenticates to the Lattice
// API at runtime with the customer's account number.
val latticeSecrets = Properties().apply {
    val f = rootProject.file("secrets.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

// Release signing — credentials live in the gitignored secrets.properties
// (see secrets.properties.example). Absent on a plain checkout or a debug
// build, in which case the release build is simply left unsigned.
val releaseStoreFile: String = latticeSecrets.getProperty("RELEASE_STORE_FILE", "")
val releaseStorePassword: String = latticeSecrets.getProperty("RELEASE_STORE_PASSWORD", "")
val releaseKeyAlias: String = latticeSecrets.getProperty("RELEASE_KEY_ALIAS", "")
val releaseKeyPassword: String = latticeSecrets.getProperty("RELEASE_KEY_PASSWORD", "")

android {
    namespace = "ai.latticevpn.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "ai.latticevpn.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 10
        versionName = "2.0.0"

        ndk {
            // The ABIs the tunnel engine (liblatticetls.so) is built for.
            abiFilters += setOf("arm64-v8a", "x86_64")
        }
    }

    signingConfigs {
        create("release") {
            // Populated only when secrets.properties supplies the keystore
            // details; otherwise left empty and the release build stays
            // unsigned (it still builds — it just can't be uploaded to
            // Play until a keystore is configured). Keystore files are
            // gitignored (*.jks / *.keystore); never commit them.
            if (releaseStoreFile.isNotEmpty()) {
                storeFile = rootProject.file(releaseStoreFile)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Sign with the release key when secrets.properties provides
            // one. Left unsigned otherwise so a plain checkout still builds.
            if (releaseStoreFile.isNotEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    // Bouncy Castle: ML-DSA-87 (FIPS 204) for this device's key and certificate request.
    // Only the lightweight API is used (no JCA provider is registered); R8 strips the rest.
    implementation("org.bouncycastle:bcprov-jdk18on:1.80")

    // Material Components — provides the XML application theme referenced
    // by AndroidManifest.xml (Theme.Material3.*). The Compose UI uses
    // Compose Material3 separately; this dependency only supplies the
    // base activity theme + splash background.
    implementation("com.google.android.material:material:1.12.0")

    // AndroidX / Compose
    implementation("androidx.core:core-ktx:1.13.1")
    // Backported splash-screen API (branded launch screen, API 23+).
    implementation("androidx.core:core-splashscreen:1.0.1")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation(platform("androidx.compose:compose-bom:2024.09.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    // Material icon set used by the A6 UI (Settings, Lock, Check,
    // ArrowBack, chevrons). Versioned by the Compose BOM above. The
    // -extended artifact is a strict superset of -core; R8 strips the
    // unused icons from release builds, so the shipped APK is unaffected.
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.animation:animation")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // OkHttp — HTTP client for the Lattice account API calls
    // (AccountClient) and the public-IP lookup (IpAddressClient).
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // WorkManager: daily renewal of the CNSA 2.0 device certificate
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    // Google Play Billing — in-app subscription purchases (BillingManager,
    // PaywallScreen). v8.0.0+ is required by Google Play policy (Aug 2026); we
    // ship v9.0.0, the latest; the -ktx artifact adds the coroutine extensions. The purchase
    // token is verified server-side (POST /v1/googleplay) which mints/extends
    // the customer's account number — the same no-account model as Stripe/IAP.
    implementation("com.android.billingclient:billing-ktx:9.0.0")

    // DataStore for persisting config (encrypted via Android Keystore wrapping)
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Tests
    testImplementation("junit:junit:4.13.2")
}
