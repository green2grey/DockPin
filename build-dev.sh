#!/bin/bash
# Builds "DockPin Dev.app" into build/ for local testing. No Developer ID needed.
#
# The dev copy is deliberately separate from a released DockPin:
#   - its own bundle ID, so its settings and its Accessibility grant are its own
#   - signed with an Apple Development certificate if there is one, otherwise ad-hoc; never
#     with the hardened runtime
#   - automatic update checks off, and a build number no release will exceed
#
# With an Apple Development certificate, macOS recognises each rebuild as the same app and its
# Accessibility grant carries over. An ad-hoc build is tied to the exact binary: after
# rebuilding, if the menu bar icon shows the warning triangle even though "DockPin Dev" is ticked
# in System Settings > Privacy & Security > Accessibility, remove it from that list (select it,
# press "-") and let the app ask again.
set -euo pipefail

APP="DockPin"
DEV_NAME="DockPin Dev"
DEV_BUNDLE_ID="com.green2grey.DockPin.dev"

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
BUNDLE="$DIR/build/$DEV_NAME.app"
CONTENTS="$BUNDLE/Contents"
PLIST="$CONTENTS/Info.plist"

# SwiftPM's default build engine doesn't pass the SDK version to the linker, which then stamps
# the binary as built against the deployment target. State both explicitly.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$DIR/Info.plist")"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
BUILD_FLAGS=(
    -c release
    -Xswiftc -DDOCKPIN_DEV
    -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_OS" -Xlinker "$SDK_VERSION"
)

# Sign with a real identity when one is available: macOS then recognises each rebuild as the same
# app and keeps its Accessibility grant. Set DOCKPIN_DEV_SIGN_ID, or have an "Apple Development"
# certificate in the keychain (Xcode > Settings > Accounts). Otherwise the build is ad-hoc signed.
SIGN_ID="${DOCKPIN_DEV_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
fi
SIGN_ID="${SIGN_ID:--}"

echo "Building $DEV_NAME..."
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

if [ ! -d "$BIN_PATH/Sparkle.framework" ]; then
    echo "error: Sparkle.framework not found in $BIN_PATH" >&2
    exit 1
fi

# Replace a running dev copy rather than rewriting the bundle underneath it.
pkill -f "$DEV_NAME.app/Contents/MacOS/$APP" 2>/dev/null || true

rm -rf "$BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

cp "$BIN_PATH/$APP" "$CONTENTS/MacOS/"
if ! otool -l "$CONTENTS/MacOS/$APP" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$CONTENTS/MacOS/$APP"
fi

cp "$DIR/DockPin.icns" "$CONTENTS/Resources/"
cp "$DIR/CHANGELOG.md" "$CONTENTS/Resources/"
# ditto keeps the framework's symlinks and permissions intact.
ditto "$BIN_PATH/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"

cp "$DIR/Info.plist" "$PLIST"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $DEV_BUNDLE_ID" \
    -c "Set :CFBundleName $DEV_NAME" \
    -c "Set :CFBundleDisplayName $DEV_NAME" \
    -c "Set :CFBundleVersion 999999" \
    -c "Set :CFBundleShortVersionString dev" \
    -c "Set :SUEnableAutomaticChecks false" \
    "$PLIST"

# Inside out. No hardened runtime: an ad-hoc build has no team identity, and library validation
# would refuse to load the embedded framework.
codesign --force --deep --sign "$SIGN_ID" "$CONTENTS/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN_ID" "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"

echo ""
if [ "$SIGN_ID" = "-" ]; then
    echo "Signed: ad-hoc (Accessibility must be granted again after each rebuild)"
else
    echo "Signed: $SIGN_ID"
fi
echo "Built:  $BUNDLE"
echo "Run:    open \"build/$DEV_NAME.app\""
echo "Quit:   pkill -f \"$DEV_NAME.app/Contents/MacOS/$APP\""
