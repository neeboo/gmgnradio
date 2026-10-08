#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${GMGN_GPUI_BUILD_ROOT:-$repo_root/tmp/gpui-product-host}"
configuration="${GMGN_GPUI_CONFIGURATION:-Release}"
case "$configuration" in Debug|Release) ;; *) echo 'Expected Debug or Release' >&2; exit 2;; esac
case "$build_root" in "$repo_root/"*.noindex/*|"$repo_root/tmp/"*) ;; *) echo 'Expected worktree-only host build root' >&2; exit 2;; esac
mkdir -p "$build_root/project"
xcodegen generate --spec "$repo_root/apps/macos/gpui-product-host.yml" --project "$build_root/project"
resolved_dir="$build_root/project/GPUIProductHost.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$resolved_dir"
cp "$repo_root/apps/macos/GMGNRadio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$resolved_dir/Package.resolved"
python3 "$repo_root/tools/with-build-lock.py" --lock "$repo_root/apps/macos/Build.noindex/.xcodebuild.lock" -- \
  xcodebuild build -project "$build_root/project/GPUIProductHost.xcodeproj" -scheme GPUIProductHost \
  -configuration "$configuration" -destination 'platform=macOS' -derivedDataPath "$build_root/DerivedData" \
  -clonedSourcePackagesDirPath "${GMGN_GPUI_SOURCE_PACKAGES:-$repo_root/apps/macos/Packages}" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  "ONLY_ACTIVE_ARCH=${GMGN_GPUI_ONLY_ACTIVE_ARCH:-YES}" \
  "SWIFT_COMPILATION_MODE=${GMGN_GPUI_COMPILATION_MODE:-incremental}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
products="$build_root/DerivedData/Build/Products/$configuration"
nm -gU "$products/GPUIProductHost.dylib" > "$build_root/product-host.exports.txt"
for symbol in create start shutdown destroy action settings_command chat_send chat_cancel snapshot chat_poll string_free reopen attach_surface surface_visibility surface_rotate; do
  rg -q " _gmgn_product_host_${symbol}$" "$build_root/product-host.exports.txt" || {
    echo "Missing product-host ABI export: gmgn_product_host_${symbol}" >&2
    exit 1
  }
done
mkdir -p "$build_root/resources"
cp -R "$repo_root/apps/macos/Resources/MMDMotions" "$build_root/resources/"
cp -R "$repo_root/apps/macos/Resources/Worlds" "$build_root/resources/"
cp "$repo_root/apps/macos/Resources/AppIcon.icns" "$build_root/resources/"
printf 'Product-host products: %s\nResource staging: %s\n' "$products" "$build_root/resources"
