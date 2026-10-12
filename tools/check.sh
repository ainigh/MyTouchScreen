#!/usr/bin/env bash
# Static checks that must pass before a milestone is ticked. Runs on Linux and macOS.
set -u
cd "$(dirname "$0")/.."
fail=0
note() { printf '  %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; fail=1; }

echo "== No unfinished-work markers in code or scripts"
# Docs that legitimately discuss these words (the instructions themselves) are excluded.
pattern='TODO|FIXME|XXX|placeholder|not implemented|fatalError\("not'
if grep -RInE "$pattern" Sources Tests scripts tools Makefile Info.plist install.sh \
     --exclude=check.sh 2>/dev/null; then
  bad "unfinished-work markers found (above)"
else
  note "none"
fi

echo "== GestureCore imports Foundation only"
imports=$(grep -RhE '^\s*(@testable\s+)?import\s+' Sources/GestureCore | sed -E 's/^\s*(@testable\s+)?import\s+//' | sort -u)
for module in $imports; do
  if [ "$module" != "Foundation" ]; then bad "GestureCore imports $module"; fi
done
[ "$imports" = "Foundation" ] && note "ok"

echo "== Mac files are guarded for Linux builds"
for f in Sources/GesturePointerApp/*.swift; do
  first=$(grep -vE '^\s*(//.*)?$' "$f" | head -n 1)
  case "$first" in
    "#if canImport(AppKit)"*) ;;
    *) bad "$f does not start with #if canImport(AppKit)";;
  esac
done
[ $fail -eq 0 ] && note "ok"

echo "== Info.plist has the required keys"
for key in CFBundleExecutable CFBundleIdentifier LSUIElement NSCameraUsageDescription LSMinimumSystemVersion; do
  grep -q "<key>$key</key>" Info.plist || bad "Info.plist missing $key"
done
grep -A1 '<key>LSUIElement</key>' Info.plist | grep -q '<true/>' || bad "LSUIElement must be true"
grep -A1 '<key>CFBundleExecutable</key>' Info.plist | grep -q '<string>GesturePointer</string>' || bad "CFBundleExecutable must be GesturePointer"
note "checked"

echo "== Scripts are executable"
for s in scripts/make-app.sh tools/check.sh install.sh; do
  [ -x "$s" ] || bad "$s is not executable"
done
note "checked"

if [ $fail -ne 0 ]; then
  echo "check.sh: FAILED"
  exit 1
fi
echo "check.sh: all checks passed"
