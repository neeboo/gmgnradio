# 主代理独立复核（2026-10-03）

- `swift tools/test-stage-resident-chat.swift`：退出码 0，197 项通过。
- `swift tools/test-living-resident-loop.swift`：退出码 0，215 项通过；无覆盖层时的当轮工具清单包含 `play_screen`、`stop_screen`、`read_screen`。
- `python3 tools/e2e-acceptance.py --only authority,placement,wish,mcp --ledger /tmp/gmgn-e2e-parent-process-20261003.json`：退出码 0，31 条断言通过。taskd、MCP 和数据库是真实进程；生成后端是回环测试服务，物件入库参数由驱动提交，不能据此宣称真实素材生成与宿主全链通过。
- `SCREEN_PLAYBACK_WINDOW=1 swift tools/probe-screen-embed-playback.swift e2e-parent-youtube https://www.youtube.com/embed/aqz-KE-bpKQ 22`：退出码 0；使用生产承载页、官方 iframe 和真实 WebKit，播放时间前进 15.03 秒，末次 `paused=false`、`muted=false`、`readyState=4`。独立窗口探针通过，不代表应用电视覆盖层的几何或遮挡通过。
- 完整门禁首次运行失败于测试抽取代码引用不存在的 `screenStore`，该测试随后被其他工作线修正并通过独立复跑。最终门禁正在运行，结果待记录。
- `cargo test --locked -p gmgn-mcpd`：首次暴露并行授权测试的时间戳文件名碰撞。主代理给文件名增加进程内原子序号后重跑退出码 0；13 项单元测试、6 项 stdio 集成测试和 4 项架构测试通过。修改仅影响测试文件命名。
- `cargo test --locked --manifest-path services/gmgn-taskd/Cargo.toml`：退出码 0，132 项通过。
- `python3 tools/e2e-acceptance.py --skip-swift --ledger /tmp/gmgn-e2e-parent-player-20261003.json`：退出码 0，32 条检查通过（31 条进程断言 + 1 条真实播放器检查）。日志 `/tmp/gmgn-e2e-parent-player-20261003.log`。
- 主代理审阅 DSH 验收文档后补明：生成后端是返回合成 GLB 的测试夹具，世界入库由驱动显式提交，44 条包含 12 个 harness 退出码检查；尚未验收同一宿主内的完整用户流程及动作穿地画面。
