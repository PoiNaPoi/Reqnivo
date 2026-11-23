#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swift-modules"
command_name="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi

resolve_with_retry() {
  local delays=(5 15 30)
  local attempt=1
  local max_attempts=$(( ${#delays[@]} + 1 ))
  while true; do
    if swift package resolve --disable-sandbox --cache-path "$PWD/.cache/swiftpm" "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      return 1
    fi
    local delay="${delays[$((attempt - 1))]}"
    echo "swift package resolve failed (attempt $attempt/$max_attempts); retrying in ${delay}s..." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

show_bin_path=false
for arg in "$@"; do
  if [ "$arg" = "--show-bin-path" ]; then
    show_bin_path=true
    break
  fi
done

if [ "$command_name" = "package" ] && [ "${1:-}" = "resolve" ]; then
  shift
  resolve_with_retry "$@"
  exit 0
fi

if { [ "$command_name" = "build" ] || [ "$command_name" = "test" ]; } && [ "$show_bin_path" = "false" ]; then
  resolve_with_retry >&2
fi

exec swift "$command_name" --disable-sandbox --cache-path "$PWD/.cache/swiftpm" "$@"
