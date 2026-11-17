#!/bin/bash
# Builds PurrNotes.app next to this script. Needs only the Xcode Command Line Tools.
#   ./build.sh          build the app
#   ./build.sh run      build, then launch it
set -euo pipefail
cd "$(dirname "$0")"

APP="PurrNotes.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PurrNotes"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PurrNotes"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon is drawn by the app itself, so there are no image assets to keep in sync.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$BIN" --export-iconset "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built $(pwd)/$APP"
if [[ "${1:-}" == "run" ]]; then
    open "$APP"
fi
