#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
source "$PROJECT_DIR/scripts/module-cache.sh"
swift run --disable-sandbox --cache-path "$PROJECT_DIR/.build/package-cache" --config-path "$PROJECT_DIR/.build/package-config" --security-path "$PROJECT_DIR/.build/package-security" KolomCoreChecks
