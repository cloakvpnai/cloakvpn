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
- **A5 — done** — Tunnel manager: peer provisioning + Rosenpass PSK
  rotation, ported from the iOS `TunnelManager` / `RosenpassBridge` to
  Kotlin coroutines. New files: `vpn/TunnelManager.kt`,
  `vpn/RosenpassRotator.kt`, `vpn/RosenpassTransport.kt`,
  `vpn/PskApplicator.kt`, `vpn/KeyStore.kt`, `data/ProvisioningClient.kt`.
  See "Phase A5 notes" below.
- **A6** — Full Jetpack Compose UI (region picker, settings, kill switch).
- **A7** — Polish + Play Store: adaptive icon, screenshots, release
  signing, store listing.

## Notes

- **wireguard-android** handles kernel-module detection, fallback to the Go
  userspace backend, DNS handling, and the ABI matrix. `TunnelRepository`
  thin-wraps it.
- **Rosenpass** runs via JNI — build the RosenpassFFI crate with
  `cargo-ndk` and drop the `.so` files into
  `app/src/main/jniLibs/<abi>/`. `RosenpassBridge.kt` is the thin JNI
  wrapper; `RosenpassRotator.kt` drives the periodic post-quantum
  handshake and PSK rotation (Phase A5).
- **Foreground service** with a persistent notification is required for
  Android 14+ to keep the tunnel alive.
- **Always-on VPN** and **block-non-VPN-traffic** are supported out of the
  box by `VpnService`; the settings screen exposing them is Phase A6.

## Phase A5 notes

Peer provisioning and the Rosenpass 2-minute PSK rotation are wired end
to end. `TunnelManager` is the orchestrator (region selection, identity
keygen, config import, connect/disconnect); `RosenpassRotator` runs the
post-quantum handshake loop once the tunnel is up. Two design points
worth knowing:

- **Rosenpass UDP routes through the tunnel.** `GoBackend` owns its own
  `VpnService`, so app code cannot `protect()` a socket to send the
  handshake outside the tunnel (the way iOS does via `excludedRoutes`).
  Instead the Rosenpass UDP travels inside the full tunnel and is
  delivered locally at the concentrator. This needs no native changes
  and is robust on a standard Linux WireGuard server. The first rotation
  therefore runs only once the tunnel is up — same ordering as iOS.

- **PSK rotation is seamless via a customized `libwg-go`.** The stock
  `com.wireguard.android:tunnel` artifact exposes no live-reconfigure
  call — `GoBackend.setState(UP)` on a running tunnel tears it down and
  brings it back up. So the project builds its own `libwg-go.so` with
  one added entry point, `wgSetConfig`, which calls `device.IpcSet` to
  update the peer's preshared key on the running tunnel **in place** —
  no teardown. `UapiPskApplicator` uses it. See `libwg-go/README.md`
  and `Scripts/build-libwg-go-android.sh`.

  If the custom library was not built (a plain checkout has the
  committed `.so`; otherwise run the script), `UapiPskApplicator`
  detects the missing JNI symbol and falls back automatically to
  `ReconfiguringPskApplicator`, which applies the new PSK via a brief
  tunnel reconnect. Either path rotates the key every cycle — the
  custom library just removes the ~1–2 s flicker.
