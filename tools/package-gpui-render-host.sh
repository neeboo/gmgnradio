#!/bin/bash
# Package only an already-built, explicitly identified isolated probe App.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_bundle="${1:?usage: bash tools/package-gpui-render-host.sh /absolute/path/to/isolated-probe.app}"
[[ $# == 1 && "$test_bundle" == /* && -d "$test_bundle/Contents" ]] || { echo 'Expected one existing absolute test App path' >&2; exit 2; }
test_bundle="$(cd "$test_bundle" && pwd -P)"
case "$test_bundle" in
  "$repo_root/tmp/"*.app|"$repo_root/tools/gpui-scenekit-probe/target/"*.app) ;;
  *) echo 'Refusing a bundle outside isolated probe build roots' >&2; exit 2 ;;
esac
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$test_bundle/Contents/Info.plist")"
[[ "$bundle_id" == ai.gmgn.gpui-scenekit-probe.production ]] || { echo 'Refusing non-production-probe bundle ID' >&2; exit 2; }
products="$repo_root/tmp/gpui-render-host/DerivedData/Build/Products/Debug"
staged_resources="$repo_root/tmp/gpui-render-host/resources"
for required in GPUIRenderHost.dylib default.metallib LiveKitWebRTC.framework RustLiveKitUniFFI.framework; do
  [[ -e "$products/$required" ]] || { echo "Missing render-host product: $required" >&2; exit 1; }
done
[[ -d "$staged_resources/Worlds" && -d "$staged_resources/MMDMotions" ]] || { echo 'Missing staged render resources' >&2; exit 1; }
frameworks="$test_bundle/Contents/Frameworks"
resources="$test_bundle/Contents/Resources"
mkdir -p "$frameworks" "$resources"
cp "$products/GPUIRenderHost.dylib" "$frameworks/GPUIRenderHost.dylib"
cp "$products/default.metallib" "$resources/default.metallib"
for framework in LiveKitWebRTC.framework RustLiveKitUniFFI.framework; do
  /usr/bin/ditto "$products/$framework" "$frameworks/$framework"
  /usr/bin/codesign --force --sign - "$frameworks/$framework"
done
# Generated SwiftPM accessors prefer Bundle.main.resourceURL / <name>.bundle.
for resource_bundle in "$products/"*.bundle; do
  [[ -d "$resource_bundle" ]] || continue
  destination="$resources/$(basename "$resource_bundle")"
  /usr/bin/ditto "$resource_bundle" "$destination"
  /usr/bin/codesign --force --sign - "$destination"
done
for resource in Worlds MMDMotions; do
  /usr/bin/ditto "$staged_resources/$resource" "$resources/$resource"
done
dylib="$frameworks/GPUIRenderHost.dylib"
/usr/bin/install_name_tool -id '@rpath/GPUIRenderHost.dylib' "$dylib"
# Both dependent frameworks are siblings of the dylib in Contents/Frameworks.
/usr/bin/install_name_tool -add_rpath '@loader_path' "$dylib"
/usr/bin/codesign --force --sign - "$dylib"
/usr/bin/codesign --force --sign - "$test_bundle"
/usr/bin/codesign --verify --deep --strict "$test_bundle"
printf 'Packaged isolated render-host probe: %s\n' "$test_bundle"
