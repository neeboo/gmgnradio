#!/bin/bash
# 居民 DSH 原生宿主工具链离线组装验证（真实 DSH runtime + 本地 mock provider）。
# 覆盖 headless --patch insert 与 ACP 式 composition 普通行 两种挂载形态。
# 禁止：真实模型调用 / 启动 App / 真实语音 / 用户 DB / GPU / 钥匙串 / 外网。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gmgn-dsh-native-assembly-run.XXXXXX")"
if [ "${KEEP_TMP:-0}" = "1" ]; then
  echo "KEEP_TMP=1 -> $TMP"
  trap - EXIT
else
  trap 'rm -rf "$TMP"' EXIT
fi
overall=0

echo "== [1/3] 纯 Swift 通道离线回归 =="
swift "$ROOT/tools/test-resident-dsh-host-channel.swift" || overall=1

echo
echo "== [2/3] 编译组装验证 harness（生产源文件） =="
BRIDGE="$ROOT/apps/macos/Sources/GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift"
CHANNEL="$ROOT/apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift"
SUPPORT="$ROOT/tools/resident-dsh-host-tools-support.swift"
ASSEMBLY="$ROOT/tools/test-resident-dsh-native-assembly.swift"
BIN="$TMP/assembly"
/usr/bin/swiftc -swift-version 6 -parse-as-library -j1 "$ROOT/apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift" "$BRIDGE" "$CHANNEL" "$SUPPORT" "$ASSEMBLY" -o "$BIN"
if [ $? -ne 0 ]; then echo "COMPILE FAILED"; exit 1; fi

run_phase() {
  phase="native"
  echo
  echo "== [3/3] 真实 DSH headless + mock provider（原生宿主工具链） =="
  REQ="$TMP/requests-${phase}.jsonl"
  MOCK_OUT="$TMP/mock-${phase}.out"
  REQUESTS_FILE="$REQ" SUCCESS_TEXT="GMGN_NATIVE_ASSEMBLY_FINAL_OK" \
    node "$ROOT/tools/resident-dsh-mock-llm.mjs" > "$MOCK_OUT" 2>&1 &
  MOCK_PID=$!
  base=""
  for _ in $(seq 1 60); do
    if [ -s "$MOCK_OUT" ]; then
      base="$(sed -n 's/^READY //p' "$MOCK_OUT" | head -1)"
      [ -n "$base" ] && break
    fi
    sleep 0.5
  done
  if [ -z "$base" ]; then
    echo "mock provider 未就绪"; cat "$MOCK_OUT"; kill "$MOCK_PID" 2>/dev/null; return 1
  fi
  echo "mock provider ready: $base"
  MOCK_BASE_URL="$base" REQUESTS_FILE="$REQ" \
    DSH_BIN="${DSH_BIN:-$HOME/.local/bin/dsh}" "$BIN"
  phase_exit=$?
  kill -TERM "$MOCK_PID" 2>/dev/null
  for _ in $(seq 1 20); do kill -0 "$MOCK_PID" 2>/dev/null || break; sleep 0.25; done
  kill -KILL "$MOCK_PID" 2>/dev/null || true
  if [ -f "$REQ" ]; then
    echo "mock(${phase}) 捕获请求数: $(wc -l < "$REQ" | tr -d ' ')"
  fi
  echo "assembly(${phase}) exit=${phase_exit}"
  return ${phase_exit}
}

run_phase || overall=1

echo
if [ $overall -eq 0 ]; then
  echo "ASSEMBLY EXIT=0"
else
  echo "ASSEMBLY EXIT=1"
fi
exit $overall
