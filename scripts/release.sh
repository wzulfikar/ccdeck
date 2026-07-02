#!/usr/bin/env bash
#
# Publish a ccdeck release: bundle (prod build -> notarized dmg) -> GitHub
# release -> Sparkle appcast -> Homebrew cask.
#
# Usage:
#   ./scripts/release.sh                # bump patch from the latest git tag
#   ./scripts/release.sh v0.2.0         # explicit version
#   ./scripts/release.sh --no-bundle    # publish the existing dist/ccdeck.dmg
#                                       # (at the version it was bundled with)
#   ./scripts/release.sh --dry-run      # print every publish step, execute none
#
# Failure-friendly ordering: artifacts are built + notarized FIRST; the version
# commit, tag, and pushes only happen once the dmg exists. A failed run leaves no
# tag or commit behind — just rerun. (The version bump is based on the latest git
# tag, not version.txt, so a rerun after a mid-release failure doesn't double-bump.)
#
# Requires (via .envrc / direnv):
#   APPLE_ID, APPLE_ID_APP_SPECIFIC_PASSWORD   (notarization — see bundle.sh)
#   GITHUB_TOKEN                               (or be `gh auth login`-ed)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ccdeck"
DMG="dist/$APP_NAME.dmg"
BUNDLE_MANIFEST="dist/.bundle.manifest"

BUNDLE=1
DRY_RUN=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --no-bundle) BUNDLE=0 ;;
        --dry-run)   DRY_RUN=1 ;;
        --no-publish)
            echo "note: --no-publish was replaced by ./scripts/bundle.sh (build + notarize, no publish)" >&2
            exit 2
            ;;
        v[0-9]*|[0-9]*) VERSION="$arg" ;;
        *)
            echo "usage: $0 [vX.Y.Z] [--no-bundle] [--dry-run]" >&2
            exit 2
            ;;
    esac
done

# In dry-run mode, publish commands are printed instead of executed.
run() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "DRY-RUN: $*"
    else
        "$@"
    fi
}

# vX.Y.Z -> vX.Y.(Z+1)
bump_patch() {
    local v="${1#v}" major minor patch
    IFS=. read -r major minor patch <<<"$v"
    echo "v${major}.${minor}.$((patch + 1))"
}

# ---------------------------------------------------------------- resolve version
if [ "$BUNDLE" = 0 ]; then
    # Releasing an existing bundle: the dmg's embedded version is already baked
    # in, so the release version MUST be the one it was bundled with.
    if [ ! -f "$DMG" ] || [ ! -f "$BUNDLE_MANIFEST" ]; then
        echo "error: no bundle found ($DMG / $BUNDLE_MANIFEST) — run ./scripts/bundle.sh first" >&2
        exit 1
    fi
    MVERSION="$(sed -n 's/^version=//p' "$BUNDLE_MANIFEST")"
    NOTARIZED="$(sed -n 's/^notarized=//p' "$BUNDLE_MANIFEST")"
    if [ "$NOTARIZED" != "1" ]; then
        echo "error: existing bundle was built with --no-notarize — rerun ./scripts/bundle.sh before releasing" >&2
        exit 1
    fi
    if [ -n "$VERSION" ] && [ "v${VERSION#v}" != "$MVERSION" ]; then
        echo "error: requested $VERSION but the existing bundle is $MVERSION — rebundle, or drop the version arg" >&2
        exit 1
    fi
    VERSION="$MVERSION"
elif [ -z "$VERSION" ]; then
    # Base the bump on the latest tag so reruns are idempotent. An -rc suffix in
    # version.txt means "promote this exact version to final".
    vt="$(tr -d '[:space:]' < version.txt 2>/dev/null || true)"
    case "$vt" in
        *-rc) VERSION="${vt%-rc}" ;;
        *)
            current="$(git tag -l 'v*' | sort -V | tail -1)"
            [ -n "$current" ] || current="${vt:-v0.1.0}"
            VERSION="$(bump_patch "$current")"
            ;;
    esac
fi
[ "${VERSION#v}" = "$VERSION" ] && VERSION="v$VERSION"

