#!/bin/sh
# Builds liblatticetls.so for the Android app: the shared C layer from
# clients/apple-tls plus its JNI surface, linked statically against OpenSSL 3.5.
# Run build-openssl.sh first. Output: ../app/src/main/jniLibs/<abi>/liblatticetls.so
set -eu
: "${ANDROID_NDK_ROOT:?set ANDROID_NDK_ROOT to the NDK directory}"
HERE="$(cd "$(dirname "$0")" && pwd)"; WORK="${WORK:-$HOME/src}"
SHARED="$HERE/../../apple-tls/Sources/CLatticeTLS"
HOST_TAG="$(ls "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt" | head -1)"
BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/bin"
for pair in arm64-v8a:aarch64-linux-android26 x86_64:x86_64-linux-android26; do
  abi=${pair%%:*}; target=${pair##*:}; SSL="$WORK/openssl-android/$abi"
  out="$HERE/../app/src/main/jniLibs/$abi"; mkdir -p "$out"
  "$BIN/clang" --target=$target -shared -fPIC -O2 -Wall -Wextra -Wno-unused-parameter \
    -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fvisibility=hidden \
    -I"$SHARED/include" -I"$SSL/include" \
    "$SHARED/lattice_tls.c" "$HERE/lattice_tls_jni.c" \
    "$SSL/lib/libssl.a" "$SSL/lib/libcrypto.a" \
    -Wl,--exclude-libs,ALL -Wl,-z,relro,-z,now -Wl,-z,max-page-size=16384 -Wl,--gc-sections \
    -o "$out/liblatticetls.so"
  "$BIN/llvm-strip" --strip-unneeded "$out/liblatticetls.so"
  ls -l "$out/liblatticetls.so"
done
