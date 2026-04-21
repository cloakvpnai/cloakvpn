# Cloak VPN — Android client

Kotlin + Jetpack Compose app using `VpnService` + the official [wireguard-android](https://github.com/WireGuard/wireguard-android) library for the tunnel.

## Prereqs

- Android Studio Hedgehog (2023.1) or later
- JDK 17
- Android SDK 34 (compileSdk), min SDK 26
- Google Play Console account ($25 one-time) — only needed at publish time

## Project layout

```
clients/android/
  settings.gradle.kts
  build.gradle.kts          # root
  app/
    build.gradle.kts        # app module
    src/main/
      AndroidManifest.xml
      java/com/cloakvpn/app/
        MainActivity.kt
        ui/CloakApp.kt
        vpn/CloakVpnService.kt
        vpn/TunnelRepository.kt
        vpn/ConfigParser.kt
        vpn/RosenpassBridge.kt
      res/values/strings.xml
      res/xml/network_security_config.xml
```

## Quickstart

```bash
cd clients/android
./gradlew :app:assembleDebug
# Install on a connected device:
./gradlew :app:installDebug
```

First launch → paste the config block produced by `server/scripts/setup.sh` → tap **Connect** → Android asks for VPN permission → tunnel is up.

## Notes

- **wireguard-android** handles the heavy lifting: kernel-module detection, fallback to Go userspace backend, DNS handling, and ABI matrix. We thin-wrap it via `TunnelRepository`.
- **Rosenpass** runs via JNI — build `rosenpass` crate with `cargo-ndk` for `arm64-v8a`, `x86_64`, and copy `.so` libraries into `app/src/main/jniLibs/<abi>/librosenpass.so`. `RosenpassBridge.kt` is stubbed for Phase 0; the tunnel works without it (server side still has PQC posture via the PSK mixed into Noise IKpsk2).
- **Always-on and Block-non-VPN-traffic** are supported out of the box by `VpnService`. The app exposes them via a settings screen (not yet implemented).
- **Foreground service** with a persistent notification is required for Android 14+ to keep the tunnel alive.

## CI

See `.github/workflows/android-ci.yml` at repo root (not yet created). Runs `:app:assembleDebug`, unit tests, lint, detekt.
