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
    compileSdk = 35

    defaultConfig {
        applicationId = "ai.latticevpn.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 3
        versionName = "1.0.1"

        ndk {
            // Restrict to the ABIs we actually ship rosenpass .so for.
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
        // The customized libwg-go.so (built by
        // Scripts/build-libwg-go-android.sh — it adds wgSetConfig for
        // seamless Rosenpass PSK rotation) must take precedence over the
        // copy bundled inside the wireguard-android AAR.
        jniLibs.pickFirsts += "**/libwg-go.so"
        // 16 KB page-size compliance (v1.0.1): the wireguard-android AAR
        // also bundles libwg.so (the wg(8) tool) and libwg-quick.so —
        // both built with 4 KB ELF alignment upstream, and both used ONLY
        // by the root-mode WgQuickBackend / ToolsInstaller path, which
        // this app never touches (we use GoBackend exclusively). Dropping
        // them from the APK removes the 16 KB-page install block on
        // Android 15+ devices without rebuilding the AAR.
        jniLibs.excludes += setOf("**/libwg.so", "**/libwg-quick.so")
    }
}

dependencies {
    // WireGuard — the official Android library from the wireguard-android repo.
    implementation("com.wireguard.android:tunnel:1.0.20230706")

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

    // Google Play Billing — in-app subscription purchases (BillingManager,
    // PaywallScreen). v7 is the current minimum Google accepts for new
    // uploads; the -ktx artifact adds the coroutine extensions. The purchase
    // token is verified server-side (POST /v1/googleplay) which mints/extends
    // the customer's account number — the same no-account model as Stripe/IAP.
    implementation("com.android.billingclient:billing-ktx:7.1.1")

    // JNA — required by the uniffi-generated Kotlin bindings
    // (uniffi/rosenpassffi/rosenpassffi.kt) to load + call into the
    // native librosenpassffi.so. The @aar classifier pulls the Android
    // build of JNA which bundles its own native .so per ABI.
    // 5.17.0 is the first release whose libjnidispatch.so is built with
    // 16 KB page alignment (JNA issues #1618/#1647) — required for
    // Android 15+ devices running in 16 KB page-size mode. Don't
    // downgrade below 5.17.0.
    implementation("net.java.dev.jna:jna:5.17.0@aar")

    // DataStore for persisting config (encrypted via Android Keystore wrapping)
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Tests
    testImplementation("junit:junit:4.13.2")
}