# Refuse to clobber an existing tag (would desync the app version and release).
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    echo "error: tag $VERSION already exists — pass a higher version" >&2
    exit 1
fi

echo "==> releasing $VERSION"

# --------------------------------------------------------------------- 1. bundle
# version.txt is written first so create_app_bundle.sh embeds the release version,
# but it is NOT committed yet — a failure below leaves only a dirty version.txt.
if [ "$BUNDLE" = 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then
        echo "DRY-RUN: write $VERSION to version.txt"
        echo "DRY-RUN: VERSION=$VERSION ./scripts/bundle.sh"
    else
        printf '%s\n' "$VERSION" > version.txt
        VERSION="$VERSION" ./scripts/bundle.sh
    fi
fi

# --------------------------------------------------------------- 2. commit + tag
if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN: git add version.txt && git commit -m \"release $VERSION\" && git tag $VERSION"
else
    printf '%s\n' "$VERSION" > version.txt
    git add version.txt
    # Idempotent rerun: version.txt may already be committed from a prior attempt.
    git diff --cached --quiet || git commit -m "release $VERSION" >/dev/null
    git tag "$VERSION"
fi

# ------------------------------------------------------------ 3. GitHub release
run git push
run git push origin "$VERSION"
run gh release create "$VERSION" "$DMG" \
    --title "$VERSION" \
    --verify-tag \
    --generate-notes
[ "$DRY_RUN" = 1 ] || echo "Published: $(gh release view "$VERSION" --json url -q .url)"

# ------------------------------------------------------------ 4. Sparkle appcast
# The app's feed URL is /releases/latest/download/appcast.xml, so attaching a fresh
# single-entry appcast to this release is enough for existing installs to see it.
# generate_appcast reads the EdDSA private key from the login Keychain (put there
# once by generate_keys; see docs/auto-update.md). No key/tool -> skip, don't fail.
publish_appcast() {
    local gen
    gen="$(find .build/artifacts -type f -name generate_appcast 2>/dev/null | head -1)"
    [ -z "$gen" ] && gen="$(command -v generate_appcast || true)"
    if [ -z "$gen" ]; then
        echo "warning: generate_appcast not found — skipping appcast (auto-update feed not updated)" >&2
        return 0
    fi
    echo "==> generating appcast"
    local dir="dist/appcast"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$DMG" "$dir/"
    "$gen" \
        --download-url-prefix "https://github.com/wzulfikar/$APP_NAME/releases/download/$VERSION/" \
        "$dir"
    gh release upload "$VERSION" "$dir/appcast.xml" --clobber
    echo "Appcast attached: $dir/appcast.xml"
}
if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN: generate_appcast + gh release upload $VERSION appcast.xml"
else
    publish_appcast
fi

# -------------------------------------------------------------- 5. Homebrew cask
# Update the cask (git submodule) to point at this release, then record the new
# submodule commit in this superproject.
publish_cask() {
    local cask="homebrew-tap/Casks/$APP_NAME.rb"
    if [ ! -f "$cask" ]; then
        echo "warning: $cask not found — skipping cask update" >&2
        return 0
    fi
    echo "==> updating cask $cask"
    local sha ver
    sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
    ver="${VERSION#v}"
    sed -i '' \
        -e "s/^  version \".*\"/  version \"$ver\"/" \
        -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" \
        "$cask"
    git -C homebrew-tap add "Casks/$APP_NAME.rb"
    git -C homebrew-tap commit -m "$APP_NAME $VERSION" >/dev/null
    git -C homebrew-tap push
    git add homebrew-tap
    git commit -m "bump homebrew-tap to $APP_NAME $VERSION" >/dev/null
    git push
    echo "Cask updated: $ver ($sha)"
}
if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN: update homebrew-tap/Casks/$APP_NAME.rb (version + sha256), commit + push"
else
    publish_cask
fi

echo ""
if [ "$DRY_RUN" = 1 ]; then
    echo "Dry run complete for $VERSION — nothing was built, committed, tagged, or pushed."
else
    echo "Released $VERSION 🎉"
fi
