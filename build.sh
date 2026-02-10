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

codesign --force --sign - "$BUNDLE"

echo ""
echo "Built: $BUNDLE"
echo "Run:   open build/DockPin.app"
