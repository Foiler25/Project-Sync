#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${1:-release}"
OUTPUT_DIR="${APP_OUTPUT_DIR:-$ROOT/build}"
APP="$OUTPUT_DIR/Project Sync.app"

BUILD_ARGS=(-c "$CONFIGURATION")
if [[ -n "${SWIFT_SCRATCH_PATH:-}" ]]; then
  BUILD_ARGS+=(--scratch-path "$SWIFT_SCRATCH_PATH")
fi

cd "$ROOT"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

if [[ ! -d "$BIN_DIR/Sparkle.framework" ]]; then
  echo "error: Sparkle.framework was not produced by Swift Package Manager" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/ProjectSync" "$APP/Contents/MacOS/ProjectSync"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

if ! otool -l "$APP/Contents/MacOS/ProjectSync" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/ProjectSync"
fi

SIGN_IDENTITY="${PROJECT_SYNC_CODE_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "$APP"
