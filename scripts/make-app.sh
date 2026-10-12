#!/bin/bash
# Builds build/GesturePointer.app and build/GesturePointer.zip (what a release carries). Needs a
# Mac with Apple's command line tools (xcode-select --install); Xcode itself isn't required.
#
#   scripts/make-app.sh                          a local build
#   VERSION=1.0.7 BRANCH=main scripts/make-app.sh what CI and the updater run
#
# Environment:
#   VERSION              CFBundleShortVersionString (default: from Info.plist, e.g. 1.0)
#   COMMIT               the commit it was built from (default: git HEAD, if this is a checkout)
#   BRANCH               the branch the in-app updater follows (default: main)
#   UNIVERSAL=1          arm64 + x86_64 (CI); default builds only this Mac's architecture
#   WISP_SIGN_IDENTITY   a code-signing identity from your keychain. Optional: with one, macOS
#                        keeps the Camera/Accessibility permissions across updates; without one
#                        the app is ad-hoc signed and macOS may ask again after an update.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=GesturePointer
APP="build/$NAME.app"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist 2>/dev/null || echo 1.0)"
VERSION="${VERSION:-$PLIST_VERSION}"
COMMIT="${COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
BRANCH="${BRANCH:-main}"

if [ "$(uname)" != "Darwin" ]; then
  echo "error: make-app.sh must run on macOS (this is $(uname))." >&2
  exit 1
fi

# The package needs Swift 5.9 or newer (Xcode 15's command line tools). When the Swift on the PATH
# is older and a newer Xcode is installed, build with that Xcode instead.
swift_version() { "$@" --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p' | head -1; }
new_enough() { [ -n "$1" ] && { read -r major minor <<<"$1"; [ "$major" -gt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -ge 9 ]; }; }; }
found="$(swift_version swift || true)"
if ! new_enough "$found"; then
  for dev in /Applications/Xcode*.app/Contents/Developer "$HOME"/Applications/Xcode*.app/Contents/Developer; do
    [ -d "$dev" ] || continue
    v="$(DEVELOPER_DIR="$dev" swift_version xcrun swift || true)"
    if new_enough "$v"; then
      export DEVELOPER_DIR="$dev"
      found="$v"
      echo "==> using Swift ${v/ /.} from $dev"
      break
    fi
  done
fi
if ! new_enough "$found"; then
  have="$(swift --version 2>&1 | head -1 || true)"
  echo "error: building needs Swift 5.9 or newer, and this Mac has: ${have:-no Swift}." >&2
  echo "       Update Apple's command line tools (Software Update, or: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install), then try again." >&2
  exit 3
fi

if [ "${UNIVERSAL:-0}" = 1 ]; then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(); fi

echo "==> swift build -c release ($VERSION, $BRANCH, ${COMMIT:0:7})"
swift build -c release --product "$NAME" ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release --product "$NAME" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

echo "==> assembling $APP"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$NAME" "$APP/Contents/MacOS/$NAME"
cp Info.plist "$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
$PB -c "Add :WispCommit string $COMMIT" "$APP/Contents/Info.plist"
$PB -c "Add :WispBranch string $BRANCH" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -n "${WISP_SIGN_IDENTITY:-}" ]; then
  echo "==> signing with \"$WISP_SIGN_IDENTITY\""
  codesign --force --sign "$WISP_SIGN_IDENTITY" --timestamp=none "$APP"
else
  echo "==> ad-hoc signing"
  codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --verbose=1 "$APP"

ditto -c -k --keepParent "$APP" "build/$NAME.zip"
echo "==> built $(pwd)/$APP ($VERSION, $BRANCH, ${COMMIT:0:7})"
