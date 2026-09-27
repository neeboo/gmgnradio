#!/bin/bash
# Offline real Service.send + ACP runtime; mock business handlers, no App/credentials/network beyond loopback.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_ENTRY="${REAL_ACP_ENTRY:-${GMGN_DSH_ACP_ENTRY:-$HOME/dev/deepseek-harness/packages/examples/acp-demo/lib/bin.js}}"
HARNESS_ROOT="$(cd "$(dirname "$REAL_ENTRY")/../../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gmgn-dsh-wish-reference-assembly-run.XXXXXX")"
cleanup() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill -TERM "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  if [ "${KEEP_TMP:-0}" = "1" ]; then echo "KEEP_TMP=1 -> $TMP"; else rm -rf "$TMP"; fi
}
trap cleanup EXIT
overall=0

echo "== 真实 AgentConversationService.send + ACP + loopback provider（三工具连续交付）=="
REQ="$TMP/requests-service.jsonl"
MOCK_OUT="$TMP/mock.out"
REQUESTS_FILE="$REQ" \
  node "$ROOT/tools/resident-dsh-wish-reference-mock.mjs" > "$MOCK_OUT" 2>&1 &
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

# 私有 DSH_HOME（全新临时目录，0700；子进程经 shim 只指向这里）。
DSHHOME="$TMP/private-dsh-home"
mkdir -p "$DSHHOME"
chmod 700 "$DSHHOME"

# 临时锚点 + env-shim 入口（仅注入 loopback mock 值；随后委托真实 acp-demo bin.js）。
ANCHOR="$TMP/entry/packages/examples/acp-demo"
mkdir -p "$ANCHOR/lib" "$ANCHOR/node_modules/@deepseek-ai"
# makeResidentSandbox 按入口祖先目录找 node_modules/@deepseek-ai/<pkg> 以链接 sandbox；
# 这里把真实安装的 8 个挂载包软链进锚点（只读指向真实源码，不复制、不改写）。
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
// test-only env shim（tools/test-resident-dsh-wish-reference-assembly.sh 生成）：
// 只设置 loopback mock 的端点/假 key 与全新私有 DSH_HOME，然后委托真实 acp-demo ACP 入口。
process.env.DEEPSEEK_BASE_URL = "$base/v1"
process.env.DEEPSEEK_API_KEY = "mock-key"
process.env.DSH_HOME = "$DSHHOME"
await import("$REAL_ENTRY")
EOF
echo "env-shim entry: $SHIM"
echo "real acp-demo entry: $REAL_ENTRY"

NODE_BIN="${NODE_BIN:-$(command -v node)}"
DSH_BIN="${DSH_BIN:-$(command -v dsh)}"
if [ -z "$DSH_BIN" ]; then DSH_BIN="$HOME/.local/bin/dsh"; fi
MOCK_BASE_URL="$base" REQUESTS_FILE="$REQ" \
  NODE_BIN="$NODE_BIN" DSH_BIN="$DSH_BIN" \
  GMGN_DSH_ACP_ENTRY="$SHIM" REAL_ACP_ENTRY="$REAL_ENTRY" PRIVATE_DSH_HOME="$DSHHOME" \
  swift "$ROOT/tools/test-resident-dsh-wish-reference-assembly.swift"
assembly_exit=$?

kill -TERM "$MOCK_PID" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$MOCK_PID" 2>/dev/null || break; sleep 0.25; done
kill -KILL "$MOCK_PID" 2>/dev/null || true
if [ -f "$REQ" ]; then
  echo "mock(service) 捕获请求数: $(wc -l < "$REQ" | tr -d ' ')"
fi
echo "service-native assembly exit=${assembly_exit}"
if [ $assembly_exit -ne 0 ]; then overall=1; fi

echo
if [ $overall -eq 0 ]; then
  echo "WISH REFERENCE ASSEMBLY EXIT=0"
else
  echo "WISH REFERENCE ASSEMBLY EXIT=1"
fi
exit $overall
