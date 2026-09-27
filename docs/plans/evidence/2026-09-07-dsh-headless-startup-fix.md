# DSH 纯文字启动失败修复

日期：2026-09-07。对应截图：DSH 执行失败，退出码 1，未能确定原因。

## 根因与修复

- 在精简桌面环境、工作目录 `/` 中，用生产受限配置复现退出码 1。实际错误是 `ERR_MODULE_NOT_FOUND`：headless 配置无法解析 `@deepseek-ai/dsh-web-fetch-http`，模型尚未开始回复。
- 该包是 DSH 官方网页读取组件，与原生搜索组件分工不同。此前启用了网页读取，却未把组件加入 headless 配置的依赖；原先的配置转储检查不会真正加载组件，因此没有发现缺失。
- 通过正式命令 `dsh plugin --profile headless add link:/Users/ghostcorn/dev/deepseek-harness/packages/web/web-fetch-http` 接入本机已有官方组件。仅修改 headless 的依赖配置，没有改密钥、会话、DSH 源码或原生搜索能力。
- 同一环境再次运行受限启动探针，退出码 0，返回合法最终回复「你好」。
- 应用新增组件缺失的固定错误提示，原始诊断、私有路径和凭证不会显示到界面。
- 真实网页测试还暴露出正文双引号未转义的问题；补充 JSON 字符串转义与中文引用规则，未放宽解析器、权限或重试上限。

## 验证

- 错误分类夹具：先红后绿；提示不泄漏测试密钥或路径。
- 输出规则回归：先红后绿。最终 `swift tools/test-resident-dsh-world-loop.swift` 通过 116 项会话检查及 21 项离线优先级检查。
- `swift tools/probe-resident-dsh-headless.swift --live`：使用生产 AgentConversationService、桌面精简环境与 `/` 工作目录，无宿主启动。文字阶段实际调用隔离 `inspect_world` 1 次并返回回复；独立网页阶段返回有效最终回复。
- 网页阶段真实记录：会话 `0c73a986-4772-4ddd-8a10-63a65bacf954`，`web_search` 调用 `call_00_tnE3955nlRNHNWhYx88R0967` 返回 8 条来源，`web_fetch` 调用 `call_01_8NCumwbFCTFvJd1K8x4Q9386` 读取 example.com 返回 HTTP 200，最终 completed。没有把回复里出现网址当作调用证据。
- 首次混合请求测试未通过：模型曾声称已检视房间却未调用宿主工具。最终分阶段验证没有解决或证明混合任务顺序可靠，此项保留为模型遵循问题；不计入本次启动故障修复通过范围。
- macOS Debug 完整构建通过。未启动或重启宿主、未进行 GPU 或实际界面验收。

## 安装与清理

- 已替换 `/Applications/gmgn radio.app`。
- 安装程序 debug dylib SHA256：`360324adef05e0534de4814547f47d234c6d7c38175ebdfe0a24dfad71a1a8ab`，与构建产物一致。
- 唯一保留安装包：`apps/macos/Build/Packages/gmgn-radio-20260907-2113-debug.zip`，完整性检查通过，SHA256 `780ca071dff1e242270a2018442d262548dbefdec2c6284b242cbc2071963bdc`。
- 旧应用、20:33 包及未交付的 21:10 中间包移到 `/Users/ghostcorn/.Trash/gmgn-before-dsh-fix.9imMpj`，可恢复；没有保留构建目录的应用副本。
- 安装后清除构建扫描重新登记的两项 `.service` 配置入口。最终应用登记只有 `/Applications/gmgn radio.app`；历史未挂载磁盘映像的容器记录不是应用条目。
