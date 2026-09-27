# DSH 桌面启动缺少凭证

日期：2026-09-06

## 根因与对照验证

上一轮真实测试继承了终端的 `DEEPSEEK_API_KEY`，没有覆盖桌面应用缺少该环境变量的情况。仅改变工作目录不足以验证这个差异。

本轮使用精简环境、根目录工作目录和相同受限配置重现退出码 1。原始诊断明确为 `MISSING_CREDENTIAL`，指出 `deepseek-official` 缺少 `DEEPSEEK_API_KEY`。诊断未含密钥值。

通过本机 DSH 的 `LocalCredentialProvider` 正式接口，将当前已有密钥保存到 DSH 原生本地凭证库。写前确认没有已有配置，写后用同一接口核对匹配且来源为 `file`。文件权限为 0600，不使用钥匙串，不改变模型或服务地址。

随后同一精简环境中的生产 AgentConversationService 探针退出 0：调用隔离房间的 `inspect_world` 一次，再返回中文最终回复。未暴露真实房间、桌面或个人文件工具。

## 代码与测试

- `MISSING_CREDENTIAL` / `no API key` 现在归为独立的缺少凭证提示，说明终端环境与桌面启动的差异。
- 原始诊断及凭证值不进入界面。
- `tools/test-resident-dsh-world-loop.swift`：57/57，通过；新增案例先红后绿。
- 本轮没有改变自主调度、工具权限、模型选择或桌面交互。

## 边界

上述结果为真实外部服务调用与无宿主集成验证。没有启动、退出或自动操作 gmgn radio，也没有将探针结果当成桌面运行验收。DSH 每次启动会自动读取其原生凭证，不需要应用通过登录 Shell 获取全部环境。

## 安装

- 单任务、低优先级 Debug 构建成功；已替换 `/Applications/gmgn radio.app`。
- 签名验证及安装文件比对通过。debug dylib SHA256：`6eb84c4ccc159beb9f7d0c50ee59d5f91346cba71afe0801719ec7bd5816db34`。
- 旧包移至 `/Users/ghostcorn/.Trash/gmgn-radio-before-dsh-credential-fix-20260906-222701.app`，可恢复。
