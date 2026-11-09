# Sourced by build-app.sh and test.sh with PROJECT_DIR set.
# Module caches record the absolute path they were built at. After the checkout
# moves or is renamed, every build fails on them ("was compiled with module cache
# path ..."), so start them over whenever the checkout is somewhere new.
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swift-cache"
CACHE_ROOT_FILE="$PROJECT_DIR/.build/cache-root"
if [[ ! -f "$CACHE_ROOT_FILE" || "$(<"$CACHE_ROOT_FILE")" != "$PROJECT_DIR" ]]; then
  rm -rf "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
  mkdir -p "$PROJECT_DIR/.build"
  print -r -- "$PROJECT_DIR" > "$CACHE_ROOT_FILE"
fi
