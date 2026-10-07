#!/bin/bash
set -euo pipefail
task_repo="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$task_repo/tmp/unity-media-host/DerivedData/Build"
task_products="$task_build/Products/Release"
task_object_root="$task_build/Intermediates.noindex/UnityMediaHost.build/Release/UnityMediaHost.build/Objects-normal/arm64"
task_output="$(mktemp -d)"
test -d "$task_products/UnityMediaHost.swiftmodule"
test -d "$task_object_root"
task_flags=()
for task_map in "$task_build/Intermediates.noindex/GeneratedModuleMaps/"*.modulemap; do
  task_flags+=(-Xcc "-fmodule-map-file=$task_map")
done
task_objects=()
while IFS= read -r task_object; do task_objects+=("$task_object"); done < <(
  rg --files --hidden --no-ignore "$task_object_root" -g '*.o'
)
test "${#task_objects[@]}" -gt 0
# Link the already-built production object files: Swift internal symbols are
# intentionally hidden by the dylib, so importing its module alone cannot link.
# No production build, application launch, authority write or binary replacement.
/usr/bin/swiftc -Xfrontend -disable-access-control \
  -Xfrontend -disable-autolink-framework -Xfrontend SwiftUICore \
  -Xfrontend -disable-autolink-framework -Xfrontend CoreAudioTypes \
  -parse-as-library -I "$task_products" -F "$task_products" -L "$task_products" \
  "${task_flags[@]}" "$task_repo/tools/recalibrate-held-prop.swift" \
  "${task_objects[@]}" "$task_products/"*.o -o "$task_output/preview"
DYLD_FRAMEWORK_PATH="$task_products" "$task_output/preview" "$@"
