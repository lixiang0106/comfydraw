#!/usr/bin/env bash
# Build an Apple Silicon app without replacing an existing application.
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:-ComfyDraw.app}"
PARENT="$(dirname "$APP")"
if [[ "$APP" != *.app ]]; then
    echo "Output path must end in .app: $APP" >&2
    exit 1
fi
if [[ ! -d "$PARENT" ]]; then
    echo "Output parent directory does not exist: $PARENT" >&2
    exit 1
fi
if [[ -e "$APP" || -L "$APP" ]]; then
    echo "Refusing to replace an existing path: $APP" >&2
    echo "Choose another path, for example: ./build.sh /tmp/ComfyDraw-test.app" >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/comfydraw-build.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
STAGED="$WORK/ComfyDraw.app"
ICONSET="$WORK/ComfyDraw.iconset"
mkdir -p "$ICONSET" "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources"

# Always render from the committed source so an older generated icon is not reused.
echo "Generating app icon…"
xcrun swiftc -O Tools/make-icon.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$STAGED/Contents/Resources/AppIcon.icns"

xcrun swiftc -parse-as-library -target arm64-apple-macosx14.0 -O main.swift \
    -framework Security -o "$STAGED/Contents/MacOS/ComfyDraw"
cp Info.plist "$STAGED/Contents/Info.plist"
cp LICENSE "$STAGED/Contents/Resources/LICENSE.txt"

# Ad-hoc signing does not provide Developer ID or Apple notarization.
codesign --force --sign - --timestamp=none "$STAGED"
codesign --verify --deep --strict --verbose=2 "$STAGED"

# mkdir is an exclusive reservation: never move or copy into a pre-existing app.
if ! mkdir "$APP"; then
    echo "Unable to reserve output; an existing path was not modified: $APP" >&2
    exit 1
fi
if ! ditto "$STAGED" "$APP" || ! codesign --verify --deep --strict "$APP"; then
    echo "Build could not be copied or verified. The newly created output may be incomplete: $APP" >&2
    exit 1
fi

echo "Built $APP"
