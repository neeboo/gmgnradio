# 跨平台空间客户端验证工程

独立 Cargo workspace，Bevy 0.19.1 / Rust 1.95。与 Swift 应用及 Rust 服务构建隔离。场景是程序生成的 **fixture**，不是用户世界，也没有修改业务权威。Bevy/wgpu 自动选择平台后端（macOS Metal、Windows 通常 DX12；实际以启动日志和报告为准）。

```sh
cargo +1.95.0 run --manifest-path apps/cross-platform/Cargo.toml -- --headless-smoke
cargo +1.95.0 test --manifest-path apps/cross-platform/Cargo.toml
cargo +1.95.0 run --release --manifest-path apps/cross-platform/Cargo.toml -- --benchmark-seconds 30 --report /tmp/gmgn-bevy-fixture.json
```

WASD 移动占位角色，Space 做原地转身，右键拖动/方向键环绕镜头，Escape 退出。占位角色中心固定在地面上方 0.7m，限制房间边界；这只是输入与约束验证，不代表骨骼重定向、角色碰撞或穿地问题已经解决。电视画面是真实 3D mesh，当前无视频帧、无音频，不伪装播放。UI 仅用于验证说明，不替代中文聊天、收件箱或音乐库。

从本工程目录运行时，`--scene sample.glb` 可加载 `assets/sample.glb` 的第一个 scene；不要给路径重复加 `assets/`。资源不依赖主仓库资产。加载失败会记录错误；benchmark 不断言 GLB 已加载完成。

窗口 benchmark 排除前 2 秒启动预热，输出 p50/p95/p99 更新间隔、33/50ms 长帧、实际 GPU adapter/backend、mesh 数量。它采样 CPU app update 间隔，含调度/呈现影响，不是 GPU 时间。空房间的结果不能证明正式应用性能，不能与不同场景的 Metal 平均 FPS 直接对比。

后续集成边界：复用 taskd 的状态/事实协议，避免 ECS 成为第二业务权威；媒体解析/解码独立于渲染，以纹理桥接接口接入。平台窗口、输入法、无障碍、菜单、签名和更新尚未实现。macOS 和 Windows 应分别完成真实窗口启动、adapter readback、中文输入、音视频和同场景性能验收后再决策迁移。

## 首次本地验证（2026-10-03）

macOS arm64 / Rust 1.95.0：`cargo check`、`cargo fmt -- --check`、`cargo test --locked` 均 exit 0；4 个测试通过，包含实际 ECS controls 系统的模拟按键输入、固定时钟与地面约束验证。`cargo run --locked -- --headless-smoke` exit 0。首次完整依赖 codegen 约 25 分钟；这属于构建耗时，不能用来判断运行帧率。Windows 与 GPU 窗口运行在此记录时尚未验证。
