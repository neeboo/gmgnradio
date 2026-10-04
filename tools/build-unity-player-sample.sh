#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
revision="${1:?Pass a fresh sample revision, e.g. v5}"
[[ "$revision" =~ ^[a-zA-Z0-9-]+$ ]] || { echo 'Invalid sample revision' >&2; exit 2; }
app="$repo_root/tmp/unity-player-release-$revision.app"
[[ ! -e "$app" ]] || { echo 'Use a fresh revision; refusing to overwrite an App' >&2; exit 2; }
export GMGN_UNITY_BUILD_PATH="$app"
unity build "$repo_root/apps/unity-player" \
  --target StandaloneOSX \
  --execute-method GMGN.UnityPlayer.Editor.PlayerBuild.BuildMac \
  --editor-version 6000.6.0f1 --output-path "$app" \
  --allow-dirty-build --no-tail --timeout 600 \
  --log-file "$repo_root/tmp/unity-player-build-$revision.log"
if rg -q 'Shader error in|Scripts have compiler errors' "$repo_root/tmp/unity-player-build-$revision.log"; then
  echo 'Unity reported shader or script compilation errors; refusing to package this build.' >&2
  exit 1
fi
bash "$repo_root/tools/package-unity-media-host.sh" "$app"
