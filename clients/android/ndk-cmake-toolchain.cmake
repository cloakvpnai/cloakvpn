# ndk-cmake-toolchain.cmake
#
# Wrapper CMake toolchain for cross-compiling CMake-based Rust
# dependencies (oqs-sys / liboqs) to Android.
#
# Why this exists:
#   The `cmake` Rust crate, when it sees an Android Rust target,
#   defaults to CMake's BUILT-IN Android support (CMAKE_SYSTEM_NAME=
#   Android). That path runs Modules/Platform/Android-Determine.cmake,
#   which on this toolchain combination (CMake 4.x + NDK 28) fails to
#   locate the Ninja build program ("CMAKE_MAKE_PROGRAM is not set").
#
#   The NDK's own android.toolchain.cmake does NOT have that problem
#   (verified: `cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE=<ndk>` configures
#   liboqs cleanly). So we force cmake-rs onto the NDK toolchain by
#   exporting CMAKE_TOOLCHAIN_FILE=<this file>, and this file pins the
#   ABI + API level and delegates to the real NDK toolchain.
#
#   The ABI comes from the LATTICE_ANDROID_ABI env var (set per build
#   in Scripts/build-rosenpass-android.sh), defaulting to arm64-v8a.
#
# Used by clients/android/Scripts/build-rosenpass-android.sh.

if(DEFINED ENV{LATTICE_ANDROID_ABI})
  set(ANDROID_ABI "$ENV{LATTICE_ANDROID_ABI}")
else()
  set(ANDROID_ABI "arm64-v8a")
endif()
set(ANDROID_PLATFORM "android-26")

include("$ENV{ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake")
