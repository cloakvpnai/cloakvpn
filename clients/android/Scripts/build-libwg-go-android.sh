#!/usr/bin/env bash
#
# build-libwg-go-android.sh — build a customized libwg-go.so for each
# shipped Android ABI and drop it into app/src/main/jniLibs/<abi>/.
#
# The customization: stock wireguard-android libwg-go PLUS Lattice's
# wgSetConfig entry point (libwg-go/api-uapi.go + libwg-go/jni-uapi.c),
# which lets the Rosenpass rotation loop apply a fresh preshared key to
# the running tunnel in place — with no tunnel teardown. The resulting
# .so shadows the copy bundled inside the wireguard-android AAR (see the
# jniLibs.pickFirsts rule in app/build.gradle.kts).
#
# Run this after editing api-uapi.go / jni-uapi.c, or to (re)generate
# the committed .so files. The .so files ARE committed (re-included in
# clients/android/.gitignore) so a plain checkout still builds a working
# APK — exactly the policy used for the rosenpass libraries in A3.
#
# Prerequisites:
#   - Android NDK 28.x   (sdkmanager "ndk;28.2.13676358")
#   - git, make, curl, patch, tar   (preinstalled on macOS / Linux)
#   - Go is downloaded + runtime-patched automatically by the upstream
#     libwg-go Makefile; nothing to install.
#
# This is the one piece of Phase A5 that cannot be verified without a
# real native toolchain. If the first run fails, the error output from
# the failing `make` is enough to pinpoint the fix.

set -euo pipefail

# --- configuration ---------------------------------------------------

# wireguard-android git ref to build libwg-go from. Pinned to the same
# version as the com.wireguard.android:tunnel AAR the app depends on, so
# the native JNI ABI matches the AAR's GoBackend.java exactly.
WIREGUARD_ANDROID_REF="${WIREGUARD_ANDROID_REF:-1.0.20230706}"

# Must match the abiFilters in app/build.gradle.kts.
ABIS=("arm64-v8a" "x86_64")

# Native API level for the cross-compile (must be <= app minSdk, 26).
API_LEVEL="${API_LEVEL:-21}"

# Baked into libwg-go via an -X ldflag; must match the app applicationId.
ANDROID_PACKAGE_NAME="ai.latticevpn.android"

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JNILIBS="$ANDROID_DIR/app/src/main/jniLibs"
SRC_DIR="$ANDROID_DIR/libwg-go"             # api-uapi.go + jni-uapi.c live here
BUILD_DIR="$ANDROID_DIR/.libwg-go-build"    # scratch; gitignored
NDK="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"

color() { printf "\033[1;34m[libwg-go]\033[0m %s\n" "$*"; }
fail()  { printf "\033[1;31m[libwg-go] ERROR:\033[0m %s\n" "$*" >&2; exit 1; }

# --- sanity checks ---------------------------------------------------

[ -d "$NDK" ] || fail "Android NDK not found at: $NDK
Set ANDROID_NDK_HOME, or install it: sdkmanager \"ndk;28.2.13676358\""

for tool in git make curl patch tar; do
	command -v "$tool" >/dev/null 2>&1 || fail "required tool not found on PATH: $tool"
done

[ -f "$SRC_DIR/api-uapi.go" ] || fail "missing $SRC_DIR/api-uapi.go"
[ -f "$SRC_DIR/jni-uapi.c" ]  || fail "missing $SRC_DIR/jni-uapi.c"

