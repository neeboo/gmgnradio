#!/usr/bin/env bash
set -euo pipefail

verification_root="$(git rev-parse --show-toplevel)"
cd "$verification_root"

verification_tmp="$(mktemp -d /tmp/gmgn-agent-living-world.XXXXXX)"
cleanup_verification_tmp() {
  case "$verification_tmp" in
    /tmp/gmgn-agent-living-world.*)
      rm -rf -- "$verification_tmp"
      ;;
  esac
}
trap cleanup_verification_tmp EXIT

echo "[1/9] Parse local package manifests"
swift package dump-package --package-path apps/macos/Packages/NanoemCore >/dev/null
swift package dump-package --package-path apps/macos/Packages/MMDSceneKit >/dev/null
swift package dump-package --package-path apps/macos/Packages/WorldRuntime >/dev/null
swift package dump-package --package-path apps/macos/Packages/MotionDistribution >/dev/null

echo "[2/9] Run the hostless WorldRuntime suite"
swift test \
  --package-path apps/macos/Packages/WorldRuntime \
  --scratch-path "$verification_tmp/world-runtime"

echo "[3/9] Run the hostless motion-distribution suite"
swift test \
  --package-path apps/macos/Packages/MotionDistribution \
  --scratch-path "$verification_tmp/motion-distribution"

echo "[4/9] Run the offline motion-factory suite"
python3 -m unittest discover -s tools/motion/tests -p 'test_*.py'

echo "[5/9] Run Blender exporter and validator tests"
python3 -m unittest discover -s tools/blender/tests -p 'test_*.py'

echo "[6/9] Validate both version-controlled world packages"
python3 tools/blender/validate_gmgn_world.py \
  apps/macos/Resources/Worlds/warm-kitchen-canary
python3 tools/blender/validate_gmgn_world.py \
  apps/macos/Resources/Worlds/quiet-corner-fixture

echo "[7/9] Run static repository checks"
git diff --check
plutil -lint apps/macos/Resources/Info.plist
plutil -lint apps/macos/GMGNRadio.xcodeproj/project.pbxproj

echo "[8/9] Compile the app and tests without launching the test host"
xcode_arguments=(
  build-for-testing
  -project apps/macos/GMGNRadio.xcodeproj
  -scheme GMGNRadio
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$verification_tmp/derived-data"
  -disableAutomaticPackageResolution
  -onlyUsePackageVersionsFromResolvedFile
  -skipPackageUpdates
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
)
if [[ -n "${GMGN_VERIFY_PACKAGE_CACHE:-}" ]]; then
  xcode_arguments+=(
    -clonedSourcePackagesDirPath "$GMGN_VERIFY_PACKAGE_CACHE"
  )
fi
xcodebuild "${xcode_arguments[@]}"

echo "[9/9] PASS: safe living-world verification completed without launching the app"
