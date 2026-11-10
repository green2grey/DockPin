#!/bin/bash
# Builds and signs a DockPin release into build/, ready to notarize and publish.
#
#   ./build.sh               build, sign, verify, zip, and sign the zip for the update feed
#   ./build.sh --notarize    the same, with notarization and stapling before the zip is made
#
# What it needs on this Mac:
#   - a "Developer ID Application" certificate for team 2H8F6Y6K3V in the keychain
#   - the Sparkle update-signing key in the keychain (created with Sparkle's generate_keys),
#     matching SUPublicEDKey in Info.plist
#   - for --notarize: a notarytool keychain profile, created once with
#       xcrun notarytool store-credentials DockPin --apple-id <Apple ID> --team-id 2H8F6Y6K3V
#
# Optional environment:
#   DOCKPIN_SIGN_ID          signing identity (default: the Developer ID Application identity found)
#   DOCKPIN_NOTARY_PROFILE   notarytool keychain profile (default: DockPin)
#   DOCKPIN_ARCHS            architectures to build (default: arm64), e.g. "arm64 x86_64"
#
# For a build to try locally, with no Developer ID needed, use build-dev.sh instead.
set -euo pipefail

APP="DockPin"
BUNDLE_ID="com.green2grey.DockPin"
# Installed copies accept an update only if it is signed by this team (see "update check" below).
TEAM_ID="2H8F6Y6K3V"

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
BUILD="$DIR/build"
BUNDLE="$BUILD/$APP.app"
CONTENTS="$BUNDLE/Contents"
ZIP="$BUILD/$APP.zip"
SPARKLE_BIN="$DIR/.build/artifacts/sparkle/Sparkle/bin"
NOTARY_PROFILE="${DOCKPIN_NOTARY_PROFILE:-DockPin}"
ARCHS="${DOCKPIN_ARCHS:-arm64}"

NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --notarize) NOTARIZE=1 ;;
        *) echo "error: unknown option $arg" >&2; exit 2 ;;
    esac
done

fail() {
    echo "error: $*" >&2
    exit 1
}

# The lines of one version's entry in CHANGELOG.md, as written.
release_notes_markdown() {
    awk -v version="$1" '/^## / { current = ($2 == version); next } current' "$DIR/CHANGELOG.md" \
        | awk 'NF { started = 1 } started' \
        | awk '{ lines[NR] = $0 } NF { last = NR } END { for (i = 1; i <= last; i++) print lines[i] }'
}

# The same entry as HTML, for the update feed: "### Section" becomes a heading and "- item" a
# list item. That is all the Markdown the changelog uses.
release_notes_html() {
    awk -v version="$1" '
        function escape(text) {
            gsub(/&/, "\\&amp;", text); gsub(/</, "\\&lt;", text); gsub(/>/, "\\&gt;", text)
            return text
        }
        function close_list() { if (in_list) { print "</ul>"; in_list = 0 } }
        /^## /   { close_list(); current = ($2 == version); next }
        !current { next }
        /^### /  { close_list(); print "<h3>" escape(substr($0, 5)) "</h3>"; next }
        /^[-*] / { if (!in_list) { print "<ul>"; in_list = 1 } print "<li>" escape(substr($0, 3)) "</li>"; next }
        END      { close_list() }
    ' "$DIR/CHANGELOG.md"
}

# ── Preflight ───────────────────────────────────────────────────────────────

SIGN_ID="${DOCKPIN_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
fi
[ -n "$SIGN_ID" ] || fail "no Developer ID Application identity in the keychain (or set DOCKPIN_SIGN_ID)"
security find-identity -v -p codesigning | grep -Fq "$SIGN_ID" \
    || fail "signing identity not found or not valid: $SIGN_ID"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

if [ "$NOTARIZE" = 1 ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "notarytool profile \"$NOTARY_PROFILE\" is missing or not working (see the top of this script)"
fi

# People are shown what's new when they're offered an update, so a release needs an entry.
NOTES_HTML="$(release_notes_html "$VERSION")"
[ -n "$NOTES_HTML" ] || fail "CHANGELOG.md has no entry for version $VERSION (add a \"## $VERSION\" section)"

echo "Building $APP $VERSION ($BUILD_NUMBER) for $ARCHS, signing as: $SIGN_ID"

# ── Build ───────────────────────────────────────────────────────────────────

# SwiftPM's default build engine doesn't pass the SDK version to the linker, which then stamps
# the binary as built against the deployment target, and AppKit decides how an app behaves from
# that stamp. State both versions explicitly.
BUILD_FLAGS=(-c release -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_OS" -Xlinker "$SDK_VERSION")
for arch in $ARCHS; do
    BUILD_FLAGS+=(--arch "$arch")
done

swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

[ -x "$BIN_PATH/$APP" ] || fail "built executable not found at $BIN_PATH/$APP"
[ -d "$BIN_PATH/Sparkle.framework" ] || fail "Sparkle.framework not found in $BIN_PATH"

# ── Assemble the bundle ─────────────────────────────────────────────────────

# Only this script's own outputs are replaced; build/ may also hold a dev build.
rm -rf "$BUNDLE" "$ZIP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

cp "$BIN_PATH/$APP" "$CONTENTS/MacOS/"
cp "$DIR/Info.plist" "$CONTENTS/"
cp "$DIR/DockPin.icns" "$CONTENTS/Resources/"
cp "$DIR/CHANGELOG.md" "$CONTENTS/Resources/"
# ditto keeps the framework's symlinks and permissions intact; cp -R can break them.
ditto "$BIN_PATH/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"

# The executable should look for frameworks inside the bundle, and nowhere on the build machine.
EXECUTABLE="$CONTENTS/MacOS/$APP"
otool -l "$EXECUTABLE" | awk '/LC_RPATH/{getline; getline; print $2}' | sort -u | while read -r rpath; do
    case "$rpath" in
        @*|/usr/lib/swift) ;;
        *) install_name_tool -delete_rpath "$rpath" "$EXECUTABLE" ;;
    esac
