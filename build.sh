#!/usr/bin/env bash
# Builds ComfyDraw.app from main.swift. Requires macOS 14+ and the Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")"

APP="ComfyDraw.app"

# The icon is generated from code so the repository stays text-only.
if [ ! -f AppIcon.icns ]; then
    echo "Generating app icon…"
    WORK="$(mktemp -d)"
    ICONSET="$WORK/ComfyDraw.iconset"
    mkdir -p "$ICONSET"
    xcrun swiftc -O Tools/make-icon.swift -o "$WORK/make-icon"
    "$WORK/make-icon" "$ICONSET"
    iconutil -c icns "$ICONSET" -o AppIcon.icns
    rm -rf "$WORK"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -parse-as-library -target arm64-apple-macosx14.0 -O main.swift \
    -o "$APP/Contents/MacOS/ComfyDraw"

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: fine for local use. Distributing to others needs Developer ID + notarization.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built $APP"
