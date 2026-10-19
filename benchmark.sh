#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_CACHE="${TMPDIR:-/tmp}/dynamicwallpaper-benchmark"
mkdir -p "$BENCHMARK_CACHE/modules"
cd "$PROJECT_DIR"
xcrun swiftc -parse-as-library -O -module-cache-path "$BENCHMARK_CACHE/modules" \
    -target "$(uname -m)-apple-macosx13.0" \
    Sources/PlaybackState.swift Sources/WallpaperManager.swift Tests/MemoryBenchmark.swift \
    -o "$BENCHMARK_CACHE/benchmark"
"$BENCHMARK_CACHE/benchmark" "$BENCHMARK_CACHE/fixture" --prepare
"$BENCHMARK_CACHE/benchmark" "$BENCHMARK_CACHE/fixture"
