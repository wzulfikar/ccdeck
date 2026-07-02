#!/usr/bin/env bash
#
# Package the SPM executable into a proper macOS .app bundle.
#
# Usage:
#   ./scripts/create_app_bundle.sh [debug|release]        (default: release)
#   VARIANT=dev ./scripts/create_app_bundle.sh            (dev build, own id)
#
# Output: "dist/CC Deck.app" (prod) or "dist/CC Deck (Dev).app" (dev)
#
# Why a bundle: running the bare SPM binary makes macOS treat the process as a
# non-app, which causes glitches like the spinning wait cursor over the menu bar
# and no proper app identity for the Keychain. A bundle fixes both.
set -euo pipefail

cd "$(dirname "$0")/.."

# APP_NAME is the internal identity — executable filename, helper prefix, artifact
# basename. NEVER user-facing. APP_BUNDLE is the display name: the .app folder +
# CFBundleName/DisplayName that Finder, /Applications, and the Login Items "App
# Background Activity" list show.
APP_NAME="ccdeck"
# Variant knobs (set by scripts/build.sh): defaults produce the production app.
APP_BUNDLE="${APP_BUNDLE:-CC Deck}"
BUNDLE_ID="${BUNDLE_ID:-com.wzulfikar.ccdeck}"
CONFIG="${1:-release}"

# Optional VARIANT=dev|prod shortcut for running this script directly (build.sh
# sets APP_BUNDLE/BUNDLE_ID via env instead and leaves VARIANT unset). Two variants
# coexist on one machine because they use DIFFERENT bundle ids → different daemon
# labels → their privileged helpers never collide. The dev id ends in ".dev" so the
# app's Keychain service ("ccdeck-dev", derived from the bundle id) stays isolated.
# See docs/stay-awake-helper.md and .work/lessons/.
if [ -n "${VARIANT:-}" ]; then
    case "$VARIANT" in
    prod)
        APP_BUNDLE="CC Deck"
        BUNDLE_ID="com.wzulfikar.ccdeck"
        ;;
    dev)
        APP_BUNDLE="CC Deck (dev)"
        BUNDLE_ID="com.wzulfikar.ccdeck.dev"
        ;;
    *)
        echo "error: VARIANT must be 'dev' or 'prod' (got '$VARIANT')" >&2
        exit 1
        ;;
    esac
fi
echo "==> bundle: $APP_BUNDLE ($BUNDLE_ID)"

# The helper's own bundle id is embedded into its binary as an __info_plist Mach-O
# section at compile time (see Package.swift). Regenerate that plist for this
# variant BEFORE `swift build` so the helper's signing identity + runtime-derived
# mach service name match this variant's daemon label. The committed default is the
# prod id, so a prod build leaves the working tree clean.
cat >"Sources/ccdeck-helper/Info.plist" <<HPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>             <string>$BUNDLE_ID.helper</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>$APP_NAME-helper</string>
    <key>CFBundleVersion</key>                <string>1.0</string>
    <key>CFBundleShortVersionString</key>     <string>1.0</string>
</dict>
</plist>
HPLIST

# SPM doesn't track the -sectcreate plist as a build input (and keys incremental
# builds on content hashes, so `touch` won't help), so switching variants wouldn't
# otherwise relink the helper and it'd keep the previous variant's embedded id.
# Delete the helper binary so llbuild must relink it, re-embedding the plist above.
HELPER_NAME="ccdeck-helper"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
rm -f "$BIN_DIR/$HELPER_NAME"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -x "$BIN" ] || {
    echo "error: built binary not found at $BIN" >&2
    exit 1
}

HELPER_NAME="ccdeck-helper"
HELPER_LABEL="$BUNDLE_ID.helper" # mach service name + LaunchDaemon Label
HELPER_BIN="$BIN_DIR/$HELPER_NAME"
[ -x "$HELPER_BIN" ] || {
    echo "error: built helper not found at $HELPER_BIN" >&2
    exit 1
}

APP="dist/$APP_BUNDLE.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Privileged helper (SMAppService daemon): its binary plus the LaunchDaemon plist
# that points launchd at it and publishes the mach service the app connects to.
cp "$HELPER_BIN" "$APP/Contents/MacOS/$HELPER_NAME"
cat >"$APP/Contents/Library/LaunchDaemons/$HELPER_LABEL.plist" <<DPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>                       <string>$HELPER_LABEL</string>
    <key>BundleProgram</key>               <string>Contents/MacOS/$HELPER_NAME</string>
    <key>MachServices</key>
    <dict>
        <key>$HELPER_LABEL</key>           <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>$BUNDLE_ID</string>
    </array>
