#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$PROJECT_DIR/dist/Clean Desk.app"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFT_MODULECACHE_PATH="$BUILD_DIR/ModuleCache"

mkdir -p "$BUILD_DIR/ModuleCache" "$BUILD_DIR/cache" "$BUILD_DIR/config" "$BUILD_DIR/security"
BUILD_OPTIONS=(
  --package-path "$PROJECT_DIR"
  --scratch-path "$BUILD_DIR"
  --cache-path "$BUILD_DIR/cache"
  --config-path "$BUILD_DIR/config"
  --security-path "$BUILD_DIR/security"
  --manifest-cache local
  --disable-sandbox
  --configuration release
)

xcrun swift build "${BUILD_OPTIONS[@]}" --product CleanDesk
BIN_DIR="$(xcrun swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/CleanDesk" "$APP_DIR/Contents/MacOS/CleanDesk"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/CleanDeskMark.svg" "$APP_DIR/Contents/Resources/CleanDeskMark.svg"
cp "$PROJECT_DIR/Resources/Lucide-LICENSE.txt" "$APP_DIR/Contents/Resources/Lucide-LICENSE.txt"
chmod +x "$APP_DIR/Contents/MacOS/CleanDesk"

# Reuse the same native vector renderer for menu, action button, and app icon.
cat "$PROJECT_DIR/Sources/CleanDesk/CleanDeskIcon.swift" "$PROJECT_DIR/scripts/create-icon.swift" \
  > "$BUILD_DIR/create-icon.swift"
xcrun swift -module-cache-path "$BUILD_DIR/ModuleCache" \
  "$BUILD_DIR/create-icon.swift" "$BUILD_DIR/AppIcon.iconset" \
  "$APP_DIR/Contents/Resources/AppIcon.icns"
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
# Finder and the app launcher use the bundle's modification date to notice updates.
touch "$APP_DIR"

printf '\nBuilt: %s\n' "$APP_DIR"
printf 'Run: open "%s"\n' "$APP_DIR"
