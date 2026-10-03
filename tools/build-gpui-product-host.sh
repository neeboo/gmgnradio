#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$repo_root/tmp/gpui-product-host"
mkdir -p "$build_root/project"
xcodegen generate --spec "$repo_root/apps/macos/gpui-product-host.yml" --project "$build_root/project"
resolved_dir="$build_root/project/GPUIProductHost.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$resolved_dir"
cp "$repo_root/apps/macos/GMGNRadio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$resolved_dir/Package.resolved"
python3 "$repo_root/tools/with-build-lock.py" --lock "$repo_root/apps/macos/Build.noindex/.xcodebuild.lock" -- \
  xcodebuild build -project "$build_root/project/GPUIProductHost.xcodeproj" -scheme GPUIProductHost \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath "$build_root/DerivedData" \
  -clonedSourcePackagesDirPath "$repo_root/apps/macos/Packages" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
products="$build_root/DerivedData/Build/Products/Debug"
mkdir -p "$build_root/resources"
cp -R "$repo_root/apps/macos/Resources/MMDMotions" "$build_root/resources/"
cp -R "$repo_root/apps/macos/Resources/Worlds" "$build_root/resources/"
cp "$repo_root/apps/macos/Resources/AppIcon.icns" "$build_root/resources/"
printf 'Product-host products: %s\nResource staging: %s\n' "$products" "$build_root/resources"
