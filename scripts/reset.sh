#!/usr/bin/env bash
#
# Reset this machine to a clean, pre-ccdeck state — as if you were developing
# (or installing) from scratch.
#
# Usage:
#   ./scripts/reset.sh                    # reset BOTH variants (asks first)
#   ./scripts/reset.sh --dev              # dev variant only (com.wzulfikar.ccdeck.dev)
#   ./scripts/reset.sh --prod             # prod variant only (com.wzulfikar.ccdeck)
#   ./scripts/reset.sh --dry-run          # print everything it would do, touch nothing
#   ./scripts/reset.sh --yes              # skip the confirmation prompt
#   ./scripts/reset.sh --official-creds   # ALSO delete the live "Claude Code-credentials"
#                                         # keychain item (logs Claude Code itself out!)
#
# Per variant it removes:
#   - the running app (graceful quit, then kill)
#   - the "Stay awake" helper daemon (launchctl bootout — needs sudo, prod only)
#   - the .app in /Applications
#   - TCC privacy permissions (tccutil reset All <bundle-id>)
#   - Keychain items under the app's service ("ccdeck" / "ccdeck-dev")
#   - ~/Library/Application Support/<ccdeck|ccdeck-dev>/  (SQLite roster + settings)
#   - defaults / preferences (incl. Sparkle's SULastCheckTime etc.)
#   - caches, HTTPStorages (Sparkle downloads), saved application state
# Plus (both modes): the local dist/ build artifacts.
#
# NOT removed: the "ccdeck-dev" self-signed signing cert (harmless, annoying to
# recreate), and the helper's Background Item entry in System Settings ▸ Login
# Items — macOS drops it on its own once the app is gone; `sfltool resetbtm`
# force-clears ALL background items (every app) if you truly need it gone now.
set -euo pipefail

cd "$(dirname "$0")/.."

DEV=1
PROD=1
OFFICIAL=0
DRY=0
YES=0
for arg in "$@"; do
    case "$arg" in
        --dev)  PROD=0 ;;
        --prod) DEV=0 ;;
        --official-creds) OFFICIAL=1 ;;
        --dry-run) DRY=1; YES=1 ;;
        --yes|-y)  YES=1 ;;
        *)
            echo "usage: $0 [--dev|--prod] [--official-creds] [--dry-run] [--yes]" >&2
            exit 2
            ;;
    esac
done

act() {
    if [ "$DRY" = 1 ]; then
        echo "DRY-RUN: $*"
    else
        "$@"
    fi
}

# ------------------------------------------------------------------ confirmation
targets=""
[ "$DEV" = 1 ]  && targets="$targets dev"
[ "$PROD" = 1 ] && targets="$targets prod"
echo "This resets ccdeck state for:${targets} (apps, permissions, keychain, data, dist/)"
[ "$OFFICIAL" = 1 ] && echo "WARNING: --official-creds will also delete \"Claude Code-credentials\" — Claude Code itself will be logged out."
if [ "$YES" != 1 ]; then
    printf "Type 'yes' to continue: "
    read -r answer
    [ "$answer" = "yes" ] || { echo "aborted"; exit 1; }
fi

# --------------------------------------------------------------------- helpers
quit_app() {
    # Graceful quit by display name, then kill any leftover process by its
    # bundle path (both variants share the executable name "ccdeck", so a plain
    # pkill would take down the other variant too).
    local display="$1" app_dir="$2"
    if [ "$DRY" = 1 ]; then
        echo "DRY-RUN: quit \"$display\" (osascript, then pkill -f \"$app_dir\")"
        return 0
    fi
    osascript -e "tell application \"$display\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -f "$app_dir/Contents/MacOS/" 2>/dev/null || true
}

purge_keychain_service() {
    # One keychain item per managed account — delete until none remain.
    local svc="$1" n=0
    if [ "$DRY" = 1 ]; then
        if security find-generic-password -s "$svc" >/dev/null 2>&1; then
            echo "DRY-RUN: security delete-generic-password -s \"$svc\" (repeat until empty)"
        else
            echo "DRY-RUN: keychain service \"$svc\": nothing to remove"
        fi
        return 0
    fi
    while security delete-generic-password -s "$svc" >/dev/null 2>&1; do
        n=$((n + 1))
    done
    echo "    keychain \"$svc\": removed $n item(s)"
}

reset_variant() {
    local bundle_id="$1" display="$2" svc="$3" data_dir="$4"
    echo "==> resetting $display ($bundle_id)"

    quit_app "$display" "$display.app"

    # "Stay awake" privileged helper (SMAppService LaunchDaemon). Only ever
    # registers for properly signed builds, i.e. prod — bootout is best-effort.
    local helper="system/$bundle_id.helper"
    if launchctl print "$helper" >/dev/null 2>&1; then
        act sudo launchctl bootout "$helper" || true
    fi

    # Privacy/TCC permissions (notifications, automation, etc.).
    if [ "$DRY" = 1 ]; then
        echo "DRY-RUN: tccutil reset All $bundle_id"
    else
        tccutil reset All "$bundle_id" >/dev/null 2>&1 || true
        echo "    TCC permissions reset"
    fi

    # Installed app.
    [ -d "/Applications/$display.app" ] && act rm -rf "/Applications/$display.app"

    # Keychain (the app's own account store — NOT the live Claude Code item).
    purge_keychain_service "$svc"

    # On-disk state.
    local paths=(
        "$HOME/Library/Application Support/$data_dir"
        "$HOME/Library/Caches/$bundle_id"
        "$HOME/Library/HTTPStorages/$bundle_id"
        "$HOME/Library/Saved Application State/$bundle_id.savedState"
    )
    for p in "${paths[@]}"; do
        [ -e "$p" ] && act rm -rf "$p"
    done

    # Preferences / defaults (includes Sparkle's update-check state).
    if [ "$DRY" = 1 ]; then
        echo "DRY-RUN: defaults delete $bundle_id"
    else
        defaults delete "$bundle_id" >/dev/null 2>&1 || true
    fi
}

# ----------------------------------------------------------------------- reset
[ "$DEV" = 1 ]  && reset_variant "com.wzulfikar.ccdeck.dev" "CC Deck (dev)" "ccdeck-dev" "ccdeck-dev"
[ "$PROD" = 1 ] && reset_variant "com.wzulfikar.ccdeck"     "CC Deck"       "ccdeck"     "ccdeck"

# Local build artifacts (regenerable via build.sh).
[ -d dist ] && act rm -rf dist

# The live Claude Code credential — explicit opt-in only.
if [ "$OFFICIAL" = 1 ]; then
    if [ "$DRY" = 1 ]; then
        echo "DRY-RUN: security delete-generic-password -s \"Claude Code-credentials\""
    else
        security delete-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 \
            && echo "    removed \"Claude Code-credentials\" (Claude Code is now logged out)" \
            || echo "    \"Claude Code-credentials\": nothing to remove"
    fi
fi

echo ""
if [ "$DRY" = 1 ]; then
    echo "Dry run complete — nothing was removed."
else
    echo "Reset complete. Start fresh with: ./scripts/build.sh"
fi
