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
hdiutil create -volname "$APP_BUNDLE" -srcfolder "$APP" -ov -format UDZO "$DMG"

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
