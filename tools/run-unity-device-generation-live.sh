#!/bin/zsh
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
if [[ $# -lt 1 || $# -gt 2 || ( $# == 2 && "$2" != "--wish-tray-v2" ) ]]; then
  print -u2 'Usage: tools/run-unity-device-generation-live.sh /absolute/path/to/gmgn-taskd [--wish-tray-v2]'
  exit 2
fi
mkdir -p tmp
bash tools/world-runtime-harness-flags.sh --ensure >/dev/null
flags=("${(@f)$(bash tools/world-runtime-harness-flags.sh)}")
swiftc -swift-version 6 -parse-as-library \
  apps/macos/Sources/GMGNRadio/Presence/{PropGenerationClient,PropGenerationStore,PropImagePreparation,PropTaskDaemonClient,PropGenerationConfiguration,WishMachineOutputDescriptor,WishMachineCoordinator,WishMachineTaskPresentation,ResidentOwnershipProjection,RetryBackoff}.swift \
  tools/generate-unity-devices-live.swift "${flags[@]}" -o tmp/generate-unity-devices-live
exec tmp/generate-unity-devices-live "$@"
