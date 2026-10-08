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
[[ ! -L "$app/Contents/Helpers" ]] || { echo 'Refusing symlinked helper destination' >&2; exit 2; }
taskd_binary="$repo_root/target/release/gmgn-taskd"
[[ ! -e "$app/Contents/Helpers/gmgn-taskd" ]] || { echo 'Task service already packaged; use a fresh App build' >&2; exit 2; }
# Reuse the product Rust service. UnityProductSettings supplies its isolated
# root/endpoint explicitly; packaging never discovers an installed service.
cargo +1.95.0 build --release --manifest-path "$repo_root/Cargo.toml" -p gmgn-taskd --locked --offline
[[ -x "$taskd_binary" ]] || { echo 'Task service build did not produce the helper' >&2; exit 1; }
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
  provenance_export="$(mktemp "$repo_root/tmp/unity-build.provenance.json.XXXXXX")"
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
mkdir -p "$app/Contents/Helpers"
# Reuse the product's pinned, already downloaded public-link helper. Missing
# assets fail packaging; this Unity path never installs or downloads helpers.
screen_helper_cache="${GMGN_SCREEN_LINK_HELPER_CACHE_DIR:-$repo_root/tmp/screen-link-helper-cache}"
[[ ! -e "$app/Contents/Resources/Helpers" ]] || { echo 'Helper resource destination already exists; use a fresh App build' >&2; exit 2; }
screen_helper_hash="$(python3 -c 'import json,sys; print(next(h["sha256"] for h in json.load(open(sys.argv[1]))["helpers"] if h["name"] == "yt-dlp"))' "$repo_root/tools/helpers/screen-link-helpers.lock.json")"
[[ -f "$screen_helper_cache/yt-dlp-$screen_helper_hash" ]] || { echo 'Missing pinned screen-link helper cache; provide GMGN_SCREEN_LINK_HELPER_CACHE_DIR' >&2; exit 1; }
[[ "$(shasum -a 256 "$screen_helper_cache/yt-dlp-$screen_helper_hash" | awk '{print $1}')" == "$screen_helper_hash" ]] || { echo 'Pinned screen-link helper cache integrity mismatch' >&2; exit 1; }
screen_deno_hash="$(python3 -c 'import json,sys; print(next(h["sha256"] for h in json.load(open(sys.argv[1]))["helpers"] if h["name"] == "deno"))' "$repo_root/tools/helpers/screen-link-helpers.lock.json")"
screen_deno_cache="$screen_helper_cache/deno-$screen_deno_hash-deno"
[[ -f "$screen_deno_cache" ]] || { echo 'Missing pinned Deno helper cache; provide GMGN_SCREEN_LINK_HELPER_CACHE_DIR' >&2; exit 1; }
[[ "$(shasum -a 256 "$screen_deno_cache" | awk '{print $1}')" == "$screen_deno_hash" ]] || { echo 'Pinned Deno helper cache integrity mismatch' >&2; exit 1; }
python3 "$repo_root/tools/bundle-screen-link-helper.py" --destination "$app/Contents/Helpers" --cache-dir "$screen_helper_cache" --include deno
python3 "$repo_root/tools/bundle-screen-link-helper.py" --destination "$app/Contents/Helpers" --verify-only --include deno
cp "$taskd_binary" "$app/Contents/Helpers/gmgn-taskd"
codesign --force --sign - "$app/Contents/Helpers/gmgn-taskd"
# Match the signed GPUI product layout: hashes/licenses are sealed resources,
# not unsigned nested code in Contents/Helpers. Keep the runtime lookup path.
mkdir -p "$app/Contents/Resources"
mv "$app/Contents/Helpers" "$app/Contents/Resources/Helpers"
ln -s Resources/Helpers "$app/Contents/Helpers"
python3 "$repo_root/tools/bundle-screen-link-helper.py" --destination "$app/Contents/Helpers" --verify-only --include deno
# MotionPackageStore resolves built-in music motions from the player bundle.
mkdir -p "$app/Contents/Resources/MMDMotions"
cp "$repo_root/apps/macos/Resources/MMDMotions/iluvslapbass_motion.vmd" "$app/Contents/Resources/MMDMotions/"
cp "$repo_root/apps/macos/Resources/MMDMotions/iluvslapbass_motion.vrma" "$app/Contents/Resources/MMDMotions/"
for motion in gmgn.motion.device.jukebox-low-button-pmx.vmd gmgn.motion.device.jukebox-low-button-vrm.vrma gmgn.motion.device.jukebox-low-button-pmx.json gmgn.motion.device.jukebox-low-button-vrm.json; do
  cp "$repo_root/apps/macos/Resources/MMDMotions/$motion" "$app/Contents/Resources/MMDMotions/"
done
# Use the product's final icon for every newly packaged Unity player.
# Microphone access belongs to the MAIN executable.
microphone_usage="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$repo_root/apps/macos/Resources/Info.plist")"
[[ -n "${microphone_usage//[[:space:]]/}" ]] || { echo 'Product microphone usage description is empty' >&2; exit 1; }
if ! /usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription $microphone_usage" "$app/Contents/Info.plist" 2>/dev/null; then
  /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string $microphone_usage" "$app/Contents/Info.plist"
fi
packaged_microphone_usage="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$app/Contents/Info.plist")"
[[ "$packaged_microphone_usage" == "$microphone_usage" && -n "${packaged_microphone_usage//[[:space:]]/}" ]] || { echo 'MAIN microphone usage description verification failed' >&2; exit 1; }
cp "$repo_root/apps/macos/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon.icns' "$app/Contents/Info.plist"
# Preserve Unity's existing signed nested code; sign the new containing bundle.
codesign --force --sign - "$app"
for framework in LiveKitWebRTC.framework RustLiveKitUniFFI.framework; do
  codesign --verify --deep --strict "$plugins/$framework"
done
codesign --verify --strict "$plugins/UnityMediaHost.dylib"
codesign --verify --strict "$app/Contents/Helpers/gmgn-taskd"
codesign --verify --deep --strict "$app"
cmp -s "$repo_root/apps/macos/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
printf 'Packaged independent Unity host: %s\n' "$app"
