#!/usr/bin/env bash
# Builds GesturePointer.app from the SwiftPM release binary. No Xcode project involved:
# command-line tools (xcode-select --install) are enough.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="GesturePointer.app"
CONFIG="${CONFIG:-release}"

if [ "$(uname)" != "Darwin" ]; then
  echo "error: make-app.sh must run on macOS (this is $(uname))." >&2
  exit 1
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product GesturePointer
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GesturePointer" "$APP/Contents/MacOS/GesturePointer"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -x scripts/make-sounds.sh ]; then
  echo "==> generating sounds"
  scripts/make-sounds.sh "$APP/Contents/Resources/Sounds"
fi

echo "==> ad-hoc codesigning"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP"

echo "==> done: $(pwd)/$APP"
