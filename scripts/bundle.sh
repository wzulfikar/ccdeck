#!/usr/bin/env bash
#
# Package the production build into a distributable DMG: dist/ccdeck.dmg
#
# Usage:
#   ./scripts/bundle.sh                 # prod build (build.sh --prod) -> notarize -> dmg
#   ./scripts/bundle.sh --no-build      # dmg from the existing prod build; fails if none
#   ./scripts/bundle.sh --no-notarize   # skip notarization (local dmg testing only —
#                                       # release.sh refuses to publish such a bundle)
#
# Pipeline: prod .app -> notarize .app -> staple -> dmg -> notarize dmg -> staple.
# Notarization requires (via .envrc / direnv):
#   APPLE_ID, APPLE_ID_APP_SPECIFIC_PASSWORD
# and the "Developer ID Application" cert in the login keychain.
#
# Writes dist/.bundle.manifest (version, sha, notarized) — release.sh --no-bundle
# uses it to release exactly what was bundled and to refuse un-notarized dmgs.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ccdeck"          # internal: artifact basename
APP_BUNDLE="CC Deck"       # user-facing: .app folder + DMG volume name
TEAM_ID="KY6TQ4484U"
IDENTITY="Developer ID Application: Klu Technologies Oy (${TEAM_ID})"

BUILD=1
NOTARIZE=1
for arg in "$@"; do
    case "$arg" in
        --no-build)    BUILD=0 ;;
        --no-notarize) NOTARIZE=0 ;;
        *)
            echo "usage: $0 [--no-build] [--no-notarize]" >&2
            exit 2
            ;;
    esac
done

APP="dist/$APP_BUNDLE.app"
# Versionless dmg name so /releases/latest/download/ccdeck.dmg stays a stable URL.
DMG="dist/$APP_NAME.dmg"
BUILD_MANIFEST="dist/.prod-build.manifest"

if [ "$BUILD" = 1 ]; then
    if [ "$NOTARIZE" = 1 ]; then
        # Notarization ONLY accepts a "Developer ID Application" cert — force it,
        # overriding any CODESIGN_IDENTITY in the environment (e.g. an "Apple
        # Development" identity from .envrc, which notarization rejects).
        CODESIGN_IDENTITY="$IDENTITY" ./scripts/build.sh --prod
    else
        ./scripts/build.sh --prod
    fi
else
    if [ ! -d "$APP" ] || [ ! -f "$BUILD_MANIFEST" ]; then
        echo "error: no production build found (missing \"$APP\" or $BUILD_MANIFEST)" >&2
        echo "       run: ./scripts/build.sh --prod   (or drop --no-build)" >&2
        exit 1
    fi
    # Staleness guard: warn (not fail — --no-build is an explicit override) when
    # the existing build doesn't match the current HEAD.
    HEAD="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    MSHA="$(sed -n 's/^sha=//p' "$BUILD_MANIFEST")"
    if [ "$MSHA" != "$HEAD" ]; then
        echo "warning: prod build is from ${MSHA:0:7} but HEAD is ${HEAD:0:7} — bundling it anyway (--no-build)" >&2
    fi
fi

if [ "$NOTARIZE" = 1 ]; then
    : "${APPLE_ID:?set APPLE_ID (run: direnv allow .)}"
    : "${APPLE_ID_APP_SPECIFIC_PASSWORD:?set APPLE_ID_APP_SPECIFIC_PASSWORD}"

    # Notarize the .app (zip for submission — notarytool wants a flat archive).
    echo "==> notarizing $APP"
    ditto -c -k --keepParent "$APP" "dist/$APP_NAME-notarize.zip"
    xcrun notarytool submit "dist/$APP_NAME-notarize.zip" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APPLE_ID_APP_SPECIFIC_PASSWORD" \
        --wait
    rm -f "dist/$APP_NAME-notarize.zip"

    echo "==> stapling $APP"
    xcrun stapler staple "$APP"
fi

echo "==> building $DMG"
rm -f "$DMG"

# Decorated DMG: stage the .app next to an /Applications symlink, arrange the
# icons in a fixed window so the user can drag CC Deck onto Applications.
# Dependency-free (hdiutil + Finder AppleScript); an optional background image
# at scripts/utils/dmg-background.png (or @2x) is used if present.
STAGING="dist/.dmg-staging"
RW_DMG="dist/.$APP_NAME-rw.dmg"
DMG_BG="scripts/utils/dmg-background.png"

rm -rf "$STAGING" "$RW_DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
if [ -f "$DMG_BG" ]; then
    mkdir -p "$STAGING/.background"
    cp "$DMG_BG" "$STAGING/.background/background.png"
    [ -f "scripts/utils/dmg-background@2x.png" ] && cp "scripts/utils/dmg-background@2x.png" "$STAGING/.background/background@2x.png"
fi

# Read-write DMG we can mount and decorate, then compress into the final one.
hdiutil create -volname "$APP_BUNDLE" -srcfolder "$STAGING" -ov \
    -fs HFS+ -format UDRW "$RW_DMG" >/dev/null

MOUNT_DIR="/Volumes/$APP_BUNDLE"
# Detach any stale mount, then mount fresh.
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen >/dev/null

# Finder needs a moment after mount before it will accept window scripting.
sleep 2

osascript <<EOF
tell application "Finder"
    tell disk "$APP_BUNDLE"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        if exists file ".background:background.png" then
            set background picture of theViewOptions to file ".background:background.png"
        end if
        set position of item "$APP_BUNDLE.app" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
EOF

# Flush Finder's .DS_Store to disk before detaching.
sync
hdiutil detach "$MOUNT_DIR" >/dev/null

# Compress the decorated RW image into the final distributable DMG.
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
rm -rf "$STAGING" "$RW_DMG"

if [ "$NOTARIZE" = 1 ]; then
    # Notarize + staple the DMG too, so the downloaded artifact itself passes.
    echo "==> notarizing $DMG"
    xcrun notarytool submit "$DMG" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APPLE_ID_APP_SPECIFIC_PASSWORD" \
        --wait
    xcrun stapler staple "$DMG"

    echo "==> verifying"
    spctl -a -t open --context context:primary-signature -v "$DMG" || true
    codesign --verify --strict --verbose=2 "$APP"
fi

# Manifest for release.sh --no-bundle: release exactly what was bundled here.
VERSION="$(sed -n 's/^version=//p' "$BUILD_MANIFEST" 2>/dev/null || true)"
[ -n "$VERSION" ] || VERSION="$(tr -d '[:space:]' < version.txt)"
SHA="$(sed -n 's/^sha=//p' "$BUILD_MANIFEST" 2>/dev/null || true)"
[ -n "$SHA" ] || SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
cat > dist/.bundle.manifest <<EOF
version=$VERSION
sha=$SHA
notarized=$NOTARIZE
bundled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo ""
echo "Bundled: $DMG (version $VERSION, notarized=$NOTARIZE)"
if [ "$NOTARIZE" = 0 ]; then
    echo "note: built with --no-notarize — for local testing only; release.sh will refuse it."
fi
