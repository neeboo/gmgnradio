#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
editor_version="$(sed -n 's/^m_EditorVersion: //p' "$repo_root/apps/unity-player/ProjectSettings/ProjectVersion.txt")"
scripting="${UNITY_SCRIPTING_DIR:-/Applications/Unity/Hub/Editor/$editor_version/Unity.app/Contents/Resources/Scripting}"
mono_bin="$scripting/MonoBleedingEdge/bin"
test -x "$mono_bin/mcs" && test -x "$mono_bin/mono"
interfaces=("$repo_root"/apps/unity-player/Library/PackageCache/com.unity.cloud.gltfast@*/Runtime/Scripts/IDeferAgent.cs)
if [ "${#interfaces[@]}" -ne 1 ] || [ ! -f "${interfaces[0]}" ]; then
    echo 'Expected exactly one restored glTFast IDeferAgent.cs' >&2
    exit 1
fi
probe_dir="$(mktemp -d /tmp/gmgn-world-defer.XXXXXX)"
trap 'rm -f "$probe_dir/Probe.exe"; rmdir "$probe_dir"' EXIT
"$mono_bin/mcs" -optimize+ -out:"$probe_dir/Probe.exe" \
    "${interfaces[0]}" \
    "$repo_root/apps/unity-player/Assets/GMGN/World/WorldPrepareDeferAgent.cs" \
    "$repo_root/tools/fixtures/world-prepare-defer/Program.cs"
"$mono_bin/mono" "$probe_dir/Probe.exe"
