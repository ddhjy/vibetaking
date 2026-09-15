#!/bin/bash
set -euo pipefail
check_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/vibetaking-tag-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -O -swift-version 5 -default-isolation MainActor \
  "$check_root/vibetaking/AIService.swift" \
  "$check_root/vibetaking/UserFacingError.swift" \
  "$check_root/tests/TagRecommendationChecks.swift" \
  -o "$check_dir/tag-checks"
"$check_dir/tag-checks"
