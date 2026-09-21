#!/bin/bash
set -euo pipefail
check_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibetaking-workflow-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  "$check_root/vibetaking/Workflow.swift" \
  "$check_root/tests/WorkflowCompatibilityChecks.swift" \
  -o "$check_dir/workflow-checks"
"$check_dir/workflow-checks"
