#!/usr/bin/env bash
#
# Build, sign, notarize, and publish a ccdeck release.
#
# Usage:
#   ./scripts/release.sh v0.1.0        # tag/version for the GitHub release
#   ./scripts/release.sh v0.1.0 --no-publish   # build + notarize, skip gh release
#
# Pipeline: swift build -> .app (Developer ID + hardened runtime) -> notarize
#           the .app -> staple -> .dmg -> notarize + staple dmg -> gh release.
#
# Requires (via .envrc / direnv):
#   APPLE_ID                          Apple ID email
#   APPLE_ID_APP_SPECIFIC_PASSWORD    app-specific password (appleid.apple.com)
#   GITHUB_TOKEN                      for `gh release` (or be `gh auth login`-ed)
# And a "Developer ID Application" cert in the login keychain.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ccdeck"
TEAM_ID="KY6TQ4484U"
IDENTITY="Developer ID Application: Klu Technologies Oy (${TEAM_ID})"
VERSION="${1:?usage: release.sh <version> [--no-publish], e.g. release.sh v0.1.0}"
PUBLISH=1
[ "${2:-}" = "--no-publish" ] && PUBLISH=0

: "${APPLE_ID:?set APPLE_ID (run: direnv allow .)}"
: "${APPLE_ID_APP_SPECIFIC_PASSWORD:?set APPLE_ID_APP_SPECIFIC_PASSWORD}"

APP="dist/$APP_NAME.app"
DMG="dist/$APP_NAME-$VERSION.dmg"

# 1. Build + sign the bundle with the Developer ID identity (hardened runtime).
CODESIGN_IDENTITY="$IDENTITY" ./scripts/create_app_bundle.sh release

# 2. Notarize the .app (zip it for submission — notarytool wants a flat archive).
echo "==> notarizing $APP"
ditto -c -k --keepParent "$APP" "dist/$APP_NAME-notarize.zip"
xcrun notarytool submit "dist/$APP_NAME-notarize.zip" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APPLE_ID_APP_SPECIFIC_PASSWORD" \
    --wait
rm -f "dist/$APP_NAME-notarize.zip"

# 3. Staple the notarization ticket onto the .app so it verifies offline.
echo "==> stapling $APP"
xcrun stapler staple "$APP"

# 4. Build the DMG from the stapled app.
echo "==> building $DMG"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"

# 5. Notarize + staple the DMG too (so the downloaded artifact itself passes).
echo "==> notarizing $DMG"
xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APPLE_ID_APP_SPECIFIC_PASSWORD" \
    --wait
xcrun stapler staple "$DMG"

# 6. Verify Gatekeeper acceptance locally before shipping.
echo "==> verifying"
spctl -a -t open --context context:primary-signature -v "$DMG" || true
codesign --verify --strict --verbose=2 "$APP"

echo ""
echo "Notarized: $DMG"

if [ "$PUBLISH" = 1 ]; then
    echo "==> publishing GitHub release $VERSION"
    gh release create "$VERSION" "$DMG" \
        --title "$VERSION" \
        --generate-notes
    echo "Published: $(gh release view "$VERSION" --json url -q .url)"
else
    echo "Skipped publish (--no-publish). Upload manually with:"
    echo "  gh release create $VERSION \"$DMG\" --title $VERSION --generate-notes"
fi
