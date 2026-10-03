# GPUI Kit 居民对话组件

首个 2D UI 迁移切片。仅使用 GPUI Kit 0.7 的 Input、Button 和 stock ScrollableElement，颜色来自现成 Theme tokens；宿主负责选 ThemeMode。独立 Rust 1.95 workspace，不读取生产配置、Keychain 或录音设备，不替换 SceneKit/Metal。

```rust,ignore
let pane = cx.new(|cx| ResidentChatPane::new(window, cx).compact(is_compact));
// 宿主消费 pane.take_commands() 的 ChatCommand::Send / Cancel。
// 实际接受发送后调用 accepted(request_id, window, cx)。
// 实际失败调用 failed(request_id, notice, window, cx)。
// 实际业务回复调用 reply(request_id, text, cx)。
// 主机展示快照调用 set_transcript(lines, cx)，进度调用 progress(id, text, cx)。
```

发送期间保留草稿，实际接受才清除未编辑草稿。发送或回复失败恢复提交原文并保留并发编辑；重复/过期回调无效。Enter 使用 Kit InputEvent，复制使用 Kit Button + 系统剪贴板。图片入口明确禁用：当前组件不能接受附件，既有 Swift 附件界面仍应保留，不能用此切片覆盖含图片的草稿。ASR/TTS 控件未迁移。

组件尚未接入 taskd transport，也没有伪造成功回复。状态测试与编译不代表生产完整流程或小窗视觉验证通过。

```sh
cargo +1.95.0 test --manifest-path apps/gpui-ui/Cargo.toml --locked
cargo +1.95.0 fmt --manifest-path apps/gpui-ui/Cargo.toml --check
```
