#!/usr/bin/env bash
# Personal build: Release build signed with a local Apple Development identity,
# installed to /Applications. A stable signing identity keeps macOS Screen
# Recording and Accessibility grants across rebuilds (ad-hoc signatures do not).
#
#   SIGN_IDENTITY=<sha1 or name> scripts/personal-install.sh
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="${SIGN_IDENTITY:-Apple Development}"
APP=".build/Build/Products/Release/BetterShot.app"

xcodebuild -project BetterShot.xcodeproj -scheme BetterShot -configuration Release \
    -derivedDataPath .build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    build 2>&1 | grep -E "error:|BUILD" | tail -5

codesign --force --options runtime --entitlements Resources/BetterShot.entitlements \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

osascript -e 'quit app "BetterShot"' 2>/dev/null || true
for _ in {1..20}; do pgrep -x BetterShot >/dev/null || break; sleep 0.25; done
pkill -x BetterShot 2>/dev/null || true

rm -rf /Applications/BetterShot.app
ditto "$APP" /Applications/BetterShot.app
open /Applications/BetterShot.app
echo "==> Installed /Applications/BetterShot.app"
