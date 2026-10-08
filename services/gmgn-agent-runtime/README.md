# GMGN Rutis runtime

生产接入候选封装，模型／工具循环直接使用 `arcships/rutis` 的 `rutis-agent`，固定提交 `330ff51b65c0178ab205abb377f6d9dbcd7225fd`。未接入的自写循环试验模块已移除。

`RutisRuntime::new` 注入 `Arc<dyn aimux_core::LanguageModel>` 和明确授权的 contextual `Vec<ToolDef>`。定义与白名单必须完全匹配，不加载 `minimal_tools`、`bash` 或 `replace_text`。注册前执行门控，阻止未授权、空／重复调用 ID 和超额工具调用；同一运行时的历史调用 ID 不重新执行。

正式工具适配入口为 `new_host(model, schemas, HostToolExecutor, config)` 与 `followup_with_identity(input, TurnIdentity)`。world、scope、session、run ID 均由可信宿主提供，不能从模型参数读取；run ID 不允许重用。执行器得到完整 call ID、工具名、参数及取消 token。仅身份与 call ID 全匹配且状态为 `Completed` 的回执可成功；旧 session、错配、未知、异常、panic 和取消后的回执会失败并取消该 turn，不自动重试。这里没有自建 ledger，持久化授权与幂等职责保留给 taskd。

`followup` 使用上游持续会话，`subscribe_text` 提供有界广播（落后接收者须处理 `Lagged`），`cancel` 中止当前上游 turn，`shutdown` 卸载上下文。taskd 候选 `RuntimeService` 已接入认证 HTTP、SQLite 工具账本和宿主回执队列，不持久化模型会话或凭据；正式应用的模型选择尚未切换。

## 尚待解决的上游边界

- 原上游 TUI 依赖为强制依赖；本地 vendor 已改为默认开启的可选 feature，GMGN 明确关闭，详情见 `vendor/rutis/GMGN-PATCHES.md`。
- 原 `ToolDef` runner 只接收参数 `Value`；本地第 4 项补丁提供 `ToolExecutionContext` 与 `new_contextual`。GMGN 封装拒绝旧参数型工具，既有上游构造函数仍保留。
- 原固定提交建立 `do_stream` 阶段没有取消 select；本地 vendor 最小补丁增加取消竞争。
- 原固定提交流结束未收到 `Finish` 时会将局部文本认作最终成功；本地 vendor 最小补丁将其变为明确失败，已收集的工具调用不会执行。
- 上游普通工具失败会反馈模型；GMGN `new_host` 对不明确结果立即取消并保留失败结论，阻止它被最终模型回复伪装为成功。跨 turn 的副作用授权与幂等需 taskd 负责。
- 上游只有模型步数／会话 token 预算；本层增加调用数门控，provider 流适配层限制总字节和全请求时间，taskd 文本回执上限为 1 MiB。

## HTTP 模型与宿主集成

`provider::build_provider` 接收明确的 `openai`、`deepseek` 或 `alibaba` 配置。endpoint/model/key 必须显式给出，密钥仅在内存使用，不读取环境凭据；不支持的 backend 明确拒绝。请求不自动重试。aimux 无原生 OpenAI registry 项，OpenAI 使用其官方 provider 构造 API。

真实 loopback HTTP/SSE 测试覆盖工具调用、身份回执、第二轮回填与最终文本，以及缺少结束信号、畸形 SSE、超时和取消；完整 runtime 16 项回归通过。taskd 真实隔离进程 3 项测试已通过，包括认证 HTTP → 本机模型 fixture → Rutis → 工具回执 → 下一轮文本 → SQLite 终态。这些测试未连接公网模型、Unity 执行器或正式应用。

图片输入、工具图片回执及同轮 steering 已实现并通过隔离 HTTP 和回合测试；现有 CLI 登录后端的等价消费尚未实现，不满足该门禁时不切换正式模型路径。未知副作用只允许可信宿主根据实际状态核验，不能通过换 runID 重放。

原始固定提交已实测：3 个常规用例通过，2 个负对照复现风险（建流取消后 100ms 仍不返回；去除 Finish 后返回 partial 成功），退出码 0。负对照原始二进制重跑日志：`/tmp/gmgn-rutis-upstream-boundaries-baseline.log`。

`tests/upstream_boundaries.rs` 已改为补丁的正向回归测试：建流取消及时返回、缺少 Finish 明确失败、缺少 Finish 时不执行已收集工具。vendor 补丁构建后使用 `cargo +1.95.0 test -p gmgn-agent-runtime --locked --offline -j 1` 独立复验：3 个常规测试和 3 个补丁回归测试全部通过，退出码 0；日志 `/tmp/gmgn-rutis-runtime-patched-tests.log`。验证未包含生产模型、GMGN HTTP 工具、正式应用或跨平台真机。

第 4 项 contextual 补丁后同命令复验：10 个测试通过，退出码 0；日志 `/tmp/gmgn-rutis-host-context-final-tests.log`。新增宿主 mock 测试包含正常关联、旧 session／错 call ID／未知／异常／panic／取消后的结果不成功、真实 token 取消传播和拒绝旧工具。1.95.0 工具链未安装 Clippy，未将其报告为通过。
