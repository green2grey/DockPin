#!/bin/bash
set -euo pipefail

APP="DockPin"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
BUNDLE="$BUILD/$APP.app"
CONTENTS="$BUNDLE/Contents"
SIGN_ID="${DOCKPIN_SIGN_ID:?Set DOCKPIN_SIGN_ID to your Developer ID signing identity}"
APPLE_ID="${DOCKPIN_APPLE_ID:?Set DOCKPIN_APPLE_ID for notarization}"
TEAM_ID="${DOCKPIN_TEAM_ID:?Set DOCKPIN_TEAM_ID for notarization}"

rm -rf "$BUILD"

echo "Building DockPin..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"

# Create app bundle structure
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

# Copy executable and set rpath so it finds embedded frameworks
cp "$BIN_PATH/$APP" "$CONTENTS/MacOS/"
install_name_tool -add_rpath @executable_path/../Frameworks "$CONTENTS/MacOS/$APP"

# Copy resources
cp "$DIR/Info.plist" "$CONTENTS/"
cp "$DIR/DockPin.icns" "$CONTENTS/Resources/"

# Embed Sparkle framework
# IMPORTANT: Use ditto to preserve symlinks and executable permissions.
# Sparkle.framework uses Versions/B/ with symlinks; cp -R may break them.
SPARKLE_FW=$(find .build -name "Sparkle.framework" -type d 2>/dev/null | head -1)
if [ -n "$SPARKLE_FW" ]; then
    echo "Embedding Sparkle.framework..."
    ditto "$SPARKLE_FW" "$CONTENTS/Frameworks/Sparkle.framework"

    # Sign nested components inside-out.
    # Sparkle contains: Autoupdate (CLI tool, no extension), Updater.app, and
    # possibly XPC services. All must be signed before the framework itself.
    find "$CONTENTS/Frameworks/Sparkle.framework" \
        \( -name "*.xpc" -o -name "*.app" \) -print0 | \
        xargs -0 -I {} codesign --force --options runtime --sign "$SIGN_ID" "{}"

    # Sign the Autoupdate helper (no file extension — not caught by the glob above)
    if [ -f "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Autoupdate" ]; then
        codesign --force --options runtime --sign "$SIGN_ID" \
            "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    fi

    # Sign the framework itself
    codesign --force --options runtime --sign "$SIGN_ID" \
        "$CONTENTS/Frameworks/Sparkle.framework"
else
    echo "WARNING: Sparkle.framework not found in .build output."
    echo "The app will build but auto-update will not work."
fi

# Sign the app bundle (must be last)
codesign --force --options runtime --sign "$SIGN_ID" "$BUNDLE"

echo ""
echo "Signed: $BUNDLE"
echo "Run:    open build/DockPin.app"
echo ""
echo "To notarize for distribution:"
echo "  ditto -c -k --keepParent build/DockPin.app build/DockPin.zip"
echo "  xcrun notarytool submit build/DockPin.zip \\"
echo "    --apple-id \$DOCKPIN_APPLE_ID \\"
echo "    --team-id \$DOCKPIN_TEAM_ID \\"
echo "    --password APP_SPECIFIC_PASSWORD --wait"
echo "  xcrun stapler staple build/DockPin.app"
echo ""
echo "Or use a stored keychain profile:"
echo "  xcrun notarytool submit build/DockPin.zip --keychain-profile DockPin --wait"
