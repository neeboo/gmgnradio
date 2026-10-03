# gmgn GPUI 产品入口

GPUI 拥有 NSApplication 和窗口，Kit ResidentChatPane 调用真实 ProductHost / AppDelegate。
保留原应用居民对话、世界工具、任务、音频和存储路径；不另建代理或认证方式。
同窗挂载原 StageRenderSurfaceController 的真实渲染视图。原空间、音乐、小窗、完整设置、通知和装修入口继续可用。
同窗重挂原 StageWorldInteractionView，拾取、摆放与输入行为仍需真实 App 验收；这不是完整 UI 迁移完成。

先构建 ProductHost 和当前原 E2E App，再运行：

```sh
bash tools/build-gpui-product-app.sh "$PWD/tmp/gpui-product-app-v1/gmgn radio.app"
cargo +1.95.0 test --manifest-path apps/gpui-app/Cargo.toml --locked --offline --target-dir tools/gpui-scenekit-probe/target
```

构建脚本只接受不存在的 tmp App 路径，复用本轮原 App Helpers 并验证完整性。
Helpers 字节原样存放 Resources/Helpers，Contents/Helpers 使用相对符号链接保持原 runtime 查找路径，避免完整性清单被签名工具视为嵌套可执行代码。外层签名、真实 Mach-O/framework 签名与独立 manifest 分别验证。
测试 bundle ID 为 ai.gmgn.radio.e2e；主代理启动时通过原 E2ERuntime 的 GMGN_E2E_DATA_ROOT 隔离数据。
正常产品配置和测试配置仍由原 runtime 决定，没有 key/backend 覆盖。
GMGN_GPUI_COMPACT=1 选择小窗布局。关闭窗口保留原 macOS 后台运行语义；退出进程关闭原 runtime。
Rust 构建复用已安装依赖和现有 GPUI target 缓存，不安装或升级依赖。
编译、签名、manifest 检查不能替代真实 App 渲染、聊天、世界操作、音乐和恢复验收。
