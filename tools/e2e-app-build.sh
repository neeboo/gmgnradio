#!/usr/bin/env bash
# 构建一个"独立测试 App"——它绝不安装、绝不启动、绝不注销或删除已装应用，
# 也不读写真实用户数据。所有产物落在仓库 `tmp/` 下，bundle id 与装机版不同：
#
#   bundle id : ai.gmgn.radio.e2e   （与 /Applications 的 ai.gmgn.radio 不是同一条注册）
#   derived   : tmp/e2e-app-build/DerivedData
#   产物路径  : <derived>/Build/Products/<配置>/gmgn radio.app
#
# 脚本只负责"编出来"，验收驱动器（tools/e2e-real-app.py）负责用
# GMGN_E2E_DATA_ROOT 把沙箱化后的这个产物跑起来。
#
# 用法：
#   tools/e2e-app-build.sh [--configuration Release] [--print-path]
# 环境：
#   GMGN_E2E_DERIVED_DATA  覆盖 derived data 目录
#   GMGN_E2E_CONFIGURATION 覆盖配置（默认 Release）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${GMGN_E2E_CONFIGURATION:-Release}"
DERIVED_DATA="${GMGN_E2E_DERIVED_DATA:-$ROOT/tmp/e2e-app-build/DerivedData}"
BUNDLE_ID="ai.gmgn.radio.e2e"
PRINT_PATH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) CONFIGURATION="${2:?}"; shift 2 ;;
    --print-path) PRINT_PATH=1; shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

PYTHON="${PYTHON:-python3}"
APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/gmgn radio.app"
LOCK_FILE="$DERIVED_DATA/.xcodebuild.lock"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: 需要 xcodebuild（仅构建，不安装）。" >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: 需要 xcodegen 生成 apps/macos/GMGNRadio.xcodeproj。" >&2
  exit 1
fi

# 与仓库既有构建互斥闸同一套：只互斥，不共享 DerivedData 的构建数据库。
run_locked() {
  "$PYTHON" "$ROOT/tools/with-build-lock.py" \
    --lock "$LOCK_FILE" --timeout "${BUILD_LOCK_TIMEOUT:-3600}" --label e2e-app-build -- "$@"
}

echo "[e2e-app-build] 生成工程（xcodegen）"
(cd "$ROOT/apps/macos" && run_locked xcodegen generate)

echo "[e2e-app-build] 编译独立测试产物：configuration=$CONFIGURATION derived=$DERIVED_DATA"
run_locked xcodebuild build \
  -project "$ROOT/apps/macos/GMGNRadio.xcodeproj" \
  -scheme GMGNRadio \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$ROOT/apps/macos/Packages" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  ONLY_ACTIVE_ARCH=YES SWIFT_COMPILATION_MODE=incremental \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

if [[ ! -x "$APP/Contents/MacOS/gmgn radio" ]]; then
  echo "error: 产物不存在或不可执行：$APP" >&2
  exit 1
fi

# 可选的屏幕链接 helper 打包（默认关：构建过程不联网）。设
# `GMGN_BUNDLE_SCREEN_LINK_HELPER=1` 时按钉死清单下载 yt-dlp（+ `GMGN_BUNDLE_DENO=1` 时的
# deno）→ 校验 sha256 → 内置到 Contents/Helpers/。空哈希 / 哈希不符一律构建失败。
REQUIRE_SCREEN_LINK=0
if [[ "${GMGN_BUNDLE_SCREEN_LINK_HELPER:-0}" == "1" ]]; then
  echo "[e2e-app-build] 打包屏幕链接 helper（钉死版本 + sha256）"
  bundle_args=(--app "$APP")
  if [[ "${GMGN_BUNDLE_DENO:-0}" == "1" ]]; then bundle_args+=(--include deno); fi
  "$PYTHON" "$ROOT/tools/bundle-screen-link-helper.py" "${bundle_args[@]}"
  REQUIRE_SCREEN_LINK=1
fi

# 独立完整性校验（taskd + mcpd + sha256 清单；有屏幕链接 helper 时一并复核）。
# 失败即构建失败。
if [[ "$REQUIRE_SCREEN_LINK" -eq 1 ]]; then
  "$PYTHON" "$ROOT/tools/verify-helper-manifest.py" --app "$APP" --require-screen-link
else
  "$PYTHON" "$ROOT/tools/verify-helper-manifest.py" --app "$APP"
fi

# 只注销、绝不删除：即使产物被 Spotlight 索引到，也不会在聚焦/启动台里冒出
# 第二个可启动项。失败不改变构建结果。
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true

if [[ "$PRINT_PATH" -eq 1 ]]; then
  printf '%s\n' "$APP"
else
  echo "[e2e-app-build] 完成：$APP"
fi
