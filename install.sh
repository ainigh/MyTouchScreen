#!/bin/bash
# Installs (or reinstalls) Wisp — GesturePointer.app — into ~/Applications, then opens it. After
# this, updates come from the menu-bar icon (Check for Updates…).
#
#   gh api -H "Accept: application/vnd.github.raw" repos/ainigh/MyTouchScreen/contents/install.sh | bash
#
# The repository is private, so everything goes through gh (GitHub's command line tool), signed in
# (this sets gh up if it's missing). It takes the latest release GitHub built. If there isn't one
# (or WISP_FROM_SOURCE=1), it downloads the source of main (WISP_BRANCH=name for another branch)
# and builds it here with Apple's command line tools. The app then follows that branch for updates.
set -euo pipefail

REPO="ainigh/MyTouchScreen"
BRANCH="${WISP_BRANCH:-main}"
APPS="$HOME/Applications"
NAME="GesturePointer"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname)" == Darwin ]] || die "Wisp is a Mac app (macOS 14 or newer)."
major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$major" -ge 14 ]] || die "Wisp needs macOS 14 (Sonoma) or newer; this Mac has $(sw_vers -productVersion)."

# gh, signed in --------------------------------------------------------------------------------
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do if [[ -x "$b" ]]; then eval "$("$b" shellenv)"; fi; done
if ! command -v gh >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "Needs Homebrew (https://brew.sh) to install gh, then run this again."
  say "Installing gh (GitHub's command line tool)"
  brew install gh
fi
if ! gh api "repos/$REPO" --silent >/dev/null 2>&1; then
  say "Sign in to GitHub with an account that can see $REPO (a browser window opens)"
  gh auth login --web --git-protocol https -h github.com </dev/tty
  gh api "repos/$REPO" --silent >/dev/null 2>&1 || die "That account can't open $REPO."
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# the app: GitHub's build, else built here -----------------------------------------------------
app=""
if [[ "${WISP_FROM_SOURCE:-0}" != 1 && "$BRANCH" == main ]]; then
  say "Downloading the latest release"
  if gh release download --repo "$REPO" --pattern "$NAME.zip" --dir "$tmp" 2>/dev/null; then
    ditto -x -k "$tmp/$NAME.zip" "$tmp/unpacked"
    app="$tmp/unpacked/$NAME.app"
  else
    echo "  No release yet: building it here instead."
  fi
fi

if [[ -z "$app" ]]; then
  xcode-select -p >/dev/null 2>&1 || die "Building needs Apple's command line tools: run xcode-select --install, then this again."
  sha="$(gh api "repos/$REPO/commits/$BRANCH" --jq .sha)" || die "Couldn't find the branch $BRANCH."
  say "Downloading the source ($BRANCH, ${sha:0:7})"
  mkdir -p "$tmp/src"
  gh api "repos/$REPO/tarball/$sha" > "$tmp/src.tar.gz"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components 1
  say "Building (a minute or two)"
  # make-app.sh finds a new-enough Swift (an installed Xcode will do) or says what to update.
  (cd "$tmp/src" && VERSION="1.0-${sha:0:7}" COMMIT="$sha" BRANCH="$BRANCH" scripts/make-app.sh)
  app="$tmp/src/build/$NAME.app"
fi

# install and open -----------------------------------------------------------------------------
# The copy that was here is kept until the new one is seen running: if the new one quits straight
# away, the old one goes back and opens again, so an install never leaves you without Wisp.
say "Installing into $APPS"
[[ -d "$app" ]] || die "The download didn't hold $NAME.app."
pkill -x "$NAME" 2>/dev/null && sleep 1 || true
mkdir -p "$APPS"
previous="$APPS/.$NAME-previous.app"
rm -rf "$previous"
[[ -d "$APPS/$NAME.app" ]] && mv "$APPS/$NAME.app" "$previous"
ditto "$app" "$APPS/$NAME.app"
xattr -dr com.apple.quarantine "$APPS/$NAME.app" 2>/dev/null || true
version="$(defaults read "$APPS/$NAME.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
open "$APPS/$NAME.app"

# Still running a few seconds on: it started.
started=0
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  if pgrep -x "$NAME" >/dev/null; then started=1; else started=0; fi
done
if [[ "$started" == 1 ]]; then
  rm -rf "$previous"
  say "Done (Wisp $version): look for the hand icon in the menu bar."
  echo "  First time (or after an update)? Wisp's Setup window asks for Camera, then Accessibility."
  echo "  If clicks don't work after an update: System Settings → Privacy & Security → Accessibility,"
  echo "  remove GesturePointer with −, then turn it on again when Wisp asks."
  exit 0
fi

crash="$(ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i "$NAME" | head -1 || true)"
if [[ -d "$previous" ]]; then
  rm -rf "$APPS/$NAME.app"
  mv "$previous" "$APPS/$NAME.app"
  open "$APPS/$NAME.app"
  printf '\n\033[31m%s\033[0m\n' "Wisp $version quit as soon as it opened, so the one you had is back and open again." >&2
else
  printf '\n\033[31m%s\033[0m\n' "Wisp $version quit as soon as it opened." >&2
fi
[[ -n "$crash" ]] && echo "  What went wrong is in ~/Library/Logs/DiagnosticReports/$crash" >&2
echo "  To see it happen: $APPS/$NAME.app/Contents/MacOS/$NAME" >&2
exit 1
