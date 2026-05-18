#!/usr/bin/env bash
#
# build-mac-framework.sh — rebuilds clients/mac/Frameworks/rosenpassffiFFI.framework
# from the Rust sources at clients/ios/RosenpassFFI/.
#
# Why is this NOT folded into clients/ios/RosenpassFFI/build-xcframework.sh?
# Because an Apple xcframework cannot contain a mix of static (.a) and
# dynamic (.dylib / .framework) library types. The iOS slices are
# static (idiomatic for iOS); the Mac slice has to be dynamic to avoid
# a duplicate-symbol link error with Mullvad's libmaybenot (which also
# embeds Rust std and defines `_rust_eh_personality`).
#
# Run after pulling a new RosenpassFFI Rust source revision:
#   ./build-mac-framework.sh
#
# Output:
#   clients/mac/Frameworks/rosenpassffiFFI.framework/   (versioned bundle)
#
# Prerequisites:
#   - Rust toolchain 1.88.0 with aarch64-apple-darwin target
#   - Xcode 14+ (for install_name_tool + framework signing)
#

set -euo pipefail

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUST_DIR="$SCRIPT_DIR/../../ios/RosenpassFFI"
FW_DIR="$SCRIPT_DIR/../Frameworks/rosenpassffiFFI.framework"

color() { printf "\033[1;34m[mac-fw]\033[0m %s\n" "$*"; }

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0

# 1. Build the Rust dylib for aarch64-apple-darwin.
color "building librosenpassffi.dylib (aarch64-apple-darwin, release, --no-default-features)"
cd "$RUST_DIR"
cargo +1.88.0 build --release --target aarch64-apple-darwin --no-default-features

DYLIB="$RUST_DIR/target/aarch64-apple-darwin/release/librosenpassffi.dylib"
HEADER="$RUST_DIR/out/include/rosenpassffiFFI.h"
[[ -f "$DYLIB"  ]] || { echo "dylib not built: $DYLIB" >&2; exit 1; }
[[ -f "$HEADER" ]] || { echo "header not built: $HEADER — run build-xcframework.sh first" >&2; exit 1; }

# 2. Assemble the macOS versioned-bundle framework.
color "assembling rosenpassffiFFI.framework (versioned macOS layout)"
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR/Versions/A/Headers"
mkdir -p "$FW_DIR/Versions/A/Modules"
mkdir -p "$FW_DIR/Versions/A/Resources"

# Binary
cp "$DYLIB" "$FW_DIR/Versions/A/rosenpassffiFFI"
install_name_tool -id "@rpath/rosenpassffiFFI.framework/Versions/A/rosenpassffiFFI" \
    "$FW_DIR/Versions/A/rosenpassffiFFI"

# Header
cp "$HEADER" "$FW_DIR/Versions/A/Headers/rosenpassffiFFI.h"

# Module map (framework module, name must match the import in
# clients/ios/CloakVPN/rosenpassffi.swift: `import rosenpassffiFFI`)
cat > "$FW_DIR/Versions/A/Modules/module.modulemap" <<'EOF'
framework module rosenpassffiFFI {
    umbrella header "rosenpassffiFFI.h"
    export *
    module * { export * }
}
EOF

# Info.plist
cat > "$FW_DIR/Versions/A/Resources/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>rosenpassffiFFI</string>
<key>CFBundleIdentifier</key><string>ai.latticevpn.rosenpassffiFFI</string>
<key>CFBundleName</key><string>rosenpassffiFFI</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>MinimumOSVersion</key><string>14.0</string>
</dict></plist>
EOF

# Top-level symlinks (Versions/Current → A, then four content links)
cd "$FW_DIR/Versions"
ln -sf A Current
cd "$FW_DIR"
ln -sf Versions/Current/rosenpassffiFFI .
ln -sf Versions/Current/Headers .
ln -sf Versions/Current/Modules .
ln -sf Versions/Current/Resources .

color "✓ wrote $FW_DIR ($(du -sh "$FW_DIR" | cut -f1))"
