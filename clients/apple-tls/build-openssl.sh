#!/bin/sh
# Builds OpenSSL 3.5.9 (Apache 2.0) as static libraries for macOS arm64 and
# links it at Vendor/openssl-macos. iOS slices are still to be added.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; WORK="${WORK:-$HOME/src}"; V=3.5.9
SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
mkdir -p "$WORK" && cd "$WORK"
[ -f openssl-$V.tar.gz ] || curl -fsSL -o openssl-$V.tar.gz https://github.com/openssl/openssl/releases/download/openssl-$V/openssl-$V.tar.gz
echo "$SHA  openssl-$V.tar.gz" | shasum -a 256 -c -
rm -rf openssl-macos-src && mkdir openssl-macos-src && tar xzf openssl-$V.tar.gz -C openssl-macos-src --strip-components 1
cd openssl-macos-src
./Configure darwin64-arm64-cc no-shared no-tests no-docs no-apps no-engine no-legacy no-ssl3 no-comp no-dso no-srp no-psk \
  no-weak-ssl-ciphers -mmacosx-version-min=14.0 --prefix="$WORK/openssl-macos"
make -j8 build_libs && make install_dev
mkdir -p "$HERE/Vendor" && ln -sfn "$WORK/openssl-macos" "$HERE/Vendor/openssl-macos"
