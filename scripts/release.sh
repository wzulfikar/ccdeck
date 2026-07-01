#!/usr/bin/env bash
#
# Build, sign, notarize, and publish a ccdeck release.
#
# Usage:
#   ./scripts/release.sh                # bump patch in version.txt (v0.1.0 -> v0.1.1)
#   ./scripts/release.sh v0.2.0         # use an explicit version
#   ./scripts/release.sh --no-publish   # build + notarize, skip gh release
#
# On each run it writes the resolved version to version.txt, commits it, and tags
# the commit `vX.Y.Z` — so the app (which reads version.txt at build time) and the
# GitHub release always agree.
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

APP_NAME="ccdeck"          # internal: executable, artifacts, bundle-id leaf
APP_BUNDLE="CC Deck"       # user-facing: .app folder + DMG volume name
TEAM_ID="KY6TQ4484U"
IDENTITY="Developer ID Application: Klu Technologies Oy (${TEAM_ID})"
# Version is optional: with no explicit version we bump the patch of version.txt.
# --no-publish may appear in either position, so parse args positionally.
VERSION=""
PUBLISH=1
for arg in "$@"; do
    case "$arg" in
        --no-publish) PUBLISH=0 ;;
        *) VERSION="$arg" ;;
    esac
done

# vX.Y.Z -> vX.Y.(Z+1)
bump_patch() {
    local v="${1#v}"
    local major minor patch
    IFS=. read -r major minor patch <<<"$v"
    echo "v${major}.${minor}.$((patch + 1))"
}

if [ -z "$VERSION" ]; then
    current="v0.1.0"
    [ -f version.txt ] && current="$(tr -d '[:space:]' < version.txt)"
    # An -rc suffix means "promote this exact version to final": drop the suffix
    # without bumping. Otherwise bump the patch as usual.
    case "$current" in
        *-rc) VERSION="${current%-rc}" ;;
        *) VERSION="$(bump_patch "$current")" ;;
    esac
fi
# Normalize to a leading "v".
[ "${VERSION#v}" = "$VERSION" ] && VERSION="v$VERSION"

# Refuse to clobber an existing tag (would desync the app version and the release).
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    echo "error: tag $VERSION already exists — pass a higher version" >&2
    exit 1
fi

# Persist, commit, and tag so the tagged commit carries the exact version the app shows.
echo "==> version $VERSION (writing version.txt + tagging)"
printf '%s\n' "$VERSION" >version.txt
git add version.txt
git commit -m "release $VERSION" >/dev/null
git tag "$VERSION"

: "${APPLE_ID:?set APPLE_ID (run: direnv allow .)}"
: "${APPLE_ID_APP_SPECIFIC_PASSWORD:?set APPLE_ID_APP_SPECIFIC_PASSWORD}"

APP="dist/$APP_BUNDLE.app"
# Versionless name so `/releases/latest/download/ccdeck.dmg` is a stable URL
# that never breaks across releases. Kept lowercase/space-free for a clean URL —
# only the DMG volume + the .app inside it carry the "CC Deck" display name.
DMG="dist/$APP_NAME.dmg"

# 1. Build + sign the bundle with the Developer ID identity (hardened runtime).
CODESIGN_IDENTITY="$IDENTITY" VERSION="$VERSION" ./scripts/create_app_bundle.sh release

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
hdiutil create -volname "$APP_BUNDLE" -srcfolder "$APP" -ov -format UDZO "$DMG"

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
    # Push the release commit + its tag, then cut the release from that exact tag.
    git push
    git push origin "$VERSION"
    gh release create "$VERSION" "$DMG" \
        --title "$VERSION" \
        --verify-tag \
        --generate-notes
    echo "Published: $(gh release view "$VERSION" --json url -q .url)"

    # 7. Generate + sign the Sparkle appcast and attach it to the release. The app's
    #    feed URL is /releases/latest/download/appcast.xml, which always resolves to
    #    the newest release's asset — so uploading a fresh single-entry appcast here
    #    is enough for existing installs to see this version. generate_appcast reads
    #    the EdDSA private key from the login Keychain (put there once by generate_keys;
    #    see docs/auto-update.md). No key → skip, don't fail the release.
    GEN_APPCAST="$(find .build/artifacts -type f -name generate_appcast 2>/dev/null | head -1)"
    [ -z "$GEN_APPCAST" ] && GEN_APPCAST="$(command -v generate_appcast || true)"
    if [ -n "$GEN_APPCAST" ]; then
        echo "==> generating appcast"
        APPCAST_DIR="dist/appcast"
        rm -rf "$APPCAST_DIR"
        mkdir -p "$APPCAST_DIR"
        cp "$DMG" "$APPCAST_DIR/"
        # Every item in this run gets the same prefix; the folder holds only this
        # version's DMG, so the enclosure URL points at this release's asset.
        "$GEN_APPCAST" \
            --download-url-prefix "https://github.com/wzulfikar/$APP_NAME/releases/download/$VERSION/" \
            "$APPCAST_DIR"
        gh release upload "$VERSION" "$APPCAST_DIR/appcast.xml" --clobber
        echo "Appcast attached: $APPCAST_DIR/appcast.xml"
    else
        echo "warning: generate_appcast not found — skipping appcast (auto-update feed not updated)" >&2
    fi

    # 8. Update the Homebrew cask (git submodule) to point at this release and
    #    record the new submodule commit in this superproject.
    CASK="homebrew-tap/Casks/$APP_NAME.rb"
    if [ -f "$CASK" ]; then
        echo "==> updating cask $CASK"
        DMG_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
        CASK_VERSION="${VERSION#v}"
        sed -i '' \
            -e "s/^  version \".*\"/  version \"$CASK_VERSION\"/" \
            -e "s/^  sha256 \".*\"/  sha256 \"$DMG_SHA\"/" \
            "$CASK"
        git -C homebrew-tap add "Casks/$APP_NAME.rb"
        git -C homebrew-tap commit -m "$APP_NAME $VERSION" >/dev/null
        git -C homebrew-tap push
        git add homebrew-tap
        git commit -m "bump homebrew-tap to $APP_NAME $VERSION" >/dev/null
        git push
        echo "Cask updated: $CASK_VERSION ($DMG_SHA)"
    else
        echo "warning: $CASK not found — skipping cask update" >&2
    fi
else
    echo "Skipped publish (--no-publish). Commit + tag $VERSION are local."
    echo "Publish later with:"
    echo "  git push && git push origin $VERSION"
    echo "  gh release create $VERSION \"$DMG\" --title $VERSION --verify-tag --generate-notes"
fi
