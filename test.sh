#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CACHE="${TMPDIR:-/tmp}/dynamicwallpaper-tests"
mkdir -p "$TEST_CACHE/modules"
cd "$PROJECT_DIR"
xcrun swiftc -parse-as-library -O -module-cache-path "$TEST_CACHE/modules" \
    -target "$(uname -m)-apple-macosx13.0" \
    Sources/PlaybackState.swift Sources/WallpaperManager.swift Tests/RegressionTests.swift \
    -o "$TEST_CACHE/regression-tests"
"$TEST_CACHE/regression-tests" "$@"
