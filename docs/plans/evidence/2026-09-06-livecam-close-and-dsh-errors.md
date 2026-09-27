# Live Cam 关闭与 DSH 错误提示修复

日期：2026-09-06

## 本轮修复

- 关闭按钮命中后，气泡点击手势和窗口拖动手势不再竞争按钮鼠标事件。
- 相同文字及同类提示重复刷新时，保留关闭状态与全文滚动位置。
- 保留此前 224×336 固定视口及中文输入处理。
- DSH 普通聊天和空间工具两条路径均区分非零退出与正常退出空内容。非零退出显示退出码与固定错误分类，不把原始诊断、凭证或路径带进界面。

## 验证

- `tools/test-livecam-panel-sizing.swift`：118/118。包含两种尺寸、实际根视图命中、祖先手势代理过滤、原生按钮 mouseDown/mouseUp 跟踪和重复提示不重新弹出。
- 未显示窗口不能覆盖完整系统鼠标事件分发；没有将上述测试表述为用户桌面点击验收。
- `tools/test-livecam-avatar-framing.swift`：通过。三种质量下人物投影高度均约 77.31%。
- `tools/test-resident-dsh-world-loop.swift`：49/49。含两通道非零退出、空白回复及敏感诊断不泄漏。
- 两次使用生产受限配置的真实 DSH 请求分别从仓库和 `/` 运行，均退出 0 并返回 JSON。
- 生产 AgentConversationService、真实 DSH 和隔离房间检查工具完整链路通过：inspect_world 调用 1 次，返回中文最终回复。没有接入实际房间或个人文件工具。
- 历史启动失败没有复现，不能声称其底层原因已经修好。新增错误区分将帮助下次失败准确定位。
- 低优先级、单任务 macOS Debug 构建通过。已有 NSSpeechSynthesizer 弃用警告。

## 安装

- 仅替换 `/Applications/gmgn radio.app`，签名与安装产物比对通过。
- debug dylib SHA256：`38e3c663f7a45f7fa3e718bb7807afb223fdd0f91a3b6253fe9ee6e3d1a5689c`
- 旧包可从 `/Users/ghostcorn/.Trash/gmgn-radio-before-close-fix-20260906-220807.app` 恢复。
- 未启动或退出宿主、未使用桌面自动化、未访问钥匙串。需要用户重新打开应用加载新包。
