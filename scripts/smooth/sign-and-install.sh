#!/usr/bin/env bash
# Ad-hoc sign and install cmux Smooth Next, per BUILD_AND_MAINTAIN.md.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="/Volumes/111360128 Lin Yan Yu/DevCache/xcode-derived/cmux-smoothnext-x27/Build/Products/Release/cmux.app"
STAGE="${TMPDIR:-/tmp}/smoothnext-stage"
APP="$STAGE/cmux Smooth Next.app"
DEST="/Applications/cmux Smooth Next.app"
ENT="${TMPDIR:-/tmp}/smoothnext.entitlements"

[[ -d "$SRC" ]] || { echo "missing build product: $SRC" >&2; exit 1; }

# Never touch the running Smooth app.
case "$DEST" in "/Applications/cmux Smooth.app"|"/Applications/cmux.app") exit 99;; esac

if [[ -e "$STAGE" ]]; then trash "$STAGE"; fi
mkdir -p "$STAGE"
ditto "$SRC" "$APP"

PL="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName cmux Smooth Next" "$PL"
# Belt and braces on top of the updater guard: no scheduled Sparkle checks.
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$PL"
/usr/libexec/PlistBuddy -c "Set :SUAutomaticallyUpdate false" "$PL"

# a. entitlements without the restricted keys
cp "$REPO/cmux.entitlements" "$ENT"
plutil -remove keychain-access-groups "$ENT"
plutil -remove "com.apple.developer.web-browser\.public-key-credential" "$ENT" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.web-browser.public-key-credential" "$ENT"
plutil -p "$ENT"

# b. inside-out: nested bundles deepest first, then loose Mach-O files
while IFS= read -r -d '' b; do
  codesign --force --sign - --timestamp=none "$b"
done < <(find "$APP/Contents" -depth \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' -o -name '*.plugin' -o -name '*.appex' -o -name '*.bundle' \) -print0)

while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    codesign --force --sign - --timestamp=none "$f"
  fi
done < <(find "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/MacOS" -type f -perm -u+x -print0 2>/dev/null)

while IFS= read -r -d '' f; do
  codesign --force --sign - --timestamp=none "$f"
done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.dylib' -print0 2>/dev/null)

# c. the app itself
codesign --force --sign - --timestamp=none --entitlements "$ENT" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# d. install
if [[ -e "$DEST" ]]; then trash "$DEST"; fi
ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --verify --deep --strict "$DEST" && echo "installed: $DEST"
