#!/bin/bash
set -euo pipefail
check_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/vibetaking-permission-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  "$check_root/vibetaking/Agent/CommandLine.swift" \
  "$check_root/vibetaking/Agent/OffloadPermissionManager.swift" \
  "$check_root/tests/OffloadPermissionChecks.swift" \
  -o "$check_dir/permission-checks"
"$check_dir/permission-checks"