</dict>
</plist>
DPLIST

# Version precedence: caller-provided $VERSION (from release.sh) > version.txt >
# hardcoded fallback. Never a git hash — the shown version must be a real release tag.
if [ -z "${VERSION:-}" ]; then
    if [ -f version.txt ]; then
        VERSION="$(tr -d '[:space:]' <version.txt)"
    else
        VERSION="v0.1.0"
    fi
fi

# Sparkle compares CFBundleVersion with its version comparator, which expects a
# plain dotted number — a leading "v" (v0.1.2) breaks the comparison. Strip it for
# the plist keys; the in-app label re-adds the "v" for display.
VERSION_NUM="${VERSION#v}"

# Sparkle auto-update feed. The public EdDSA key is read from $SPARKLE_PUBLIC_KEY or
# Resources/sparkle_pubkey.txt. Without it we omit the Sparkle keys entirely so the
# embedded framework stays dormant (see docs/auto-update.md for the one-time setup).
SPARKLE_FEED_URL="https://github.com/wzulfikar/ccdeck/releases/latest/download/appcast.xml"
SPARKLE_PUBKEY="${SPARKLE_PUBLIC_KEY:-}"
if [ -z "$SPARKLE_PUBKEY" ] && [ -f "Resources/sparkle_pubkey.txt" ]; then
    SPARKLE_PUBKEY="$(tr -d '[:space:]' <Resources/sparkle_pubkey.txt)"
fi
# Dev variant (SPARKLE_ENABLED=0): drop the feed entirely so a dev build can
# never auto-update itself into the production app.
if [ "${SPARKLE_ENABLED:-1}" != "1" ]; then
    SPARKLE_PUBKEY=""
    echo "==> Sparkle: disabled for this variant (SPARKLE_ENABLED=0)"
fi
SPARKLE_KEYS=""
if [ -n "$SPARKLE_PUBKEY" ]; then
    SPARKLE_KEYS="    <key>SUFeedURL</key>                 <string>$SPARKLE_FEED_URL</string>
    <key>SUPublicEDKey</key>             <string>$SPARKLE_PUBKEY</string>
    <key>SUEnableAutomaticChecks</key>   <true/>
    <key>SUScheduledCheckInterval</key>  <integer>86400</integer>"
else
    echo "==> Sparkle: no public key (SPARKLE_PUBLIC_KEY / Resources/sparkle_pubkey.txt) — updater dormant"
fi

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_BUNDLE</string>
    <key>CFBundleDisplayName</key>       <string>$APP_BUNDLE</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION_NUM</string>
    <key>CFBundleVersion</key>           <string>$VERSION_NUM</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>MIT License</string>
$SPARKLE_KEYS
    <!-- App controls Dock visibility at runtime (regular when a window is open,
         accessory / menu-bar-only when closed), so no LSUIElement here. -->
</dict>
</plist>
PLIST

# Optional app icon: drop an .icns at Resources/AppIcon.icns to embed it.
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
    echo "==> embedded Resources/AppIcon.icns"
fi

# Embed Sparkle.framework. `swift build` copies the framework (from the binary
# xcframework dependency) into the build bin dir; the app finds it at runtime via
# the @executable_path/../Frameworks rpath set in Package.swift. Signing happens
# below in the inside-out codesign pass.
SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
APP_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    echo "==> embedding Sparkle.framework"
    mkdir -p "$APP/Contents/Frameworks"
    # -R preserves the Versions/Current symlink structure that framework signing needs.
    cp -R "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORK"
else
    echo "warning: $SPARKLE_FRAMEWORK not found — auto-update disabled in this build" >&2
    APP_FRAMEWORK=""
fi

