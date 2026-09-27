#!/usr/bin/env bash
# 普通用户体验真机验收辅助脚本。
#
# 本脚本**不会**启动、构建、安装或重启宿主 App，不触发系统权限，不操作窗口。
# 它只运行纯逻辑门，并打印需要用户手动完成的验收步骤；--logs 仅以只读方式
# 跟随已运行 App 的日志。
#
# 用法：
#   tools/verify-resident-ux-real-device.sh            # 逻辑门 + 手动清单
#   tools/verify-resident-ux-real-device.sh --logs     # 追加只读日志跟随
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 1

failures=0

run_gate() {
  local script="$1"
  printf '== %s\n' "$script"
  if swift "$script"; then
    printf '   exit=0\n'
  else
    printf '   exit=%s\n' "$?"
    failures=$((failures + 1))
  fi
}

run_gate tools/test-avatar-grounding.swift
run_gate tools/test-agent-failure-messages.swift
run_gate tools/test-resident-agent-loop.swift
run_gate tools/test-resident-status-lifecycle.swift
run_gate tools/test-first-use-guidance.swift
run_gate tools/test-resident-chat-transcript.swift

printf '\n逻辑门失败数：%s\n' "$failures"

cat <<'CHECKLIST'

手动验收（请在已手动启动的 App 中完成；本脚本不代劳）：
  1. 动作接地：选用 preferred.pmx 默认动作 recovery-faint-pmx 触发对应活动，
     观察脚底与躯干是否仍沉入地面；再切到跳跃/后空翻类动作，确认离地姿态未被压回。
  2. 连接失败：断开 DSH/Claude 依赖或凭证后发消息，确认只出现可行动中文说明，
     无「退出码」「stderr」「JSON」等原始字段，文字/图片已回到输入框可重发。
  3. 工具进度：连续触发电台、音乐、许愿、物件与空间动作，确认状态行是人话，
     而非「正在调用工具…」。
  4. 首次语音：首次点「录制一句」，观察系统权限弹窗期间是否卡在「正在连接」，
     以及超时后能否再次成功录音（当前预期仍可能失败，属未修项）。

  5. 最近对话：连发三条消息，确认展开聊天后能按回合回看你自己发的每一条与
     较早的回复（不止最后一条）；制造一次失败/停止，确认对应回合显示「未送达」
     而不是冒充已送达；切换空间或切换 Agent 后端后，确认看不到上一个空间/后端
     的对话。重进聊天只恢复进程内历史，重启 App 后的恢复仍是未修边界。

CHECKLIST

if [ "${1:-}" = "--logs" ]; then
  cat <<'LOGS'
只读日志跟随中（Ctrl-C 结束）。请在另一个窗口手动操作 App：
LOGS
  exec log stream --style compact --predicate 'subsystem CONTAINS "gmgn"'
fi

exit "$failures"
