#!/bin/bash
set -euo pipefail

APP="DockPin"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
BUNDLE="$BUILD/$APP.app"
CONTENTS="$BUNDLE/Contents"
SIGN_ID="${DOCKPIN_SIGN_ID:?Set DOCKPIN_SIGN_ID to your Developer ID signing identity}"

if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_ID"; then
    echo "ERROR: signing identity not found: $SIGN_ID" >&2
    echo "Available code signing identities:" >&2
    security find-identity -v -p codesigning >&2
    exit 1
fi

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
SPARKLE_FW=$(find .build -name "Sparkle.framework" -type d 2>/dev/null | head -n 1)
if [ -n "$SPARKLE_FW" ]; then
    echo "Embedding Sparkle.framework..."
    ditto "$SPARKLE_FW" "$CONTENTS/Frameworks/Sparkle.framework"

    # Sign nested components inside-out.
    # Sparkle contains: Autoupdate (CLI tool, no extension), Updater.app, and
    # possibly XPC services. All must be signed before the framework itself.
    find "$CONTENTS/Frameworks/Sparkle.framework" \
        \( -name "*.xpc" -o -name "*.app" \) -print0 | \
        xargs -0 -I {} codesign --force --timestamp --options runtime --sign "$SIGN_ID" "{}"

    # Sign the Autoupdate helper (no file extension — not caught by the glob above)
    if [ -f "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Autoupdate" ]; then
        codesign --force --timestamp --options runtime --sign "$SIGN_ID" \
            "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    fi

    # Sign the framework itself
    codesign --force --timestamp --options runtime --sign "$SIGN_ID" \
        "$CONTENTS/Frameworks/Sparkle.framework"

    codesign --verify --deep --strict --verbose=2 "$CONTENTS/Frameworks/Sparkle.framework"
else
    echo "ERROR: Sparkle.framework not found in .build output." >&2
    exit 1
fi

# Sign the app bundle (must be last)
codesign --force --timestamp --strict --options runtime --sign "$SIGN_ID" "$BUNDLE"
codesign --verify --deep --strict --verbose=2 "$BUNDLE"

if [ -n "${DOCKPIN_NOTARY_PROFILE:-}" ]; then
    ZIP="$BUILD/$APP.zip"
    echo "Submitting DockPin for notarization..."
    COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc "$BUNDLE" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$DOCKPIN_NOTARY_PROFILE" --wait
    xcrun stapler staple "$BUNDLE"
else
    echo "Skipping notarization; set DOCKPIN_NOTARY_PROFILE to a notarytool keychain profile to enable it."
fi

echo ""
echo "Signed: $BUNDLE"
echo "Run:    open build/DockPin.app"