done
if ! otool -l "$EXECUTABLE" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$EXECUTABLE"
fi

# ── Sign, inside out ────────────────────────────────────────────────────────

SIGN=(codesign --force --timestamp --options runtime --sign "$SIGN_ID")
SPARKLE="$CONTENTS/Frameworks/Sparkle.framework/Versions/Current"

for service in "$SPARKLE"/XPCServices/*.xpc; do
    [ -e "$service" ] || continue
    # Sparkle's downloader service may carry entitlements, which must survive re-signing.
    "${SIGN[@]}" --preserve-metadata=entitlements "$service"
done
[ -e "$SPARKLE/Autoupdate" ] && "${SIGN[@]}" "$SPARKLE/Autoupdate"
[ -e "$SPARKLE/Updater.app" ] && "${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$CONTENTS/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$BUNDLE"

# ── Verify ──────────────────────────────────────────────────────────────────

codesign --verify --deep --strict "$BUNDLE"

# Update check: Sparkle in an installed copy accepts an update if it is signed with the update
# key that copy knows, or by the same Developer ID team. The second route is what carries users
# across a change of update key, so a build from any other team must never ship.
codesign --verify -R="identifier \"$BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" "$BUNDLE" \
    || fail "the bundle is not signed as $BUNDLE_ID by team $TEAM_ID; installed copies would refuse it"

STAMP="$(vtool -show-build "$EXECUTABLE" | awk '/sdk/{print $2}' | sort -u | tr '\n' ' ')"
case " $STAMP" in
    *" $MIN_OS "*) fail "the executable is stamped as built against SDK $MIN_OS; the linker flag fix did not take" ;;
esac

# ── Notarize ────────────────────────────────────────────────────────────────

if [ "$NOTARIZE" = 1 ]; then
    echo "Submitting to Apple for notarization (this usually takes a few minutes)..."
    SUBMISSION="$BUILD/$APP-notarize.zip"
    COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc "$BUNDLE" "$SUBMISSION"
    xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$SUBMISSION"
    xcrun stapler staple "$BUNDLE"
    xcrun stapler validate "$BUNDLE"
    spctl --assess --type execute --verbose=2 "$BUNDLE"
fi

# ── Package for the update feed ─────────────────────────────────────────────

# The zip is made last, from the final bundle, so the update signature and length describe
# exactly the file that gets uploaded.
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc "$BUNDLE" "$ZIP"

PLIST_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Info.plist)"
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)"
[ -n "$KEYCHAIN_KEY" ] || fail "no Sparkle update key in the keychain; create one with $SPARKLE_BIN/generate_keys"
[ "$PLIST_KEY" = "$KEYCHAIN_KEY" ] \
    || fail "SUPublicEDKey in Info.plist does not match the update key in the keychain; this build could never be updated"

ENCLOSURE_ATTRIBUTES="$("$SPARKLE_BIN/sign_update" "$ZIP")"

# An Apple-silicon-only build says so in the feed, so Intel Macs aren't offered an update they
# can't run.
HARDWARE_REQUIREMENT=""
if ! lipo -archs "$EXECUTABLE" | grep -qw x86_64; then
    HARDWARE_REQUIREMENT=$'\n            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>'
fi

# What people see when they are offered this update. The small stylesheet is for the update
# window in DockPin 2.1 and earlier, which shows this HTML as it is; later versions read the
# list items and draw them themselves.
ITEM="$BUILD/appcast-item.xml"
cat > "$ITEM" <<ITEM_END
        <item>
            <title>$VERSION</title>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>$HARDWARE_REQUIREMENT
            <sparkle:fullReleaseNotesLink>https://github.com/green2grey/DockPin/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
            <description><![CDATA[
<style>:root{color-scheme:light dark}body{font:13px -apple-system,sans-serif;margin:14px}h3{font-size:13px;margin:14px 0 4px}h3:first-of-type{margin-top:0}ul{margin:0;padding-left:18px}li{margin:3px 0}</style>
$NOTES_HTML
]]></description>
            <enclosure url="https://github.com/green2grey/DockPin/releases/download/v$VERSION/$APP.zip" type="application/octet-stream" $ENCLOSURE_ATTRIBUTES/>
        </item>
ITEM_END
{
    printf '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>\n'
    cat "$ITEM"
    printf '</channel></rss>\n'
} | xmllint --noout - || fail "the generated appcast entry is not well-formed XML"

# The same notes as Markdown, for the GitHub release page.
release_notes_markdown "$VERSION" > "$BUILD/release-notes.md"

echo ""
echo "Built:    $BUNDLE"
echo "Archive:  $ZIP"
echo "Archs:    $(lipo -archs "$EXECUTABLE")   SDK stamp: $STAMP"
if [ "$NOTARIZE" = 1 ]; then
    echo "Notarized and stapled."
else
    echo "NOT notarized. Run ./build.sh --notarize before publishing."
fi
echo ""
echo "Release notes for the GitHub release:  $BUILD/release-notes.md"
echo "Entry to add to docs/appcast.xml:      $ITEM"
echo "(publish the appcast only after the zip is uploaded to the release)"
