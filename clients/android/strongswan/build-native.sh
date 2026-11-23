#!/bin/sh
# Builds the strongSwan native libraries for the Android app's CNSA 2.0 mode.
#
# strongSwan is GPLv2. These libraries may only ship inside an app whose
# source is published under a compatible license.
#
# Pinned inputs:
#   strongSwan  eb7fa250749b3979055e09312cd603f1a61d9aee  (development branch: ML-DSA is not in 6.1.0)
#   OpenSSL     3.5.9, sha256 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
# Needs: Android NDK, Docker (for strongSwan's autotools step), perl, make.
# Output: $OUT/arm64-v8a/lib{strongswan,charon,ipsec,androidbridge}.so
# Copy those into ../app/src/debug/jniLibs/arm64-v8a/ (git-ignored).
# lattice-android.patch: certificate authentication only (no EAP, no BYOD),
# larger IKE messages, private key handed over by the app, lifetimes from the
# profile.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${ANDROID_NDK_ROOT:?set ANDROID_NDK_ROOT to the NDK directory}"
WORK="${WORK:-$HOME/src}"
OUT="${OUT:-$WORK/strongswan-android-libs}"
ABI="${ABI:-arm64-v8a}"
HOST_TAG="$(ls "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt" | head -1)"
mkdir -p "$WORK" && cd "$WORK"

if [ ! -d strongswan ]; then
  git clone https://github.com/strongswan/strongswan.git
fi
git -C strongswan checkout -q eb7fa250749b3979055e09312cd603f1a61d9aee
git -C strongswan checkout -q -- . && git -C strongswan apply "$HERE/lattice-android.patch"

if [ ! -d openssl-3.5.9 ]; then
  curl -fsSL -o openssl-3.5.9.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
  echo "603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a  openssl-3.5.9.tar.gz" | shasum -a 256 -c -
  tar xzf openssl-3.5.9.tar.gz
fi

# 1. libcrypto for Android (static), same options as strongSwan's own script.
JNI="$WORK/strongswan/src/frontends/android/app/src/main/jni"
mkdir -p "$JNI/openssl/$ABI"
( cd openssl-3.5.9
  export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT" PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/bin:$PATH"
  ./Configure android-arm64 no-shared no-ct no-cast no-comp no-dgram no-dsa no-gost no-idea no-rmd160 \
    no-seed no-sm2 no-sm3 no-sm4 no-sock no-srp no-srtp no-err no-engine no-dso no-hw no-stdio \
    no-ui-console -fPIC -DOPENSSL_PIC -O3 -Wno-macro-redefined -D__ANDROID_API__=26
  make -j8 build_generated && make -j8 libcrypto.a
  cp libcrypto.a "$JNI/openssl/$ABI/" && cp -R include/ "$JNI/openssl/include" )
cat > "$JNI/openssl/Android.mk" <<'MK'
LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)
LOCAL_MODULE := libcrypto_static
LOCAL_SRC_FILES := $(TARGET_ARCH_ABI)/libcrypto.a
LOCAL_EXPORT_C_INCLUDES := $(LOCAL_PATH)/include
include $(PREBUILT_STATIC_LIBRARY)
MK

# 2. Generate strongSwan's parser and table sources (autotools, in a container).
docker run --rm -v "$WORK/strongswan:/ss" -w /ss lattice-cnsa2-lab:master \
  sh -c "./autogen.sh && ./configure && make -j4 && make distclean"

# 3. Native libraries.
"$ANDROID_NDK_ROOT/ndk-build" -C "$JNI" NDK_PROJECT_PATH=.. NDK_OUT="$WORK/strongswan-android-obj" \
  NDK_LIBS_OUT="$OUT" APP_ABI="$ABI" -j8
ls -l "$OUT/$ABI"
