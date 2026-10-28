#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache"
mkdir -p "$BUILD_DIR/ModuleCache" "$BUILD_DIR/cache" "$BUILD_DIR/config" "$BUILD_DIR/security"
xcrun swift test --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" \
  --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" \
  --security-path "$BUILD_DIR/security" --manifest-cache local --disable-sandbox
