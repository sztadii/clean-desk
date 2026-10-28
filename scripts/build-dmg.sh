#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/Clean Desk.app"
DMG_PATH="$PROJECT_DIR/dist/Clean-Desk.dmg"

"$PROJECT_DIR/scripts/build.sh"

DMG_STAGE_DIR="$(mktemp -d "$PROJECT_DIR/.build/dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ditto "$APP_DIR" "$DMG_STAGE_DIR/Clean Desk.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

hdiutil create \
  -volname "Clean Desk" \
  -srcfolder "$DMG_STAGE_DIR" \
  -format UDZO \
  -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"

printf '\nBuilt DMG: %s\n' "$DMG_PATH"
