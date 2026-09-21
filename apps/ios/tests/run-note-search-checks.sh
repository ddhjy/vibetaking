#!/bin/bash
set -euo pipefail
check_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibetaking-search-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  "$check_root/vibetaking/NoteSearch.swift" \
  "$check_root/tests/NoteSearchChecks.swift" \
  -o "$check_dir/search-checks"
"$check_dir/search-checks"
