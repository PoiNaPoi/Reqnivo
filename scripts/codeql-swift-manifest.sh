#!/bin/bash
set -euo pipefail

: "${REQNIVO_MANIFEST_SWIFTC:?Missing manifest compiler path}"

if [ "${1:-}" = "--untraced" ]; then
  shift
  case "${DYLD_INSERT_LIBRARIES:-}" in
    *libtrace.dylib*)
      echo "CodeQL tracing is still active for the manifest compiler." >&2
      exit 1
      ;;
  esac
  exec "$REQNIVO_MANIFEST_SWIFTC" "$@"
fi

: "${CODEQL_DIST:?CodeQL must be initialized before compiling manifests}"
: "${CODEQL_EXTRACTOR_SWIFT_WIP_DATABASE:?Missing Swift CodeQL database}"

exec "$CODEQL_DIST/codeql" database trace-command \
  --quiet --no-tracing "$CODEQL_EXTRACTOR_SWIFT_WIP_DATABASE" \
  -- "$0" --untraced "$@"
