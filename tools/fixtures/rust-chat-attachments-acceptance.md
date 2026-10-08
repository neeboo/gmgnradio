# Rust 附件真实链路验收

已运行命令：

`python3 tools/test-rust-chat-attachments-daemon.py --run --daemon /Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio/target/debug/gmgn-taskd`

使用根代理确认的 schema24 二进制（统一构建 98695，退出码 0）。本次实际运行进程句柄为 `25112`，退出码 `0`。原始 stdout 在此次 Codex exec 工具回执中，未另存原始日志；本文件是验收记录，不冒充原始日志。

实际通过内容：

- Swift 6 编译真实 client、Store、ImageIO preparation、Unity bridge。
- 真实私有 HTTP/SQLite 注册、精确 CAS、frame generation、session、图片 hash/权限验证。
- Store 两张提交后追加两张并恢复到四张；再提交、追加两张、恢复到六张，明确禁止溢出发送。
- 已恢复后移除图片，重复恢复不重新添加；提交过的文件保留，未提交文件依据 Rust 删除回执删除。
- 丢一次真实 take 响应：`take` 调用计数等于 1，`read` 至少 1；恢复原 immutable submission，不重发 take。
- 丢一次真实 remove 响应：`remove` 调用计数等于 1，`read` 至少 1；读取持久删除能力后原生删除。
- SQLite 中共 6 个 authority owner；跨 session 未确认 submission 保持 unknown；所有留存文件 hash、byteCount 与 0600 权限核验通过。
- 私有 daemon 两次启动，重启前后持久 facts/submission 完全一致。
- PID 和进程组均核验已回收，重复 stop 安全；临时目录已清理。未打开正式应用、窗口或播放音频。

此次真实运行修复的阻断：fixture readiness 从已退役 `world_list` 改为只读 `capability_contract`；生产 Store 保留 POSIX realpath，避免 Foundation 将 `/private/var` 改回 `/var` 导致 Rust exact-path 校验拒绝。

边界：此结果覆盖私有 daemon 附件链路，不代表完整正式 App 构建或现场 Finder UI 验收；旧消费者脚本另行迁移验收。