# Detect the NDK host-prebuilt toolchain directory (darwin-x86_64,
# linux-x86_64, ...).
NDK_HOST_DIR=""
for d in "$NDK"/toolchains/llvm/prebuilt/*/; do
	[ -d "$d" ] && NDK_HOST_DIR="${d%/}" && break
done
[ -n "$NDK_HOST_DIR" ] || fail "no LLVM prebuilt toolchain found under $NDK"
TOOLBIN="$NDK_HOST_DIR/bin"
SYSROOT="$NDK_HOST_DIR/sysroot"

# --- macOS shims -----------------------------------------------------
# The upstream libwg-go Makefile uses `flock` and `sha256sum`, which are
# absent on stock macOS. Provide equivalents on PATH when missing.

SHIM_DIR="$BUILD_DIR/shims"
mkdir -p "$SHIM_DIR"
if ! command -v flock >/dev/null 2>&1; then
	color "providing a no-op flock shim (not present on this host)"
	cat > "$SHIM_DIR/flock" <<'SHIM'
#!/bin/sh
# Minimal flock stand-in: ignore the lock file, run the -c command.
# Safe here — this script builds one ABI at a time, serially.
while [ $# -gt 0 ]; do
	case "$1" in
		-c) shift; exec /bin/sh -c "$1" ;;
		*)  shift ;;
	esac
done
SHIM
	chmod +x "$SHIM_DIR/flock"
fi
if ! command -v sha256sum >/dev/null 2>&1; then
	color "providing a sha256sum shim over shasum"
	cat > "$SHIM_DIR/sha256sum" <<'SHIM'
#!/bin/sh
exec shasum -a 256 "$@"
SHIM
	chmod +x "$SHIM_DIR/sha256sum"
fi
export PATH="$SHIM_DIR:$PATH"

# --- fetch the wireguard-android libwg-go sources --------------------

CLONE_DIR="$BUILD_DIR/wireguard-android-$WIREGUARD_ANDROID_REF"
if [ ! -d "$CLONE_DIR/tunnel/tools/libwg-go" ]; then
	color "cloning wireguard-android @ $WIREGUARD_ANDROID_REF"
	rm -rf "$CLONE_DIR"
	git clone --depth 1 --branch "$WIREGUARD_ANDROID_REF" \
		https://github.com/WireGuard/wireguard-android.git "$CLONE_DIR"
fi
LIBWG="$CLONE_DIR/tunnel/tools/libwg-go"

# Drop in the Lattice additions (overwrites any prior copy so re-runs
# always pick up edits to the source-of-truth files under libwg-go/).
color "applying Lattice additions: api-uapi.go, jni-uapi.c"
cp "$SRC_DIR/api-uapi.go" "$LIBWG/api-uapi.go"
cp "$SRC_DIR/jni-uapi.c"  "$LIBWG/jni-uapi.c"

# --- build per ABI ---------------------------------------------------

# Shared across ABIs: the Makefile downloads + runtime-patches Go here
# once; only DESTDIR is per-ABI.
GO_CACHE="$BUILD_DIR/gradle-cache"
MAKE_BUILDDIR="$BUILD_DIR/make-build"
mkdir -p "$GO_CACHE" "$MAKE_BUILDDIR"

for ABI in "${ABIS[@]}"; do
	case "$ABI" in
		arm64-v8a)   ARCH_NAME="arm64";  TRIPLE="aarch64-linux-android" ;;
		x86_64)      ARCH_NAME="x86_64"; TRIPLE="x86_64-linux-android" ;;
		armeabi-v7a) ARCH_NAME="arm";    TRIPLE="armv7a-linux-androideabi" ;;
		x86)         ARCH_NAME="x86";    TRIPLE="i686-linux-android" ;;
		*) fail "unsupported ABI: $ABI" ;;
	esac

	CC="$TOOLBIN/${TRIPLE}${API_LEVEL}-clang"
	[ -x "$CC" ] || fail "NDK compiler not found: $CC"

	DEST="$BUILD_DIR/out/$ABI"
	mkdir -p "$DEST"

	color "building libwg-go.so for $ABI ($ARCH_NAME)"
	make -C "$LIBWG" \
		ANDROID_ARCH_NAME="$ARCH_NAME" \
		ANDROID_PACKAGE_NAME="$ANDROID_PACKAGE_NAME" \
		GRADLE_USER_HOME="$GO_CACHE" \
		CC="$CC" \
		CFLAGS="" \
		LDFLAGS="" \
		SYSROOT="$SYSROOT" \
		TARGET="${TRIPLE}${API_LEVEL}" \
		DESTDIR="$DEST" \
		BUILDDIR="$MAKE_BUILDDIR"

	mkdir -p "$JNILIBS/$ABI"
	cp "$DEST/libwg-go.so" "$JNILIBS/$ABI/libwg-go.so"
	color "  -> $JNILIBS/$ABI/libwg-go.so"
done

color "✓ built libwg-go.so for: ${ABIS[*]}"
ls -la "$JNILIBS"/*/libwg-go.so
