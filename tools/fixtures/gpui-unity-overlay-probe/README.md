# 聊天2：单窗口 GPUI 可行性实验

独立实验 crate，固定产品同一 gpui-kit commit、gpui-fast 0.1.2；不接
ProductHost/第二世界、模型、持久化、音乐或 TTS。不修改产品依赖与锁文件。

`gmgn_gpui_probe_mount(parentNSView)` 必须由原有宿主主线程调用，返回 0 才表示
真实 GPUIView 已装进给定 NSView。`gmgn_gpui_probe_unmount()` 同线程解绑。
实验使用 kit Input/InputState、Button 和 kit 导出的滚动元素；发送只本地回显。

EmbeddedPlatform 的 run 只执行 launch 回调，不调用 stock MacPlatform.run，
不运行第二 NSApplication loop、不替换 Unity delegate。保留隐藏 donor
GPUI window，将真实 GPUIView 移入宿主；这只是探针，内部 resize/focus/IME
仍可能引用 donor，未经运行不得认定生产可用。卸载先从宿主解除 view，
随后显式 remove_window；失败 mount 同样移除 donor，允许重新尝试。所有挂载
共享一个宿主进程生命周期的 ApplicationHandle，unmount 不提前释放它。
实际初次实验发现 MacWindow 的异步 close 回调在 App 销毁后升级 weak handle
会崩溃，因此必须保留 runtime，让外部 runloop 驱动 close/autorelease 完成。
runtime 总数有界为一，重复 mount 复用它，不创建第二 runtime。实验 dylib
必须保持加载直到宿主进程退出，不支持运行中 dlclose；尚待真实重挂载验收。

ABI 返回值明确区分：native register/attach/detach 是 1 成功、0 失败；Rust
gmgn_gpui_probe_mount 是 0 成功、负数失败。只有 native attach 返回 1 才保留
MOUNTED 和 ApplicationHandle。native 内部 probe_native_* 由 Rust 显式导出
gmgn_overlay_* wrappers，避免 cdylib 丢弃只供动态调用的 native 符号。

编译须由根协调（当前有统一构建，不并发执行）：

```
cargo +1.95.0 build --offline --manifest-path tools/fixtures/gpui-unity-overlay-probe/Cargo.toml
```

这是独立 crate 的实验 lock；不得复制或覆盖产品 Cargo.lock。首次构建会暴露
锁定 GPUI trait/API 编译差异，需先修到通过再运行。尚未编译或运行。

真实验收至少记录：同一 NSWindow 身份、宿主 delegate 未改变、宿主继续刷新，
聊天2可见、发送按钮点击、本地回显、ASCII输入、中文IME组合/提交、面板外
Unity输入、窗口缩放/Retina/fullscreen、卸载后Unity输入恢复。任何一项失败
记录原始现象；独立窗口可见不能计作成功。

源码依据：core app.rs run_embedded/with_platform 为可扩展接口；stock macOS
window.rs MacWindow::open 自建窗口，未提供外部window adoption。后续真正
适配可用公开 gpui-fast-apple MetalRenderer::from_layer 接独立透明CAMetalLayer，
并实现 PlatformWindow 的真实宿主 geometry/input/IME/frame/lifecycle，而非
将 donor 探针直接推广。
