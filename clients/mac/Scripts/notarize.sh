#!/usr/bin/env bash
#
# notarize.sh — Sign, notarize, staple, and DMG a Direct-Download
# build of LatticeMac.app.
#
# Prerequisites:
#   - Developer ID Application certificate installed in the login keychain
#   - notarytool keychain profile set up:
#       xcrun notarytool store-credentials latticevpn-notary \
#           --apple-id <YOUR_APPLE_ID> \
#           --team-id <TEAM_ID> \
#           --password <APP_SPECIFIC_PASSWORD>
#   - create-dmg installed (`brew install create-dmg`)
#
# Usage:
#   ./notarize.sh path/to/LatticeMac.app [out_dir]
#
# Result:
#   - <app> is re-signed with Hardened Runtime + Developer ID
#   - <app> is sent to Apple notary, polled until "Accepted"
#   - notarization ticket is stapled to the .app
#   - LatticeMac-<version>.dmg is produced in <out_dir> (default: ./dist)
#

set -euo pipefail

APP_PATH="${1:?Usage: notarize.sh path/to/LatticeMac.app [out_dir]}"
OUT_DIR="${2:-./dist}"
NOTARY_PROFILE="latticevpn-notary"
SIGN_IDENTITY="Developer ID Application"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: $APP_PATH does not exist or is not a .app bundle" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
APP_NAME=$(basename "$APP_PATH" .app)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
ZIP_PATH="$OUT_DIR/${APP_NAME}-${VERSION}.zip"
DMG_PATH="$OUT_DIR/${APP_NAME}-${VERSION}.dmg"

echo "==> Signing with Developer ID + Hardened Runtime"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$(dirname "$0")/../LatticeMac/Resources/LatticeMac.entitlements" \
    --deep "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH" || true   # pre-notary spctl is expected to warn

echo "==> Compressing for notary upload"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple Notary Service (this can take 1-15 min)"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

echo "==> Building DMG"
if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "Lattice VPN" \
        --window-size 540 380 \
        --icon-size 96 \
        --icon "${APP_NAME}.app" 140 180 \
        --app-drop-link 400 180 \
        --hdiutil-quiet \
        "$DMG_PATH" \
        "$APP_PATH"
else
    echo "create-dmg not installed; falling back to hdiutil"
    hdiutil create -volname "Lattice VPN" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
fi

echo "==> Signing the DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Submitting DMG to notary (so Gatekeeper trusts the download)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"

echo ""
echo "Done: $DMG_PATH"
echo "Verify with: spctl --assess --type open --context context:primary-signature -v $DMG_PATH"
