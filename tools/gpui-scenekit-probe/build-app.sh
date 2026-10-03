#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
cargo build --locked
# Optional destination lets acceptance builds avoid overwriting a running bundle.
bundle="${1:-$PWD/target/GPUI SceneKit Probe.app}"
mkdir -p "$bundle/Contents/MacOS"
cp target/debug/gpui-scenekit-probe "$bundle/Contents/MacOS/GPUI SceneKit Probe"
plist_source=Info.plist
if [[ "${2:-}" == compact ]]; then plist_source=Info-compact.plist; fi
if [[ "${2:-}" == compact-focus ]]; then plist_source=Info-compact-focus.plist; fi
if [[ "${2:-}" == production ]]; then plist_source=Info-production.plist; fi
cp "$plist_source" "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
printf '%s\n' "$bundle"
