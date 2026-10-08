# 旧物品编辑大测试：真实 Rust 接口验收

实际运行：

`python3 tools/test-resident-prop-editor-daemon.py --daemon /Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio/target/debug/gmgn-taskd`

根代理确认的 schema26 二进制构建 58352 退出码 0。真实运行句柄 `29466`，退出码 `0`。原始 stdout/stderr 已由 driver 直接捕获，日志路径：`/tmp/gmgn-rust-prop-editor-fb5effa9-e13f-401b-a94c-a82225ae415e.log`。

真实 SQLite 只读核验：2 个已导入的独立私有 context、3 个已提交 command、3 个已消费 UI intent。真实操作为编辑器 hold → adjustGrip → returnHeld。每个 context 使用独立临时 daemon/DB，以保持旧夹具重复 worldID=a 的不同初始状态，未更改世界身份或伪造 agent claim。

原大测试的取消、失败保留、重复提交、过期修订、迟到世界、输入路由、网格就绪与空几何、重试、行点击就绪补办、场景拾取、预览、鼠标左键放下/右键旋转/拖动相机、失焦保留装修及有界缓存断言全部通过。这些纯 UI/模型断言仍使用生产模型和逐字抽取的源码，未将它们称为每条都执行 Rust command。

宿主动作部分编译真实 RustWorldPropClient、HTTP transport 和生产 App 的 identity/command/commit 方法。旧 Swift applyPropLayout 写入与旧 PlacementFixture 壳已移除；采用真实 world_import、GLB hash/独立重读 POSITION 测量、observe、UI intent、command、receipt/snapshot 投影。Rust 未确认的动作不会写进本地 world state。

修正的夹具事实：原先居民与杯子完全重叠，Rust returnHeld 正确返回 world_prop_resident_blocked；将夹具居民站位移到 x=0.5，保持真实可达与不占据杯子 footprint，原归还断言保留。未修改生产物理规则。

所有自有 daemon PID/进程组正常回收，临时 context/资产目录清理。driver 对超时/异常保留独立 PGID watcher。没有正式应用、显示窗口、音频、真实模型或正式数据库访问。

最终移除未使用旧 PlacementFixture 后，compile-only 句柄 `74843` 退出码 `0`；该清理未改变运行路径。差异检查退出码 `0`。

边界：本文件对应 `tools/test-resident-prop-editor.swift` 大测试。`tools/test-resident-prop-editor-loop.swift` 独立后台暂停脚本尚未在本轮适配/运行，不能引用为该脚本通过。
