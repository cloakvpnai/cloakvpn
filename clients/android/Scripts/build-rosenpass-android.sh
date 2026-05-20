#!/usr/bin/env bash
#
# build-rosenpass-android.sh — cross-compile the RosenpassFFI Rust crate
# to Android .so libraries for every shipped ABI, and drop them into
# app/src/main/jniLibs/<abi>/librosenpassffi.so.
#
# Run after pulling a new RosenpassFFI source revision.
#
# Prerequisites:
#   - Rust toolchain 1.88.0 with the Android targets:
#       rustup target add aarch64-linux-android armv7-linux-androideabi \
#                          x86_64-linux-android --toolchain 1.88.0
#   - cargo-ndk            (cargo install cargo-ndk)
#   - Android NDK 28.x     (sdkmanager "ndk;28.2.13676358")
#   - CMake 4.x + Ninja    (brew install cmake ninja)  — needed because
#                          oqs-sys builds liboqs (C) via CMake.
#
# Why the CMAKE_TOOLCHAIN_FILE override:
#   cmake-rs defaults to CMake's built-in Android support, which fails
#   to find Ninja on CMake 4.x + NDK 28 ("CMAKE_MAKE_PROGRAM is not
#   set"). Pointing CMAKE_TOOLCHAIN_FILE at our wrapper forces cmake-rs
#   onto the NDK's own android.toolchain.cmake, which works. See
#   ndk-cmake-toolchain.cmake for the full explanation.

set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$ANDROID_DIR/../ios/RosenpassFFI"
JNILIBS="$ANDROID_DIR/app/src/main/jniLibs"

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/28.2.13676358"
export CMAKE_GENERATOR=Ninja
export CMAKE_TOOLCHAIN_FILE="$ANDROID_DIR/ndk-cmake-toolchain.cmake"

# Map cargo-ndk ABI name -> the LATTICE_ANDROID_ABI the wrapper expects.
# (They happen to be identical strings, but keep the mapping explicit.)
ABIS=("arm64-v8a" "armeabi-v7a" "x86_64")

color() { printf "\033[1;34m[rp-android]\033[0m %s\n" "$*"; }

cd "$RUST_DIR"

for ABI in "${ABIS[@]}"; do
    color "building librosenpassffi.so for $ABI"
    export LATTICE_ANDROID_ABI="$ABI"
    # Clean the per-ABI target dir so a stale CMakeCache from a prior
    # generator choice can't poison the build.
    case "$ABI" in
        arm64-v8a)    rm -rf target/aarch64-linux-android ;;
        armeabi-v7a)  rm -rf target/armv7-linux-androideabi ;;
        x86_64)       rm -rf target/x86_64-linux-android ;;
    esac
    cargo +1.88.0 ndk -t "$ABI" -o "$JNILIBS" build --release --no-default-features
done

color "✓ built ABIs: ${ABIS[*]}"
find "$JNILIBS" -name '*.so' -exec ls -la {} \;
