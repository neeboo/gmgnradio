#!/bin/bash
set -euo pipefail

# Build the helper for the same architectures as the containing app. This does
# not launch the daemon or access the user's task database or configuration.
task_repo="$(cd "$(dirname "$0")/.." && pwd)"
task_cargo="$(command -v cargo || true)"
if [[ -z "$task_cargo" && -x "${HOME}/.cargo/bin/cargo" ]]; then
  task_cargo="${HOME}/.cargo/bin/cargo"
fi
if [[ -z "$task_cargo" ]]; then
  echo 'error: Rust cargo is required to bundle gmgn-taskd.' >&2
  exit 1
fi
: "${TARGET_BUILD_DIR:?Xcode TARGET_BUILD_DIR is required}"
: "${CONTENTS_FOLDER_PATH:?Xcode CONTENTS_FOLDER_PATH is required}"
: "${ARCHS:?Xcode ARCHS is required}"
task_target_dir="${DERIVED_FILE_DIR:-${TARGET_BUILD_DIR}/taskd-derived}/rust-taskd"
task_profile=debug
task_cargo_profile=dev
if [[ "${CONFIGURATION:-Debug}" != Debug ]]; then
  task_profile=release
  task_cargo_profile=release
fi
task_binaries=()
for task_arch in $ARCHS; do
  case "$task_arch" in
    arm64) task_triple=aarch64-apple-darwin ;;
    x86_64) task_triple=x86_64-apple-darwin ;;
    *) echo "error: Unsupported gmgn-taskd architecture: $task_arch" >&2; exit 1 ;;
  esac
  "$task_cargo" build --locked --manifest-path "$task_repo/services/gmgn-taskd/Cargo.toml" \
    --target-dir "$task_target_dir" --target "$task_triple" --profile "$task_cargo_profile"
  task_binaries+=("$task_target_dir/$task_triple/$task_profile/gmgn-taskd")
done
task_destination="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$task_destination"
if [[ ${#task_binaries[@]} -eq 1 ]]; then
  install -m 755 "${task_binaries[0]}" "$task_destination/gmgn-taskd"
else
  /usr/bin/lipo -create "${task_binaries[@]}" -output "$task_destination/gmgn-taskd"
  chmod 755 "$task_destination/gmgn-taskd"
fi
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime "$task_destination/gmgn-taskd"
fi

# Fail-closed integrity manifest: the installed helper's own digest, never a
# placeholder. `tools/verify-helper-manifest.py` re-checks it before install.
task_hash="$(/usr/bin/shasum -a 256 "$task_destination/gmgn-taskd" | /usr/bin/awk '{print $1}')"
if [[ -z "$task_hash" ]]; then
  echo 'error: empty sha256 for gmgn-taskd; refusing to bundle an unverifiable helper.' >&2
  exit 1
fi
printf '%s  %s\n' "$task_hash" "gmgn-taskd" > "$task_destination/gmgn-taskd.sha256"
