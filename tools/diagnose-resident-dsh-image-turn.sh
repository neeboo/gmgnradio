#!/bin/bash
# 居民图片输入「发送之后」全链诊断的离线运行器。
#
# 与 tools/test-resident-dsh-service-native-assembly.sh 同构：真实 Service.send +
# 真实 DSH ACP runtime + 真实 gmgn-host-tools 插件 + 本地 loopback mock provider。
# 区别只有一处：本诊断**带真实图片附件**发一轮，并断言 provider 捕获的请求体里
# 真的出现图片内容。禁止：真实模型/真实凭据/用户 DB/App/语音/GPU/钥匙串/外网。
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_ENTRY="${REAL_ACP_ENTRY:-${GMGN_DSH_ACP_ENTRY:-$HOME/dev/deepseek-harness/packages/examples/acp-demo/lib/bin.js}}"
HARNESS_ROOT="$(cd "$(dirname "$REAL_ENTRY")/../../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gmgn-dsh-image-turn.XXXXXX")"
if [ "${KEEP_TMP:-0}" = "1" ]; then
  echo "KEEP_TMP=1 -> $TMP"
  trap - EXIT
else
  trap 'rm -rf "$TMP"' EXIT
fi

echo "== 真实 AgentConversationService.send（带图片附件）+ 真实 DSH ACP runtime + mock provider =="
REQ="$TMP/requests-image.jsonl"
CTL="$TMP/control.txt"
printf 'final\n' > "$CTL"
MOCK_OUT="$TMP/mock.out"
REQUESTS_FILE="$REQ" CONTROL_FILE="$CTL" SUCCESS_TEXT="GMGN_IMAGE_TURN_FINAL_OK" \
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

DSHHOME="$TMP/private-dsh-home"
mkdir -p "$DSHHOME"
chmod 700 "$DSHHOME"

ANCHOR="$TMP/entry/packages/examples/acp-demo"
mkdir -p "$ANCHOR/lib" "$ANCHOR/node_modules/@deepseek-ai"
for rel in \
  "llm/llm-deepseek:dsh-llm-deepseek" \
  "credentials/credentials-local:dsh-credentials-local" \
  "attachment/attachment-local:dsh-attachment-local" \
  "examples/acp-demo:dsh-acp-demo" \
  "web/web:dsh-web" \
  "web/web-fetch-http:dsh-web-fetch-http" \
  "web/web-search-deepseek:dsh-web-search-deepseek" \
  "web/tool-web:dsh-tool-web"; do
  pkg_dir="${rel%%:*}"; pkg_name="${rel##*:}"
  real="$HARNESS_ROOT/packages/$pkg_dir"
  if [ ! -f "$real/package.json" ]; then
    echo "缺少真实包: $real"; kill "$MOCK_PID" 2>/dev/null; exit 1
  fi
  ln -s "$real" "$ANCHOR/node_modules/@deepseek-ai/$pkg_name"
done
SHIM="$ANCHOR/lib/bin.mjs"
cat > "$SHIM" <<EOF
// test-only env shim（tools/diagnose-resident-dsh-image-turn.sh 生成）：
// 只设置 loopback mock 的端点/假 key 与全新私有 DSH_HOME，然后委托真实 acp-demo ACP 入口。
process.env.DEEPSEEK_BASE_URL = "$base/v1"
process.env.DEEPSEEK_API_KEY = "mock-key"
process.env.DSH_HOME = "$DSHHOME"
await import("$REAL_ENTRY")
EOF

NODE_BIN="${NODE_BIN:-$(command -v node)}"
DSH_BIN="${DSH_BIN:-$(command -v dsh)}"
if [ -z "$DSH_BIN" ]; then DSH_BIN="$HOME/.local/bin/dsh"; fi
MOCK_BASE_URL="$base" REQUESTS_FILE="$REQ" CONTROL_FILE="$CTL" \
  NODE_BIN="$NODE_BIN" DSH_BIN="$DSH_BIN" \
  GMGN_DSH_ACP_ENTRY="$SHIM" REAL_ACP_ENTRY="$REAL_ENTRY" PRIVATE_DSH_HOME="$DSHHOME" \
  swift "$ROOT/tools/diagnose-resident-dsh-image-turn.swift"
turn_exit=$?

kill -TERM "$MOCK_PID" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$MOCK_PID" 2>/dev/null || break; sleep 0.25; done
kill -KILL "$MOCK_PID" 2>/dev/null || true
if [ -f "$REQ" ]; then
  echo "mock 捕获请求数: $(wc -l < "$REQ" | tr -d ' ')"
  echo "mock 捕获的图片内容块数: $(grep -c 'data:image/' "$REQ" 2>/dev/null || echo 0)"
fi
echo "image-turn diagnosis exit=${turn_exit}"
exit $turn_exit
