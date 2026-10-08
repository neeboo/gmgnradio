#!/bin/bash
# Build the current Unity scene and embedded GPUI; never install or launch.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
destination="${1:?Pass the worktree noindex formal candidate path}"
[[ "${GMGN_UNITY_CONFIGURATION:-Release}" == Release && "${GMGN_UNITY_ONLY_ACTIVE_ARCH:-YES}" == YES ]] || {
  echo 'Current Unity packaging supports Release/active architecture only; Debug/universal require a matching player, host and plugin build' >&2; exit 2;
}
case "$destination" in "$root/"*.noindex/*/*.app) ;; *) echo 'Expected worktree noindex candidate' >&2; exit 2;; esac
[[ "$destination" != *'/../'* && ! -L "$destination" ]] || exit 2
unity_cli="${UNITY_CLI_BIN:-$(command -v unity || true)}"
if [[ -z "$unity_cli" && -x "$HOME/.unity/bin/unity" ]]; then unity_cli="$HOME/.unity/bin/unity"; fi
[[ -n "$unity_cli" && -f "$unity_cli" && -x "$unity_cli" ]] || { echo 'Unity CLI unavailable; set UNITY_CLI_BIN to an existing executable (no automatic installation)' >&2; exit 2; }
mkdir -p "$root/tmp" "$(dirname "$destination")"
parent="$(cd "$(dirname "$destination")" && pwd -P)"
case "$parent/$(basename "$destination")" in "$root/"*.noindex/*/*.app) ;; *) exit 2;; esac
evidence_root="$root/tmp/ReleaseArtifacts.noindex"
mkdir -p "$evidence_root"
stage="$(mktemp -d "$evidence_root/unity-product.XXXXXX")"
trap 'printf "Unity candidate evidence retained: %s\n" "$stage" >&2' EXIT
app="$stage/gmgn radio.app"
# CLI selects the editor from ProjectVersion.txt; no stale sample version.
GMGN_UNITY_BUILD_PATH="$app" "$unity_cli" build "$root/apps/unity-player" --non-interactive \
  --target StandaloneOSX --execute-method GMGN.UnityPlayer.Editor.PlayerBuild.BuildMac \
  --output-path "$app" --allow-dirty-build --no-tail --timeout 600 \
  --log-file "$stage/unity-build.log" --provenance-path "$stage/unity-build.provenance.json"
bash "$root/tools/build-unity-media-host.sh"
CARGO_BUILD_JOBS=1 bash "$root/tools/package-unity-media-host.sh" "$app"
overlay="$root/tools/fixtures/gpui-unity-overlay-probe"
overlay_target="$root/tools/gpui-scenekit-probe/target"
CARGO_TARGET_DIR="$overlay_target" cargo +1.95.0 build -j1 --release --manifest-path "$overlay/Cargo.toml" --locked --offline
bash "$root/tools/package-gpui-chat2-probe.sh" "$app" "$overlay_target/release/libgmgn_gpui_overlay_probe.dylib"
# Keep the existing Unity identity and actual required helpers (no mcpd).
python3 "$root/tools/unity-product-metadata.py" --player "$app" --privacy-source "$root/apps/macos/Resources/Info.plist"
python3 "$root/tools/unity-product-metadata.py" --write-manifest "$app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
python3 "$root/tools/unity-product-metadata.py" --verify "$app"
python3 "$root/tools/bundle-screen-link-helper.py" --destination "$app/Contents/Helpers" --verify-only --include deno
if [[ -e "$destination" ]]; then
  backup="$(mktemp -d "$parent/.unity-previous.XXXXXX")"
  mv "$destination" "$backup/gmgn radio.app"
  printf 'Previous candidate retained: %s\n' "$backup" >&2
fi
mv "$app" "$destination"
printf 'Built Unity + embedded GPUI formal candidate (not installed): %s\n' "$destination"
