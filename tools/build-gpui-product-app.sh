#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-$root/tmp/gpui-product-app/gmgn radio.app}"
case "$destination" in "$root/tmp/"*.app) ;; *) echo 'Expected an absolute isolated tmp App destination' >&2; exit 2;; esac
[[ ! -e "$destination" ]] || { echo 'Destination exists; use a fresh App path' >&2; exit 2; }
products="$root/tmp/gpui-product-host/DerivedData/Build/Products/Release"
source_app="$root/tmp/e2e-app-build/DerivedData/Build/Products/Release/gmgn radio.app"
[[ -f "$products/GPUIProductHost.dylib" && -f "$products/default.metallib" ]] || { echo 'Build ProductHost first' >&2; exit 1; }
python3 "$root/tools/verify-helper-manifest.py" --app "$source_app" --require-screen-link
cargo +1.95.0 build --release --manifest-path "$root/apps/gpui-app/Cargo.toml" --locked --offline --target-dir "$root/tools/gpui-scenekit-probe/target"
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Frameworks" "$destination/Contents/Resources"
cp "$root/tools/gpui-scenekit-probe/target/release/gmgn-gpui-app" "$destination/Contents/MacOS/gmgn-gpui-app"
cp "$root/apps/gpui-app/Info.plist" "$destination/Contents/Info.plist"
ditto "$source_app/Contents/Resources" "$destination/Contents/Resources"
# Preserve Bundle.main/Helpers lookup and byte-identical helper manifests while
# keeping metadata outside Apple's implicit nested-code directory classification.
ditto "$source_app/Contents/Helpers" "$destination/Contents/Resources/Helpers"
ln -s Resources/Helpers "$destination/Contents/Helpers"
cp "$products/default.metallib" "$destination/Contents/Resources/default.metallib"
for bundle in "$products/"*.bundle; do
  [[ -d "$bundle" ]] || continue
  ditto "$bundle" "$destination/Contents/Resources/$(basename "$bundle")"
done
for framework in LiveKitWebRTC.framework RustLiveKitUniFFI.framework; do
  ditto "$products/$framework" "$destination/Contents/Frameworks/$framework"
  codesign --force --sign - "$destination/Contents/Frameworks/$framework"
done
dylib="$destination/Contents/Frameworks/GPUIProductHost.dylib"
cp "$products/GPUIProductHost.dylib" "$dylib"
install_name_tool -id '@rpath/GPUIProductHost.dylib' "$dylib"
install_name_tool -add_rpath '@loader_path' "$dylib"
codesign --force --sign - "$dylib"
codesign --force --sign - "$destination"
codesign --verify --strict "$destination"
for helper in gmgn-taskd gmgn-mcpd; do
  codesign --verify --strict "$destination/Contents/Helpers/$helper"
done
for framework in LiveKitWebRTC.framework RustLiveKitUniFFI.framework; do
  codesign --verify --deep --strict "$destination/Contents/Frameworks/$framework"
done
codesign --verify --strict "$dylib"
python3 "$root/tools/verify-helper-manifest.py" --app "$destination" --require-screen-link
printf 'Built actual gmgn product App: %s\n' "$destination"
