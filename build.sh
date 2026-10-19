#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_ROOT="${1:-$PROJECT_DIR/dist}"
BUILD_CACHE="${TMPDIR:-/tmp}/dynamicwallpaper-build"
mkdir -p "$OUTPUT_ROOT" "$BUILD_CACHE/clang" "$BUILD_CACHE/modules" "$BUILD_CACHE/swiftpm" "$BUILD_CACHE/config" "$BUILD_CACHE/security"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"
export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE/modules"
cd "$PROJECT_DIR"
BUILD_OPTIONS=(--disable-sandbox --cache-path "$BUILD_CACHE/swiftpm" --config-path "$BUILD_CACHE/config" --security-path "$BUILD_CACHE/security" --scratch-path "$BUILD_CACHE/package" -c release)
swift build "${BUILD_OPTIONS[@]}" -Xswiftc -debug-prefix-map -Xswiftc "$PROJECT_DIR=." -Xswiftc -file-prefix-map -Xswiftc "$PROJECT_DIR=."
BINARY_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
STAGING_DIR="$(mktemp -d "$OUTPUT_ROOT/.dynamicwallpaper.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/DynamicWallpaper.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BINARY_DIR/DynamicWallpaper" "$APP_DIR/Contents/MacOS/DynamicWallpaper"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
chmod 755 "$APP_DIR/Contents/MacOS/DynamicWallpaper"
strip -S "$APP_DIR/Contents/MacOS/DynamicWallpaper"
codesign --force --sign - "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"
if [ -e "$OUTPUT_ROOT/DynamicWallpaper.app" ]; then
    mv "$OUTPUT_ROOT/DynamicWallpaper.app" "$STAGING_DIR/previous.app"
fi
mv "$APP_DIR" "$OUTPUT_ROOT/DynamicWallpaper.app"
printf 'Built: %s\n' "$OUTPUT_ROOT/DynamicWallpaper.app"