# Trim Sparkle.framework. It ships as a universal (x86_64 + arm64) framework and
# carries dev-time headers plus XPC services that are ONLY used by sandboxed apps.
# We ship Apple-Silicon-only and are NOT sandboxed, so we drop all three. This cuts
# the framework from ~3.0M to ~1.4M. Must run BEFORE the codesign pass below, since
# every edit invalidates the framework's existing seal (we re-sign it afterwards).
# Override the kept arch with SPARKLE_ARCH=x86_64 (or set SPARKLE_NO_TRIM=1 to skip).
if [ -n "$APP_FRAMEWORK" ] && [ -z "${SPARKLE_NO_TRIM:-}" ]; then
    FW_V="$APP_FRAMEWORK/Versions/B"
    KEEP_ARCH="${SPARKLE_ARCH:-arm64}"
    echo "==> trimming Sparkle.framework (arch=$KEEP_ARCH, drop XPCServices + headers)"
    # 1. Thin every universal Mach-O down to the target arch. Skip binaries that are
    #    already single-arch (lipo -thin errors on a non-fat file).
    for macho in "$FW_V/Sparkle" "$FW_V/Autoupdate" "$FW_V/Updater.app/Contents/MacOS/Updater"; do
        [ -f "$macho" ] || continue
        if [ "$(lipo -archs "$macho" 2>/dev/null | wc -w)" -gt 1 ]; then
            lipo "$macho" -thin "$KEEP_ARCH" -output "$macho.thin" && mv "$macho.thin" "$macho"
        fi
    done
    # 2. XPC services are only wired up for sandboxed apps; non-sandboxed Sparkle runs
    #    the installer/downloader in-process, so these are dead weight for us.
    rm -rf "$FW_V/XPCServices"
    # 3. Public/private headers + swiftmodule maps are compile-time only, no runtime use.
    rm -rf "$FW_V/Headers" "$FW_V/PrivateHeaders" "$FW_V/Modules"
    # Drop the now-dangling top-level symlinks so codesign doesn't choke on them.
    rm -f "$APP_FRAMEWORK/XPCServices" "$APP_FRAMEWORK/Headers" \
        "$APP_FRAMEWORK/PrivateHeaders" "$APP_FRAMEWORK/Modules"
fi

# Codesign. A STABLE signing identity is what makes the Keychain "Always Allow"
# decision persist across launches and rebuilds — ad-hoc ("-") changes every build,
# so macOS re-prompts every time. Set CODESIGN_IDENTITY to a stable identity:
#
#   # one-time: create a self-signed code-signing cert named "ccdeck-dev"
#   #   Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…
#   #   Name: ccdeck-dev   Identity Type: Self Signed Root   Type: Code Signing
#   CODESIGN_IDENTITY="ccdeck-dev" ./scripts/create_app_bundle.sh
#
#   # or an Apple-issued identity (from Xcode):
#   CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./scripts/create_app_bundle.sh
#
# List available identities with:  security find-identity -v -p codesigning
IDENTITY="${CODESIGN_IDENTITY:--}"
# Notarization requires the Hardened Runtime + a secure timestamp, and only a
# "Developer ID Application" identity is accepted by Apple's notary service.
# Auto-enable those flags for any Developer ID identity (or force with HARDENED_RUNTIME=1).
#
# NOTE: --deep is intentionally NOT used — the nested privileged helper has its
# own signature/identity and must be signed first (inside-out), then the app.
SIGN_ARGS=(--force --sign "$IDENTITY")
case "${HARDENED_RUNTIME:-}${IDENTITY}" in
1* | *"Developer ID"*)
    SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
    echo "==> codesign (identity: $IDENTITY, hardened runtime + timestamp)"
    ;;
-)
    echo "==> codesign (ad-hoc — Keychain will re-prompt each build; set CODESIGN_IDENTITY for persistence)"
    echo "    WARNING: the 'Stay awake' privileged helper (SMAppService daemon) will"
    echo "    NOT register when ad-hoc signed. Build with a Developer ID identity:"
    echo "      CODESIGN_IDENTITY=\"Developer ID Application: … (TEAMID)\" $0"
    ;;
*)
    echo "==> codesign (identity: $IDENTITY)"
    ;;
esac
# Inside-out signing. Sparkle's nested XPC services + helper tools ship ad-hoc
# signed, so each must be re-signed with our identity (hardened runtime, NO --deep —
# --deep applies one requirement to all nested code and breaks Sparkle) BEFORE the
# framework, which is signed before the helper and app that enclose it.
if [ -n "$APP_FRAMEWORK" ]; then
    echo "==> codesign Sparkle.framework (inside-out)"
    FW_V="$APP_FRAMEWORK/Versions/B"
    for xpc in "$FW_V/XPCServices/Installer.xpc" "$FW_V/XPCServices/Downloader.xpc"; do
        [ -e "$xpc" ] && codesign "${SIGN_ARGS[@]}" "$xpc"
    done
    [ -e "$FW_V/Autoupdate" ] && codesign "${SIGN_ARGS[@]}" "$FW_V/Autoupdate"
    [ -e "$FW_V/Updater.app" ] && codesign "${SIGN_ARGS[@]}" "$FW_V/Updater.app"
    codesign "${SIGN_ARGS[@]}" "$APP_FRAMEWORK"
fi

# Helper first, then the app bundle that contains both it and the framework.
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/$HELPER_NAME"
codesign "${SIGN_ARGS[@]}" "$APP"

echo ""
echo "Built $APP"
echo "Run it:   open \"$APP\""
echo "Install:  cp -R \"$APP\" /Applications/"
