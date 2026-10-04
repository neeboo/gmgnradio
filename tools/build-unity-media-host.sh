#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$repo_root/tmp/unity-media-host"
mkdir -p "$build_root/project"
xcodegen generate --spec "$repo_root/apps/macos/UnityHost/project.yml" --project "$build_root/project"
resolved_dir="$build_root/project/UnityMediaHost.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$resolved_dir"
cp "$repo_root/apps/macos/GMGNRadio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$resolved_dir/Package.resolved"
python3 "$repo_root/tools/with-build-lock.py" --lock "$repo_root/apps/macos/Build.noindex/.xcodebuild.lock" -- \
  xcodebuild build -project "$build_root/project/UnityMediaHost.xcodeproj" -scheme UnityMediaHost \
  -configuration Release -destination 'platform=macOS' -derivedDataPath "$build_root/DerivedData" \
  -clonedSourcePackagesDirPath "$repo_root/apps/macos/Packages" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
printf 'Unity media host: %s\n' "$build_root/DerivedData/Build/Products/Release/UnityMediaHost.dylib"
