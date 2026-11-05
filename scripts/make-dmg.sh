#!/bin/bash
# Packs build/The Thinking Notebook.app into a drag-to-Applications disk image.
# Run ./scripts/build-app.sh first. Output: build/TheThinkingNotebook-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="The Thinking Notebook"
APP="build/$NAME.app"
[ -d "$APP" ] || { echo "Missing $APP. Run ./scripts/build-app.sh first." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/TheThinkingNotebook-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# ditto without extended attributes: Finder/iCloud metadata on the bundle breaks its signature check.
ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/$NAME.app"
codesign --verify --deep --strict "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# hdiutil occasionally fails with "Resource busy" on CI runners; retry a few times.
for attempt in 1 2 3 4; do
  if hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null; then
    break
  fi
  [ "$attempt" = 4 ] && { echo "hdiutil failed" >&2; exit 1; }
  sleep 5
done

hdiutil verify "$DMG" >/dev/null
echo "Built: $DMG ($(du -h "$DMG" | cut -f1))"
