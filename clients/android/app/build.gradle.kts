import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Load build-time secrets from clients/android/secrets.properties.
// That file is gitignored — copy secrets.properties.example to
// secrets.properties and fill in the live value. The Android
// equivalent of the iOS Secrets.xcconfig -> Info.plist path.
val latticeSecrets = Properties().apply {
    val f = rootProject.file("secrets.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val cloakBootstrapKey: String = latticeSecrets.getProperty("CLOAK_BOOTSTRAP_KEY", "")

android {
    namespace = "ai.latticevpn.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "ai.latticevpn.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        ndk {
            // Restrict to the ABIs we actually ship rosenpass .so for.
            abiFilters += setOf("arm64-v8a", "x86_64")
        }

        // Bootstrap key for the /api/v1/auth/exchange call. Read at
        // build time from secrets.properties (see top of file) and
        // surfaced to Kotlin as BuildConfig.CLOAK_BOOTSTRAP_KEY.
        buildConfigField("String", "CLOAK_BOOTSTRAP_KEY", "\"$cloakBootstrapKey\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
    // WireGuard — the official Android library from the wireguard-android repo.
    implementation("com.wireguard.android:tunnel:1.0.20230706")

    // Material Components — provides the XML application theme referenced
    // by AndroidManifest.xml (Theme.Material3.*). The Compose UI uses
    // Compose Material3 separately; this dependency only supplies the
    // base activity theme + splash background.
    implementation("com.google.android.material:material:1.12.0")

    // AndroidX / Compose
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation(platform("androidx.compose:compose-bom:2024.09.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // OkHttp — HTTP client for the cloak-api-server auth + peer
    // provisioning calls (AuthClient, ProvisioningClient).
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // JNA — required by the uniffi-generated Kotlin bindings
    // (uniffi/rosenpassffi/rosenpassffi.kt) to load + call into the
    // native librosenpassffi.so. The @aar classifier pulls the Android
    // build of JNA which bundles its own native .so per ABI.
    implementation("net.java.dev.jna:jna:5.14.0@aar")

    // DataStore for persisting config (encrypted via Android Keystore wrapping)
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Tests
    testImplementation("junit:junit:4.13.2")
}
