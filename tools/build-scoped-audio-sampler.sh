#!/usr/bin/env bash
# 构建**验收专用**、按目标 PID 限定的系统输出音频采样器。
#
#   tools/build-scoped-audio-sampler.sh [--no-app] [--print-path] [--configuration debug|release]
#
# 产物（全部落在被 .gitignore 忽略的 tmp/ 下，不装、不注册、不碰已装 App）：
#   tmp/scoped-audio-sampler/gmgn-scoped-audio                       直接可跑的 CLI
#   tmp/scoped-audio-sampler/ScopedAudioSampler.app/Contents/MacOS/gmgn-scoped-audio
#       —— 同一份二进制，外面套一个带 `NSAudioCaptureUsageDescription` 的 .app。
#          需要系统"音频录制/麦克风"TCC 授权时，把这个 .app 交给主代理在
#          系统设置 → 隐私与安全性 里授权（GUI 操作由主代理负责），再运行里面的可执行文件。
#
# 本脚本只做离线编译，不联网、不读写生产数据、不申请权限。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/tools/probe-scoped-process-audio.swift"
BUILD_DIR="${GMGN_SCOPED_AUDIO_BUILD_DIR:-$ROOT/tmp/scoped-audio-sampler}"
BIN="$BUILD_DIR/gmgn-scoped-audio"
APP="$BUILD_DIR/ScopedAudioSampler.app"
MODULE_CACHE="$BUILD_DIR/modulecache"
BUNDLE_ID="ai.gmgn.radio.e2e.audiosampler"
CONFIGURATION="${GMGN_SCOPED_AUDIO_CONFIGURATION:-release}"
BUILD_APP=1
PRINT_PATH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-app) BUILD_APP=0; shift ;;
    --print-path) PRINT_PATH=1; shift ;;
    --configuration) CONFIGURATION="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$SOURCE" ]]; then
  echo "error: 找不到源码 $SOURCE" >&2
  exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: 需要 Xcode 命令行工具（swiftc）。" >&2
  exit 1
fi

OPT_FLAG=(-O)
if [[ "$CONFIGURATION" == "debug" ]]; then OPT_FLAG=(-Onone -g); fi

mkdir -p "$BUILD_DIR" "$MODULE_CACHE"

echo "[scoped-audio] 编译 $SOURCE"
swiftc "${OPT_FLAG[@]}" -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  -framework CoreAudio -framework ScreenCaptureKit -framework AppKit \
  "$SOURCE" -o "$BIN"

if [[ "$BUILD_APP" -eq 1 ]]; then
  EXEC_DIR="$APP/Contents/MacOS"
  mkdir -p "$EXEC_DIR"
  cp "$BIN" "$EXEC_DIR/gmgn-scoped-audio"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>gmgn-scoped-audio</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>GMGN Scoped Audio Sampler</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>gmgn radio E2E 验收：只采集指定隔离测试 App 进程的系统输出音频，用于核对电视 HLS 的真实声音输出。不采集全系统或其他应用。</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>gmgn radio E2E 验收：Core Audio 进程 tap 在部分系统上以"音频录制"权限授权，仅用于采集指定测试进程的输出音频。</string>
</dict>
</plist>
PLIST
  # 尽力 ad-hoc 签名，给 TCC 一个稳定的 bundle 身份；失败不阻断编译产物。
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
      || echo "[scoped-audio] 警告：ad-hoc 签名失败，TCC 可能按父进程归属；不影响 CLI 产物。" >&2
  fi
  echo "[scoped-audio] App bundle：$APP"
fi

echo "[scoped-audio] 完成：$BIN"
if [[ "$PRINT_PATH" -eq 1 ]]; then
  if [[ "$BUILD_APP" -eq 1 ]]; then
    printf '%s\n' "$APP/Contents/MacOS/gmgn-scoped-audio"
  else
    printf '%s\n' "$BIN"
  fi
fi
