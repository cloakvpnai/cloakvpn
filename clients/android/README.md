# Lattice VPN — Android client

Kotlin + Jetpack Compose app using `VpnService` + the official
[wireguard-android](https://github.com/WireGuard/wireguard-android) library
for the tunnel. Post-quantum key exchange (Rosenpass) runs via JNI.

## Prereqs

- JDK 17
- Android SDK: compileSdk 35, minSdk 26
- Android NDK 28.x (for the Rosenpass native library)
- Rust + cargo-ndk + Android Rust targets (for building the native lib)
- Google Play Console account ($25 one-time) — only needed at publish time

No Android Studio required — the build is fully command-line driven.

## Project layout

```
clients/android/
  settings.gradle.kts        # rootProject.name = "LatticeVPN"
  build.gradle.kts           # root — AGP + Kotlin plugin versions
  gradle.properties          # useAndroidX, parallel, JVM heap
  gradle/wrapper/            # Gradle 8.9 wrapper (committed)
  gradlew                    # wrapper script
  local.properties           # sdk.dir — machine-local, NOT committed
  app/
    build.gradle.kts         # app module
    src/main/
      AndroidManifest.xml
      kotlin/ai/latticevpn/android/
        MainActivity.kt
        ui/LatticeApp.kt
        vpn/LatticeVpnService.kt
        vpn/TunnelRepository.kt
        vpn/ConfigParser.kt        # LatticeConfig + INI parser
        vpn/RosenpassBridge.kt     # JNI bridge (stubbed in Phase 0)
      res/values/strings.xml
```

## Quickstart

```bash
cd clients/android
export JAVA_HOME=/opt/homebrew/opt/openjdk@17   # or your JDK 17 path
./gradlew :app:assembleDebug
# Install on a connected device:
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

First launch → paste the config block produced by `server/scripts/setup.sh`
→ tap **Connect** → Android asks for VPN permission → tunnel is up.

## Status

This is a **Phase 0 skeleton**, rebranded to Lattice VPN
(`ai.latticevpn.android`). It builds into an installable APK and shows the
connect UI, but the tunnel bring-up and post-quantum bridge are stubbed.

Remaining phases:
- **A3** — Rosenpass JNI library: cross-compile the RosenpassFFI Rust crate
  to Android `.so` (arm64-v8a, armeabi-v7a, x86_64) via `cargo-ndk`,
  wire up the JNI bindings in `RosenpassBridge.kt`.
- **A4** — WireGuard + VpnService: drive the real `GoBackend` tunnel.
- **A5** — Tunnel manager: port the iOS auth / region / provisioning logic
  to Kotlin coroutines (talks to cloak-api-server).
- **A6** — Full Jetpack Compose UI (region picker, settings, kill switch).
- **A7** — Polish + Play Store: adaptive icon, screenshots, release
  signing, store listing.

## Notes

- **wireguard-android** handles kernel-module detection, fallback to the Go
  userspace backend, DNS handling, and the ABI matrix. `TunnelRepository`
  thin-wraps it.
- **Rosenpass** runs via JNI — build the RosenpassFFI crate with
  `cargo-ndk` and drop the `.so` files into
  `app/src/main/jniLibs/<abi>/`. `RosenpassBridge.kt` is stubbed for
  Phase 0; the tunnel works without it (the WireGuard handshake is still
  PSK-mixed; the server enforces PQC posture).
- **Foreground service** with a persistent notification is required for
  Android 14+ to keep the tunnel alive.
- **Always-on VPN** and **block-non-VPN-traffic** are supported out of the
  box by `VpnService`; the settings screen exposing them is Phase A6.
