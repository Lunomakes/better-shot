#!/usr/bin/env bash
# Builds the BetterShot Plus release DMG for the Lunomakes fork: universal
# Release, the fork's bundle ID, ad-hoc signed (not notarized).
# Prints the DMG path: release/BetterShot-Plus-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION=$(python3 -c "import json; print(json.load(open('version.json'))['version'])")
DERIVED=.build/fork-release
APP_NAME="BetterShot Plus"
DMG="release/BetterShot-Plus-$VERSION.dmg"

# The bundle ID is set only here, so it can sit beside upstream BetterShot
# while local personal builds keep com.bettershot.app and their privacy grants.
xcodebuild -project BetterShot.xcodeproj -scheme BetterShot -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
    PRODUCT_BUNDLE_IDENTIFIER=com.lunomakes.bettershot \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    build 2>&1 | grep -E "error:|BUILD" | tail -5

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$DERIVED/Build/Products/Release/BetterShot.app" "$STAGE/$APP_NAME.app"
codesign --force --options runtime --entitlements Resources/BetterShot.entitlements \
    --sign - "$STAGE/$APP_NAME.app"
codesign --verify --strict "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p release
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
echo "$DMG"
