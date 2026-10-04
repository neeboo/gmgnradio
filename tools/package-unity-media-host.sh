#!/bin/bash
# Package only the independent Unity sample; never modify an installed app.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?Pass the freshly built Unity sample .app path}"
products="$repo_root/tmp/unity-media-host/DerivedData/Build/Products/Release"
case "$app" in "$repo_root/tmp/"*.app) ;; *) echo 'Expected a Unity sample App inside repo/tmp' >&2; exit 2 ;; esac
[[ -d "$app/Contents/MacOS" && -f "$app/Contents/Info.plist" ]] || { echo 'App bundle is incomplete' >&2; exit 2; }
real_app="$(cd "$app" && pwd -P)"
case "$real_app" in "$repo_root/tmp/"*.app) ;; *) echo 'App resolves outside repo/tmp' >&2; exit 2 ;; esac
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
case "$identifier" in ai.gmgn.unity-sample*) ;; *) echo 'Refusing non-sample bundle identifier' >&2; exit 2 ;; esac
plugins="$app/Contents/Plugins"
[[ ! -L "$app/Contents" && ! -L "$plugins" ]] || { echo 'Refusing symlinked plugin destination' >&2; exit 2; }
[[ -f "$products/UnityMediaHost.dylib" ]] || { echo 'Build UnityMediaHost first' >&2; exit 1; }
settings_binary="$repo_root/tools/gpui-scenekit-probe/target/release/gmgn-unity-settings"
[[ -x "$settings_binary" ]] || { echo 'Build the gmgn-unity-settings Release binary first' >&2; exit 1; }
settings_app="$app/Contents/Helpers/GMGN Unity Settings.app"
[[ ! -e "$settings_app" && ! -e "$app/Contents/MacOS/gmgn-unity-settings" ]] || { echo 'Settings already packaged; use a fresh App build' >&2; exit 2; }
[[ ! -L "$app/Contents/Helpers" ]] || { echo 'Refusing symlinked settings destination' >&2; exit 2; }
[[ ! -e "$plugins/UnityMediaHost.dylib" ]] || { echo 'Host already packaged; use a fresh App build' >&2; exit 2; }
for framework in LiveKitWebRTC.framework RustLiveKitUniFFI.framework; do
  [[ -d "$products/$framework" ]] || { echo "Missing required framework: $framework" >&2; exit 1; }
  [[ ! -e "$plugins/$framework" ]] || { echo "Framework already exists: $framework" >&2; exit 2; }
done
# Unity CLI puts provenance at the bundle root, outside Apple's sealed
# Contents layout. Preserve it beside the App before signing, never discard it.
provenance="$app/unity-build.provenance.json"
if [[ -e "$provenance" ]]; then
  [[ -f "$provenance" && ! -L "$provenance" ]] || { echo 'Unexpected provenance entry' >&2; exit 2; }
  provenance_export="$(mktemp "$repo_root/tmp/unity-build.provenance.XXXXXX.json")"
  # mktemp owns this unique file; copying never overwrites any prior evidence.
  cp "$provenance" "$provenance_export"
  cmp -s "$provenance" "$provenance_export" || { echo 'Provenance preservation failed' >&2; exit 1; }
  mv "$provenance" "$provenance_export"
  printf 'Preserved Unity build provenance: %s\n' "$provenance_export"
fi
mkdir -p "$plugins"
cp "$products/UnityMediaHost.dylib" "$plugins/UnityMediaHost.dylib"
for framework in LiveKitWebRTC.framework RustLiveKitUniFFI.framework; do
  ditto "$products/$framework" "$plugins/$framework"
  codesign --force --sign - "$plugins/$framework"
done
install_name_tool -id '@rpath/UnityMediaHost.dylib' "$plugins/UnityMediaHost.dylib"
if ! otool -l "$plugins/UnityMediaHost.dylib" | rg 'path @loader_path ' >/dev/null; then
  install_name_tool -add_rpath '@loader_path' "$plugins/UnityMediaHost.dylib"
fi
codesign --force --sign - "$plugins/UnityMediaHost.dylib"
mkdir -p "$settings_app/Contents/MacOS"
cp "$repo_root/tools/unity-settings-info.plist" "$settings_app/Contents/Info.plist"
cp "$settings_binary" "$settings_app/Contents/MacOS/gmgn-unity-settings"
codesign --force --sign - "$settings_app"
# Preserve Unity's existing signed nested code; sign the new containing bundle.
codesign --force --sign - "$app"
for framework in LiveKitWebRTC.framework RustLiveKitUniFFI.framework; do
  codesign --verify --deep --strict "$plugins/$framework"
done
codesign --verify --strict "$plugins/UnityMediaHost.dylib"
codesign --verify --deep --strict "$settings_app"
codesign --verify --deep --strict "$app"
printf 'Packaged independent Unity host: %s\n' "$app"
