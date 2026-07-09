#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

status=0

fail_if_tracked() {
  local label="$1"
  shift

  local matches
  matches="$(git ls-files -- "$@")"

  if [[ -n "$matches" ]]; then
    echo "ERROR: tracked $label files are not allowed:" >&2
    echo "$matches" >&2
    status=1
  fi
}

# Output folders named `generated` (e.g. locally rendered docs), root or nested.
fail_if_tracked "generated" "generated" "*/generated"
fail_if_tracked "macOS metadata" ".DS_Store" "*/.DS_Store"
fail_if_tracked "SwiftPM build output" ".build" ".build/*"
fail_if_tracked "SwiftPM local metadata" ".swiftpm" ".swiftpm/*"
fail_if_tracked "Xcode DerivedData" "DerivedData" "DerivedData/*" "*/DerivedData" "*/DerivedData/*"
fail_if_tracked "scratch SQLite" "*.sqlite" "*.sqlite-journal" "*.sqlite-wal" "*.sqlite-shm" "*.db"

exit "$status"
