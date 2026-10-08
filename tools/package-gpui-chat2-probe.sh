#!/bin/bash
# Add the already-built real GPUI plugin only to an explicit private Unity Player bundle.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?Pass an absolute existing private Unity Player .app}"
library="${2:?Pass an absolute already-built libgmgn_gpui_overlay_probe.dylib}"
case "$app" in "$repo_root/tmp/"*.app) ;; *) echo 'Only private repo/tmp Unity bundles allowed' >&2; exit 2 ;; esac
case "$library" in /*/libgmgn_gpui_overlay_probe.dylib) ;; *) echo 'Expected absolute real probe dylib' >&2; exit 2 ;; esac
[[ -f "$library" && ! -L "$library" && -d "$app/Contents/Plugins" && ! -L "$app/Contents/Plugins" ]] || exit 2
actual_app="$(cd "$app" && pwd -P)"
case "$actual_app" in "$repo_root/tmp/"*.app) ;; *) exit 2 ;; esac
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
case "$identifier" in ai.gmgn.unity-sample*) ;; *) echo 'Not a private Unity sample bundle' >&2; exit 2 ;; esac
for symbol in gmgn_gpui_probe_mount gmgn_gpui_probe_unmount gmgn_gpui_chat_snapshot gmgn_gpui_chat_take_command gmgn_gpui_ui_command gmgn_gpui_take_escape_consumed gmgn_overlay_register_current_unity_window gmgn_overlay_unity_content_view gmgn_overlay_geometry_revision gmgn_overlay_backing_scale gmgn_overlay_owns_input gmgn_overlay_set_panel_expanded gmgn_overlay_normalize_chat_rect; do
  nm -gU "$library" | awk '{print $NF}' | grep -qx "_$symbol" || { echo "Missing ABI: $symbol" >&2; exit 2; }
done
destination="$app/Contents/Plugins/libgmgn_gpui_overlay_probe.dylib"
[[ ! -e "$destination" ]] || { echo 'Refusing to overwrite an existing plugin' >&2; exit 2; }
cp "$library" "$destination"
codesign --force --sign - "$destination"
codesign --force --deep --sign - "$app"
printf 'Packaged production GPUI UI; not launched: %s\n' "$app"
