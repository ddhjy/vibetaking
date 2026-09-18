#!/bin/bash
set -euo pipefail
check_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibetaking-naming-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  "$check_root/vibetaking/AppConfigurationTransfer.swift" \
  "$check_root/tests/NamingCompatibilityChecks.swift" \
  -o "$check_dir/naming-checks"
"$check_dir/naming-checks"
