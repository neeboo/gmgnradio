#!/bin/bash
set -euo pipefail

# Build the MCP stdio helper for the same architectures as the containing app
# and install it next to gmgn-taskd in Contents/Helpers/.
#
# This does NOT launch the MCP face, does NOT contact any socket and does NOT
# read the user's task database or configuration. It only compiles the crate
# that already lives in this repository and copies the binary into the bundle.
#
# The sha256 of the installed binary is written to `gmgn-mcpd.sha256` and the
# build fails closed if that digest comes back empty (never a placeholder hash).

mcp_repo="$(cd "$(dirname "$0")/.." && pwd)"
mcp_cargo="$(command -v cargo || true)"
if [[ -z "$mcp_cargo" && -x "${HOME}/.cargo/bin/cargo" ]]; then
  mcp_cargo="${HOME}/.cargo/bin/cargo"
fi
if [[ -z "$mcp_cargo" ]]; then
  echo 'error: Rust cargo is required to bundle gmgn-mcpd.' >&2
  exit 1
fi
: "${TARGET_BUILD_DIR:?Xcode TARGET_BUILD_DIR is required}"
: "${CONTENTS_FOLDER_PATH:?Xcode CONTENTS_FOLDER_PATH is required}"
: "${ARCHS:?Xcode ARCHS is required}"

mcp_target_dir="${DERIVED_FILE_DIR:-${TARGET_BUILD_DIR}/mcpd-derived}/rust-mcpd"
mcp_profile=debug
mcp_cargo_profile=dev
if [[ "${CONFIGURATION:-Debug}" != Debug ]]; then
  mcp_profile=release
  mcp_cargo_profile=release
fi

mcp_binaries=()
for mcp_arch in $ARCHS; do
  case "$mcp_arch" in
    arm64) mcp_triple=aarch64-apple-darwin ;;
    x86_64) mcp_triple=x86_64-apple-darwin ;;
    *) echo "error: Unsupported gmgn-mcpd architecture: $mcp_arch" >&2; exit 1 ;;
  esac
  "$mcp_cargo" build --locked --manifest-path "$mcp_repo/services/gmgn-mcpd/Cargo.toml" \
    --target-dir "$mcp_target_dir" --target "$mcp_triple" --profile "$mcp_cargo_profile"
  mcp_binaries+=("$mcp_target_dir/$mcp_triple/$mcp_profile/gmgn-mcpd")
done

mcp_destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$mcp_destination"
if [[ ${#mcp_binaries[@]} -eq 1 ]]; then
  install -m 755 "${mcp_binaries[0]}" "$mcp_destination/gmgn-mcpd"
else
  /usr/bin/lipo -create "${mcp_binaries[@]}" -output "$mcp_destination/gmgn-mcpd"
  chmod 755 "$mcp_destination/gmgn-mcpd"
fi
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime "$mcp_destination/gmgn-mcpd"
fi

mcp_hash="$(/usr/bin/shasum -a 256 "$mcp_destination/gmgn-mcpd" | /usr/bin/awk '{print $1}')"
if [[ -z "$mcp_hash" ]]; then
  echo 'error: empty sha256 for gmgn-mcpd; refusing to bundle an unverifiable helper.' >&2
  exit 1
fi
printf '%s  %s\n' "$mcp_hash" "gmgn-mcpd" > "$mcp_destination/gmgn-mcpd.sha256"
