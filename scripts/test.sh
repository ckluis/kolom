#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swift-cache"
swift run --disable-sandbox --cache-path "$PROJECT_DIR/.build/package-cache" --config-path "$PROJECT_DIR/.build/package-config" --security-path "$PROJECT_DIR/.build/package-security" KolomCoreChecks
