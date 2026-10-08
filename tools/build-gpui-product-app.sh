#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${GMGN_GPUI_CONFIGURATION:-Release}"
case "$configuration" in Debug|Release) ;; *) echo 'Expected Debug or Release' >&2; exit 2;; esac
mode="${GMGN_GPUI_BUNDLE_MODE:-production}"
case "$mode" in production|e2e) ;; *) echo 'Expected explicit production or e2e mode' >&2; exit 2;; esac
destination="${1:-$root/apps/macos/Build.noindex/Build/Products/$configuration/gmgn radio.app}"
case "$destination" in "$root/"*.noindex/*/*.app|"$root/tmp/"*.app) ;; *) echo 'Expected a worktree-only noindex or tmp App destination' >&2; exit 2;; esac
[[ "$destination" != *'/../'* && ! -L "$destination" ]] || { echo 'Refusing indirect App destination' >&2; exit 2; }
products="${GMGN_GPUI_HOST_PRODUCTS:-$root/tmp/gpui-product-host/DerivedData/Build/Products/$configuration}"
source_app="${GMGN_GPUI_SOURCE_APP:-$root/apps/macos/Build.noindex/NativeHost.noindex/Build/Products/$configuration/gmgn radio.app}"
[[ "$source_app" != "$destination" && ! -L "$source_app" ]] || { echo 'Expected a separate explicit native carrier' >&2; exit 2; }
source_app="$(cd "$source_app" && pwd -P)"
products="$(cd "$products" && pwd -P)"
for input in "$source_app" "$products"; do
  case "$input" in "$root/"*.noindex/*|"$root/tmp/"*) ;; *) echo 'Inputs must be explicit worktree build artifacts' >&2; exit 2;; esac
done
expected_identity=ai.gmgn.radio; if [[ "$mode" == e2e ]]; then expected_identity=ai.gmgn.radio.e2e; fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" == "$expected_identity" ]] || { echo 'Carrier identity does not match the explicit bundle mode' >&2; exit 2; }
package_only="${GMGN_GPUI_PACKAGE_ONLY:-0}"
signing="${GMGN_GPUI_SIGNING:-none}"
case "$signing" in none|adhoc) ;; *) echo 'Only unsigned or explicit ad-hoc candidate signing is supported' >&2; exit 2;; esac
[[ -f "$products/GPUIProductHost.dylib" && -f "$products/default.metallib" ]] || { echo 'Build ProductHost first' >&2; exit 1; }
python3 "$root/tools/verify-helper-manifest.py" --app "$source_app" --require-screen-link
target_dir="${GMGN_GPUI_TARGET_DIR:-$root/tools/gpui-scenekit-probe/target}"
architectures="${GMGN_GPUI_ARCHS:-$(uname -m)}"
profile=release; profile_args=(--release)
if [[ "$configuration" == Debug ]]; then profile=debug; profile_args=(); fi
launcher_binaries=()
for architecture in $architectures; do
  case "$architecture" in arm64) triple=aarch64-apple-darwin ;; x86_64) triple=x86_64-apple-darwin ;; *) echo 'Unsupported launcher architecture' >&2; exit 2;; esac
  target_args=(); binary="$target_dir/$profile/gmgn-gpui-app"
  if [[ "$architectures" != "$(uname -m)" ]]; then target_args=(--target "$triple"); binary="$target_dir/$triple/$profile/gmgn-gpui-app"; fi
  if [[ "$package_only" != 1 ]]; then
    cargo +1.95.0 build "${profile_args[@]}" --manifest-path "$root/apps/gpui-app/Cargo.toml" --bin gmgn-gpui-app --locked --offline --target-dir "$target_dir" "${target_args[@]}"
  fi
  [[ -x "$binary" ]] || { echo 'Missing actual GPUI launcher' >&2; exit 1; }
  launcher_binaries+=("$binary")
done
[[ ${#launcher_binaries[@]} -gt 0 ]] || { echo 'No launcher architecture selected' >&2; exit 2; }
mkdir -p "$(dirname "$destination")"
parent="$(cd "$(dirname "$destination")" && pwd -P)"
case "$parent/$(basename "$destination")" in "$root/"*.noindex/*/*.app|"$root/tmp/"*.app) ;; *) echo 'Destination resolves outside worktree candidates' >&2; exit 2;; esac
staging="$(mktemp -d "$parent/.gpui-package.XXXXXX")"
trap 'echo "Candidate staging retained: $staging" >&2' EXIT
final_destination="$destination"
destination="$staging/gmgn radio.app"
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Frameworks" "$destination/Contents/Resources"
if [[ ${#launcher_binaries[@]} == 1 ]]; then
  cp "${launcher_binaries[0]}" "$destination/Contents/MacOS/gmgn-gpui-app"
else
  /usr/bin/lipo -create "${launcher_binaries[@]}" -output "$destination/Contents/MacOS/gmgn-gpui-app"
fi
plist_args=(--source "$source_app/Contents/Info.plist" --destination "$destination/Contents/Info.plist")
if [[ "$mode" == e2e ]]; then plist_args+=(--e2e); fi
python3 "$root/tools/gpui-product-plist.py" "${plist_args[@]}"
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
  if [[ "$signing" == adhoc ]]; then codesign --force --sign - "$destination/Contents/Frameworks/$framework"; fi
done
dylib="$destination/Contents/Frameworks/GPUIProductHost.dylib"
cp "$products/GPUIProductHost.dylib" "$dylib"
install_name_tool -id '@rpath/GPUIProductHost.dylib' "$dylib"
if ! otool -l "$dylib" | rg -q 'path @loader_path '; then
  install_name_tool -add_rpath '@loader_path' "$dylib"
fi
if [[ "$signing" == adhoc ]]; then
  # Ad-hoc only; no account identity or keychain access is requested.
  # Do not deep-resign helpers: their manifests and pinned public binaries
  # must remain byte-identical to the verified carrier.
  codesign --force --sign - "$dylib"
  codesign --force --sign - "$destination"
  codesign --verify --deep --strict "$destination"
fi
python3 "$root/tools/verify-helper-manifest.py" --app "$destination" --require-screen-link
for architecture in $architectures; do
  /usr/bin/lipo -verify_arch "$architecture" "$destination/Contents/MacOS/gmgn-gpui-app"
  /usr/bin/lipo -verify_arch "$architecture" "$dylib"
  for helper in gmgn-taskd gmgn-mcpd; do
    /usr/bin/lipo -verify_arch "$architecture" "$destination/Contents/Helpers/$helper"
  done
  for framework in LiveKitWebRTC RustLiveKitUniFFI; do
    /usr/bin/lipo -verify_arch "$architecture" "$destination/Contents/Frameworks/$framework.framework/$framework"
  done
done
if [[ -e "$final_destination" ]]; then
  # Only replace a previous generated GPUI candidate; retain it for recovery.
  previous_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$final_destination/Contents/Info.plist")"
  previous_identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$final_destination/Contents/Info.plist")"
  [[ "$previous_executable" == gmgn-gpui-app && "$previous_identity" == "$expected_identity" ]] || { echo 'Refusing to replace a non-GPUI candidate' >&2; exit 2; }
  mv "$final_destination" "$staging/previous.backup"
fi
mv "$destination" "$final_destination"
if [[ -e "$staging/previous.backup" ]]; then
  printf 'Previous candidate retained: %s\n' "$staging/previous.backup"
else
  rmdir "$staging"
fi
trap - EXIT
printf 'Built %s GPUI product App: %s (signing=%s)\n' "$mode" "$final_destination" "$signing"
