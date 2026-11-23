#!/bin/sh
# OpenSSL 3.5.9 (Apache 2.0) static libraries for Android, used by liblatticetls.so.
# Output: $WORK/openssl-android/<abi>/{include,lib}
set -eu
: "${ANDROID_NDK_ROOT:?set ANDROID_NDK_ROOT to the NDK directory}"
WORK="${WORK:-$HOME/src}"; V=3.5.9
SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
HOST_TAG="$(ls "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt" | head -1)"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT" PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/bin:$PATH"
mkdir -p "$WORK" && cd "$WORK"
[ -f openssl-$V.tar.gz ] || curl -fsSL -o openssl-$V.tar.gz https://github.com/openssl/openssl/releases/download/openssl-$V/openssl-$V.tar.gz
echo "$SHA  openssl-$V.tar.gz" | shasum -a 256 -c -
for pair in arm64-v8a:android-arm64 x86_64:android-x86_64; do
  abi=${pair%%:*}; target=${pair##*:}
  rm -rf "openssl-android-src-$abi" && mkdir "openssl-android-src-$abi"
  tar xzf openssl-$V.tar.gz -C "openssl-android-src-$abi" --strip-components 1
  ( cd "openssl-android-src-$abi"
    ./Configure $target no-shared no-tests no-docs no-apps no-engine no-legacy no-ssl3 no-comp no-dso no-srp no-psk \
      no-weak-ssl-ciphers no-ui-console -fPIC -D__ANDROID_API__=26 --prefix="$WORK/openssl-android/$abi"
    make -j8 build_libs && make install_dev )
done
