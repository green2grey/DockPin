#!/bin/bash
set -euo pipefail

APP="DockPin"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
BUNDLE="$BUILD/$APP.app"
CONTENTS="$BUNDLE/Contents"

rm -rf "$BUILD"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "Compiling DockPin..."
swiftc \
    -swift-version 5 \
    -O \
    -whole-module-optimization \
    -o "$CONTENTS/MacOS/$APP" \
    "$DIR"/Sources/*.swift

cp "$DIR/Info.plist" "$CONTENTS/"
cp "$DIR/DockPin.icns" "$CONTENTS/Resources/"

SIGN_ID="Developer ID Application: Babken Egoian (2H8F6Y6K3V)"

codesign --force --options runtime --sign "$SIGN_ID" "$BUNDLE"

echo ""
echo "Signed: $BUNDLE"
echo "Run:    open build/DockPin.app"
echo ""
echo "To notarize for distribution:"
echo "  ditto -c -k --keepParent build/DockPin.app build/DockPin.zip"
echo "  xcrun notarytool submit build/DockPin.zip --apple-id YOUR_APPLE_ID --team-id 2H8F6Y6K3V --password APP_SPECIFIC_PASSWORD --wait"
echo "  xcrun stapler staple build/DockPin.app"
