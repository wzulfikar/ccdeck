#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns (blue blueprint-grid squircle + white 50% gauge).
# Usage: ./scripts/utils/create_app_icon.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
swift scripts/utils/create_app_icon.swift
work="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$work"
gen() { sips -z "$1" "$1" /tmp/appicon_1024.png --out "$work/$2" >/dev/null; }
gen 16 icon_16x16.png;    gen 32 icon_16x16@2x.png
gen 32 icon_32x32.png;    gen 64 icon_32x32@2x.png
gen 128 icon_128x128.png; gen 256 icon_128x128@2x.png
gen 256 icon_256x256.png; gen 512 icon_256x256@2x.png
gen 512 icon_512x512.png; cp /tmp/appicon_1024.png "$work/icon_512x512@2x.png"
mkdir -p Resources
iconutil -c icns "$work" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
