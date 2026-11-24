#!/bin/sh
# Builds OpenSSL 3.5.9 (Apache 2.0) as static libraries for the Apple apps and
# links them under Vendor/:
#   Vendor/openssl-macos          macOS arm64
#   Vendor/openssl-ios            iOS arm64 (devices)
#   Vendor/openssl-iossimulator   iOS simulator arm64
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; WORK="${WORK:-$HOME/src}"; V=3.5.9
SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPTS="no-shared no-tests no-docs no-apps no-engine no-legacy no-ssl3 no-comp no-dso no-srp no-psk no-weak-ssl-ciphers no-async"
mkdir -p "$WORK" "$HERE/Vendor" && cd "$WORK"
[ -f openssl-$V.tar.gz ] || curl -fsSL -o openssl-$V.tar.gz https://github.com/openssl/openssl/releases/download/openssl-$V/openssl-$V.tar.gz
echo "$SHA  openssl-$V.tar.gz" | shasum -a 256 -c -
build() { # name, Configure target, extra flags
  name=$1; target=$2; shift 2
  [ -z "${ONLY:-}" ] || [ "$ONLY" = "$name" ] || return 0
  rm -rf "openssl-$name-src" && mkdir "openssl-$name-src" && tar xzf openssl-$V.tar.gz -C "openssl-$name-src" --strip-components 1
  ( cd "openssl-$name-src" && ./Configure $target $OPTS "$@" --prefix="$WORK/openssl-$name" && make -j8 build_libs && make install_dev )
  ln -sfn "$WORK/openssl-$name" "$HERE/Vendor/openssl-$name"
}
build macos darwin64-arm64-cc -mmacosx-version-min=14.0
build ios ios64-xcrun -mios-version-min=17.0
build iossimulator iossimulator-arm64-xcrun -mios-simulator-version-min=17.0
