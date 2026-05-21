# libwg-go — Lattice customization

This directory holds **Lattice's additions to wireguard-android's
`libwg-go`**, plus the script that builds the customized native library.

## Why this exists

WireGuard's userspace engine (`wireguard-go`, shipped as `libwg-go.so`)
can update a peer's preshared key on a *running* tunnel in place, via
its `IpcSet` call. But the stock `com.wireguard.android:tunnel` Maven
artifact exposes no path to it — `GoBackend.setState(UP)` on a live
tunnel tears it down and brings it back up.

That forces Rosenpass PSK rotation to bounce the tunnel every ~2
minutes (a brief reconnect each cycle). To rotate **seamlessly**, the
project builds its own `libwg-go.so` with one extra entry point.

## What's added

| File | Purpose |
|------|---------|
| `api-uapi.go`  | A cgo `//export wgSetConfig` — calls `device.IpcSet` on the running tunnel. |
| `jni-uapi.c`   | The JNI wrapper, bound to `ai.latticevpn.android.vpn.WgUapi`. |

Both are dropped into a pinned checkout of wireguard-android's
`tunnel/tools/libwg-go/` and compiled, unchanged-otherwise, into
`libwg-go.so`. Nothing in the upstream sources is modified.

## How it's built

```bash
cd clients/android
./Scripts/build-libwg-go-android.sh
```

The script clones wireguard-android at the pinned ref
(`1.0.20230706` — the same version as the `tunnel` AAR), copies in the
two files above, and cross-compiles `libwg-go.so` for each shipped ABI
(`arm64-v8a`, `x86_64`) using the Android NDK. Output goes to
`app/src/main/jniLibs/<abi>/libwg-go.so`.

Those `.so` files **are committed** (re-included in
`clients/android/.gitignore`) so a plain checkout builds a complete APK
without the native toolchain — the same policy used for the rosenpass
libraries. Re-run the script after editing `api-uapi.go` / `jni-uapi.c`.

## How it's wired up

- `app/build.gradle.kts` has a `jniLibs.pickFirsts` rule so this
  `libwg-go.so` takes precedence over the AAR's copy.
- `WgUapi.kt` declares the `external fun wgSetConfig` JNI binding.
- `UapiPskApplicator.kt` uses it to rotate the PSK with no tunnel
  bounce. If this custom `.so` is absent (the build was never run), the
  JNI symbol is missing, `WgUapi` reports unavailable, and the rotation
  loop falls back to the bounce-based `ReconfiguringPskApplicator` — so
  the app always works, with or without this library.

## Compatibility note

The customized `libwg-go.so` is built from wireguard-android
`1.0.20230706` to match the `tunnel` AAR. The JNI surface that
`GoBackend` depends on (`wgTurnOn`, `wgTurnOff`, `wgGetConfig`, …) is
unchanged, so the custom library is a drop-in replacement for the AAR's.
If the `tunnel` dependency is upgraded, bump `WIREGUARD_ANDROID_REF` in
the build script to match and rebuild.
