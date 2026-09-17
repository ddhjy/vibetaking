#!/bin/bash
set -euo pipefail

check_root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="${NAVIGATION_CHECK_DIR:-$(mktemp -d /tmp/vibetaking-navigation-checks.XXXXXX)}"
destination="${1:-platform=iOS,name=KAI}"
mkdir -p "$check_dir"

# A separate runner tests the installed app without changing the shipping project.
ruby - "$check_root" "$check_dir" <<'RUBY'
require 'xcodeproj'
root, output = ARGV
path = File.join(output, 'NavigationChecks.xcodeproj')
project = Xcodeproj::Project.new(path)
target = project.new_target(:ui_test_bundle, 'NavigationChecks', :ios, '26.0')
target.add_file_references([
  project.main_group.new_file(File.join(root, 'tests/NavigationToolbarUITests.swift'))
])
target.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'cn.1pointech.vibetaking.navigationchecks',
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'SWIFT_VERSION' => '5.0',
    'DEVELOPMENT_TEAM' => '6KH2T566FP',
    'CODE_SIGN_STYLE' => 'Automatic',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'SDKROOT' => 'iphoneos'
  })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(target)
scheme.save_as(path, 'NavigationChecks')
RUBY

printf 'Navigation test results: %s\n' "$check_dir/results.xcresult"
xcodebuild -project "$check_dir/NavigationChecks.xcodeproj" \
  -scheme NavigationChecks -destination "$destination" \
  -derivedDataPath "$check_dir/DerivedData" \
  -resultBundlePath "$check_dir/results.xcresult" \
  -allowProvisioningUpdates -parallel-testing-enabled NO \
  -collect-test-diagnostics never test
