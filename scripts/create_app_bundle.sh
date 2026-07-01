#!/usr/bin/env bash
#
# Package the SPM executable into a proper macOS .app bundle.
#
# Usage:
#   ./scripts/create_app_bundle.sh [debug|release]   (default: release)
#
# Output: "dist/CC Deck.app"
#
# Why a bundle: running the bare SPM binary makes macOS treat the process as a
# non-app, which causes glitches like the spinning wait cursor over the menu bar
# and no proper app identity for the Keychain. A bundle fixes both.
set -euo pipefail

cd "$(dirname "$0")/.."

# APP_NAME is the internal identity — executable filename, helper prefix, artifact
# basename, bundle-id leaf. NEVER user-facing. APP_BUNDLE is the display name: the
# .app folder + CFBundleName/DisplayName that Finder, /Applications, and the Login
# Items "App Background Activity" list show.
APP_NAME="ccdeck"
APP_BUNDLE="CC Deck"
BUNDLE_ID="com.wzulfikar.ccdeck"
CONFIG="${1:-release}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -x "$BIN" ] || {
    echo "error: built binary not found at $BIN" >&2
    exit 1
}

HELPER_NAME="ccdeck-helper"
HELPER_LABEL="$BUNDLE_ID.helper"   # mach service name + LaunchDaemon Label
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
        VERSION="$(tr -d '[:space:]' < version.txt)"
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
    SPARKLE_PUBKEY="$(tr -d '[:space:]' < Resources/sparkle_pubkey.txt)"
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
    [ -e "$FW_V/Autoupdate" ]  && codesign "${SIGN_ARGS[@]}" "$FW_V/Autoupdate"
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
