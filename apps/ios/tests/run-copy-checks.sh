#!/bin/bash
set -euo pipefail
check_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/vibetaking-copy-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  "$check_root/vibetaking/UserFacingError.swift" \
  "$check_root/tests/UserFacingErrorChecks.swift" \
  -o "$check_dir/copy-checks"
"$check_dir/copy-checks"
