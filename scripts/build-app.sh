#!/bin/bash
# Builds "The Thinking Notebook.app" into ./build using only the Swift toolchain (no Xcode needed).
#   ./scripts/build-app.sh          release build for this Mac
#   ./scripts/build-app.sh --open   build, then launch
# Environment:
#   VERSION=1.2.3     version shown in Finder / About (default 0.1.0)
#   BUILD_NUMBER=42   build number (default 1)
#   UNIVERSAL=1       one binary for Apple silicon and Intel (needs full Xcode, as on CI)
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="The Thinking Notebook"
EXEC="TheThinkingNotebook"
APP="build/$NAME.app"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/$EXEC"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>app.thethinkingnotebook</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: required to run on Apple silicon. Not a Developer ID, so not notarized.
# Extended attributes (Finder info, provenance) break strict signature checks, so drop them first.
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/$EXEC"))"

if [ "${1:-}" = "--open" ]; then open "$APP"; fi
