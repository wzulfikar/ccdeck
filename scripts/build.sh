#!/usr/bin/env bash
#
# Build an app bundle you can run locally.
#
# Usage:
#   ./scripts/build.sh          # dev variant  -> "dist/CC Deck (dev).app"
#   ./scripts/build.sh --prod   # prod variant -> "dist/CC Deck.app" (+ manifest)
#
# Dev variant: bundle id com.wzulfikar.ccdeck.dev, debug config, Sparkle disabled
# (a dev build must never auto-update itself into prod). The app derives its
# Keychain service ("ccdeck-dev") and Application Support dir from the bundle id,
# so it is safe to run side by side with the installed production app.
#
# Prod variant: bundle id com.wzulfikar.ccdeck, release config, Sparkle enabled.
# Writes dist/.prod-build.manifest (version + git sha) so bundle.sh / release.sh
# can detect stale artifacts.
set -euo pipefail

cd "$(dirname "$0")/.."

VARIANT="dev"
for arg in "$@"; do
    case "$arg" in
        --prod) VARIANT="prod" ;;
        *)
            echo "usage: $0 [--prod]" >&2
            exit 2
            ;;
    esac
done

if [ "$VARIANT" = "prod" ]; then
    export APP_BUNDLE="CC Deck"
    export BUNDLE_ID="com.wzulfikar.ccdeck"
    export SPARKLE_ENABLED=1
    CONFIG="release"
else
    export APP_BUNDLE="CC Deck (dev)"
    export BUNDLE_ID="com.wzulfikar.ccdeck.dev"
    export SPARKLE_ENABLED=0
    CONFIG="debug"
    # Prefer the self-signed "ccdeck-dev" identity when it exists — a stable
    # identity is what makes the Keychain "Always Allow" decision persist across
    # rebuilds. Falls back to ad-hoc (create_app_bundle.sh prints the warning).
    if [ -z "${CODESIGN_IDENTITY:-}" ] \
        && security find-identity -v -p codesigning 2>/dev/null | grep -q '"ccdeck-dev"'; then
        export CODESIGN_IDENTITY="ccdeck-dev"
    fi
fi

echo "==> build variant: $VARIANT ($BUNDLE_ID)"
./scripts/create_app_bundle.sh "$CONFIG"

# Freshness manifest: lets bundle.sh --no-build and release.sh --no-bundle verify
# they are shipping bits that match the current checkout.
if [ "$VARIANT" = "prod" ]; then
    VERSION="${VERSION:-$(tr -d '[:space:]' < version.txt)}"
    SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    DIRTY=0
    git diff --quiet 2>/dev/null || DIRTY=1
    cat > dist/.prod-build.manifest <<EOF
version=$VERSION
sha=$SHA
dirty=$DIRTY
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    echo "==> wrote dist/.prod-build.manifest ($VERSION @ ${SHA:0:7}, dirty=$DIRTY)"
fi
