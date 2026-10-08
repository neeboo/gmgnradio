# 后台编辑暂停循环：真实 Rust 验收

命令：

`python3 tools/test-resident-prop-editor-loop-daemon.py --daemon /Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio/target/debug/gmgn-taskd`

使用根代理确认的 schema27 budget 构建 35505（构建退出码 0）。实际运行句柄 `63060`，退出码 `0`。

原始 stdout/stderr 由 driver 捕获，日志：`/tmp/gmgn-rust-prop-editor-loop-3dce819c-4cdd-4c40-ba12-57a129e7a215.log`。日志含随后真实 SQLite 核验和清理结果。

编译、运行真实 ResidentAgentLoop、RustResidentSchedulerClient、ResidentMemoryStore、RustResidentIntentClient、ResidentStateClient、TaskdHTTPTransport；夹具 transport 仅发送实际私有 HTTP，不生成调度结果或意图规则。宿主临时编辑取消、明确停止、作用域关联方法仍逐字从生产 App 提取。

原断言全部保留并通过：首次后台轮启动；编辑取消不保存持久用户暂停；不把编辑变成用户停止；ready continuation 恢复第二轮；编辑过程中显式停止保存暂停；退出编辑不解除停止；invalidate 不新增或清除用户暂停。

额外真实核验：

- 每次调用开始前，通过 actual agent_loop_read 核验同 runID/hostSessionID 已持久 claimed。
- 两次取消仅在夹具自己拥有的 sleep 调用实际抛出 CancellationError、确认该调用已结束后，提交同 ticket 的取消确认。夹具无模型、工具或外部副作用；没有用取消请求冒充终止。
- SQLite 中恰有 2 个不同 runID、同 fixture-host、state=cancelled、started=true 的回执；claimed_at 均保留，未释放已执行后台预算；无第三个事件或未知执行。
- 明确停止的宿主回调次数为 1（与持久写入次数区分）；通过真实 resident_intent_restore 核验 intentPausedByUser=true。
- 私有 daemon PID 和独立进程组两次 stop 后均不存在；临时目录清理。没有正式应用、显示窗口、音频、模型、用户数据库或凭据访问。

测试等待真实异步 claim/恢复/取消/暂停回执，使用有上限的条件等待，未降低原断言。生产源码未修改。Swift 6 编译出现两个已有的 try? 结果未使用警告，不影响退出码。
