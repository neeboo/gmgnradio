#!/bin/bash
# 居民 DSH「真实 ACP 原生宿主工具链」离线组装验证（真实 acp-demo runtime + 本地
# 内容驱动 mock provider）。覆盖：同 ACP 会话连续两轮原生工具调用（结果回同会话
# 到普通 final）、revoke 后旧授权调用零执行、取消轮零执行且会话仍可用、重新 arm 后
# 新轮可用、schema/安全 overlay 正确。仅 headless 形态或单元 fake 不算 ACP 交付。
# 禁止：真实模型调用 / 启动 App / 真实语音 / 用户 DB / GPU / 钥匙串 / 外网。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gmgn-dsh-acp-native-assembly-run.XXXXXX")"
if [ "${KEEP_TMP:-0}" = "1" ]; then
  echo "KEEP_TMP=1 -> $TMP"
  trap - EXIT
else
  trap 'rm -rf "$TMP"' EXIT
fi
overall=0

echo "== [1/2] 真实 DSH ACP runtime + mock provider（原生宿主工具链，同会话多轮）=="
REQ="$TMP/requests-acp.jsonl"
CTL="$TMP/control.txt"
printf 'tool\n' > "$CTL"
MOCK_OUT="$TMP/mock.out"
REQUESTS_FILE="$REQ" CONTROL_FILE="$CTL" SUCCESS_TEXT="GMGN_ACP_NATIVE_ASSEMBLY_FINAL_OK" \
  node "$ROOT/tools/resident-dsh-acp-mock.mjs" > "$MOCK_OUT" 2>&1 &
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
  echo "mock provider 未就绪"; cat "$MOCK_OUT"; kill "$MOCK_PID" 2>/dev/null; exit 1
fi
echo "mock provider ready: $base"
NODE_BIN="${NODE_BIN:-$(command -v node)}"
GMGN_DSH_ACP_ENTRY="${GMGN_DSH_ACP_ENTRY:-$HOME/dev/deepseek-harness/packages/examples/acp-demo/lib/bin.js}"
MOCK_BASE_URL="$base" REQUESTS_FILE="$REQ" CONTROL_FILE="$CTL" \
  NODE_BIN="$NODE_BIN" GMGN_DSH_ACP_ENTRY="$GMGN_DSH_ACP_ENTRY" \
  swift "$ROOT/tools/test-resident-dsh-acp-native-assembly.swift"
assembly_exit=$?
kill -TERM "$MOCK_PID" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$MOCK_PID" 2>/dev/null || break; sleep 0.25; done
kill -KILL "$MOCK_PID" 2>/dev/null || true
if [ -f "$REQ" ]; then
  echo "mock(acp) 捕获请求数: $(wc -l < "$REQ" | tr -d ' ')"
fi
echo "assembly(acp) exit=${assembly_exit}"
if [ $assembly_exit -ne 0 ]; then overall=1; fi

echo
if [ $overall -eq 0 ]; then
  echo "ACP ASSEMBLY EXIT=0"
else
  echo "ACP ASSEMBLY EXIT=1"
fi
exit $overall
