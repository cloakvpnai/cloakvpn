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
        MainActivity.kt            # single-activity host
        ui/
          LatticeApp.kt            # nav root (Home / Regions / Settings)
          LatticeViewModel.kt      # Compose-facing layer over TunnelManager
          theme/                   # brand Material 3 theme (Color, Theme)
          components/Components.kt  # connect control, brand mark, rows
          screens/                 # Home, RegionPicker, Settings
        vpn/TunnelManager.kt       # A5 orchestrator
        vpn/TunnelRepository.kt    # GoBackend tunnel wrapper
        vpn/ConfigParser.kt        # LatticeConfig + INI parser
        vpn/RosenpassBridge.kt     # JNI bridge to librosenpassffi
        data/                      # Region catalog, AuthClient, ProvisioningClient
      res/values/                  # strings, colors, themes
```

## Quickstart

```bash
cd clients/android
export JAVA_HOME=/opt/homebrew/opt/openjdk@17   # or your JDK 17 path
./gradlew :app:assembleDebug
# Install on a connected device:
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

First launch → tap the location card → pick a region (the app provisions
a peer against that region's `cloak-api-server`) → tap the shield to
connect → Android asks for VPN permission → tunnel is up. A raw config
block can still be pasted under **Settings → Advanced**.

## Status

The Android client is feature-complete through **Phase A6**. It builds
into an installable APK with the real WireGuard tunnel (A4), the
Rosenpass post-quantum PSK rotation (A3/A5), region provisioning (A5),
and the full Jetpack Compose UI (A6). Only store-readiness polish (A7)
remains.

Phase status:
- **A3 — done** — Rosenpass JNI library cross-compiled to Android `.so`
  (arm64-v8a, armeabi-v7a, x86_64) via `cargo-ndk`, wired through
  `RosenpassBridge.kt`.
- **A4 — done** — real `GoBackend` WireGuard tunnel via `VpnService`.
- **A5 — done** — Tunnel manager: peer provisioning + Rosenpass PSK
  rotation, ported from the iOS `TunnelManager` / `RosenpassBridge` to
  Kotlin coroutines. New files: `vpn/TunnelManager.kt`,
  `vpn/RosenpassRotator.kt`, `vpn/RosenpassTransport.kt`,
  `vpn/PskApplicator.kt`, `vpn/KeyStore.kt`, `data/ProvisioningClient.kt`.
  See "Phase A5 notes" below.
- **A6 — done** — Full Jetpack Compose UI: brand Material 3 theme, a
  redesigned connection home screen, the region picker, and a settings
  screen (incl. the always-on / kill-switch hand-off). See "Phase A6
  notes" below.
- **A7 — pending** — Polish + Play Store: adaptive icon, screenshots,
  release signing, store listing.

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
  box by `VpnService`. Android does not let an app toggle them itself, so
  the Settings screen deep-links to the system VPN settings instead.

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

## Phase A6 notes

The Compose UI is a single-activity, three-screen app — Home, region
picker, settings — cross-faded by `LatticeApp`. State lives where A5 put
it: `LatticeViewModel` is a thin Compose-shaped layer over the
process-wide `TunnelManager`, adding only in-app navigation, the
auto-connect preference, and a `viewModelScope` for firing the manager's
`suspend` actions. Four points worth knowing:

- **No sign-in screen.** Auth is headless — `AuthClient` mints a JWT
  from a per-install UUID + the bootstrap key — so the user never sees a
  login. Region selection alone drives provisioning.

- **The kill switch is a system setting.** Android does not expose an
  API for an app to turn on always-on VPN or "block connections without
  VPN". The Settings screen is honest about this: it deep-links to
  `Settings.ACTION_VPN_SETTINGS` where the user enables both for Lattice.

- **`VpnService.prepare` lives in the activity.** Bringing the tunnel up
  may need the system VPN-consent dialog, which needs an `Activity`
  result launcher. `MainActivity` owns that flow and the launch-time
  auto-connect; the view model only exposes `connect()` / `disconnect()`.

- **The brand mark and connect control are drawn, not bundled.** Both
  are Compose `Canvas` code (`ui/components/Components.kt`), so they
  scale crisply and re-tint per tunnel state with no image assets. The
  adaptive launcher icon is still Phase A7.

The activity XML theme (`res/values/themes.xml`, `Theme.Lattice`) only
sets the window background and system-bar colors to the brand navy so
cold start does not flash white — the actual UI palette is the Compose
`LatticeTheme`.
