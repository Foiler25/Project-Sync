#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${1:-release}"
APP="$ROOT/build/Project Sync.app"

cd "$ROOT"
swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ProjectSync" "$APP/Contents/MacOS/ProjectSync"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"

echo "$APP"
