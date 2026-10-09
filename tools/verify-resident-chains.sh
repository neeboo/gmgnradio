#!/usr/bin/env bash
# 五链无人值守验证的**一条命令**入口。
#
#     tools/verify-resident-chains.sh              # 跑全部五条链
#     tools/verify-resident-chains.sh --only B     # 只跑 B 链（A/B/C/D/E 均可）
#     tools/verify-resident-chains.sh --json tmp/verify-chains/ledger.json
#
# 它做的事只有三件：确保有一个真 `gmgn-taskd` 二进制、调用
# `tools/verify-resident-chains.py`、把退出码原样传出去（全 PASS=0 / 有 FAIL=1 /
# 缺二进制=2）。
#
# 边界（与 harness 同一套，别在这里偷偷放宽）：不打包、不装机、不占版本号、
# 不点界面、不抢焦点、不播放音频、不改分辨率/音量/设备、不触发钥匙串、
# 不 rm 用户数据（daemon 只在自己的临时 root 上跑）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CARGO_BIN="${CARGO:-cargo}"
BIN=""

# 找到（或造出）一个真二进制。优先 release：debug 也真，但慢一截。
for candidate in target/release/gmgn-taskd target/debug/gmgn-taskd; do
    if [[ -x "$candidate" ]]; then BIN="$candidate"; break; fi
done

if [[ -z "$BIN" ]]; then
    echo "未找到 gmgn-taskd，正在构建 release（--locked，离线）…" >&2
    # 与仓库其它 target 一致：离线、锁定依赖。
    CARGO_NET_OFFLINE="${CARGO_NET_OFFLINE:-true}" \
        "$CARGO_BIN" build --locked --release -p gmgn-taskd --bin gmgn-taskd >&2
    BIN="target/release/gmgn-taskd"
fi

echo "daemon: $BIN" >&2
TASKD_BIN="$BIN" exec python3 tools/verify-resident-chains.py "$@"
