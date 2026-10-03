#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$repo_root/tmp/gpui-render-host"
mkdir -p "$build_root/project"
xcodegen generate --spec "$repo_root/apps/macos/gpui-render-host.yml" --project "$build_root/project"
resolved_dir="$build_root/project/GPUIRenderHost.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$resolved_dir"
cp "$repo_root/apps/macos/GMGNRadio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$resolved_dir/Package.resolved"
python3 "$repo_root/tools/with-build-lock.py" --lock "$repo_root/apps/macos/Build.noindex/.xcodebuild.lock" -- \
  xcodebuild build -project "$build_root/project/GPUIRenderHost.xcodeproj" -scheme GPUIRenderHost \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath "$build_root/DerivedData" \
  -clonedSourcePackagesDirPath "$repo_root/apps/macos/Packages" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
products="$build_root/DerivedData/Build/Products/Debug"
# Install into the isolated GPUI test App's Contents/Resources later, never the
# installed application. The production renderer uses Bundle.main metallib.
mkdir -p "$build_root/resources"
cp -R "$repo_root/apps/macos/Resources/MMDMotions" "$build_root/resources/"
cp -R "$repo_root/apps/macos/Resources/Worlds" "$build_root/resources/"
printf 'Render-host products: %s\nResource staging: %s\n' "$products" "$build_root/resources"
