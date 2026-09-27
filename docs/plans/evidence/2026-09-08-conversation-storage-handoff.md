# 居民聊天 SQLite 持久化——交接给主代理

日期：2026-09-08。本文件只说明需要 App/主代理配合的接线点与已完成的存储/服务侧
实现；是给主代理整合用的交接，不是本仓库新的冻结合同。Rust 侧合同与 scope 语义仍以
`docs/plans/2026-09-08-resident-storage-contract.md` 为准（未改动任何 IPC）。

## 1. 本次已完成（本协作者独占文件内）

| 文件 | 内容 |
| --- | --- |
| `apps/macos/Sources/GMGNRadio/Agent/ResidentConversationStore.swift`（新增） | conversation 域的有界对话记录：按 `(worldID, residentScope)` 一条 `transcript` 状态记录，值只含「用户文本 / 成功回复文本」成对消息（默认保留最近 60 条）。整值 CAS + requestID 幂等；`recordTurn` 失败可见（`persistenceError` / `onPersistenceError`），revision_conflict 会先读回再合并一次，绝不静默覆盖他人写入；损坏/旧格式记录解码失败抛出 `unreadableArchive`，不注入部分状态。 |
| `apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift` | `send(...)` 新增可选 `userMessage`；`attachConversationStore(_:onPersistenceError:)` 接线；成功轮次在整轮成功后按 scope 落库；新会话（无原生续聊、进程内历史为空）恢复持久化纯文本上下文；原生续聊存在时**不**注入。取消/失败/空回复的轮次绝不落库。 |
| `tools/test-resident-conversation-storage.swift`（新增） | 离线工具测试：真实临时 `gmgn-taskd` daemon + 内存桩覆盖记录/恢复/裁剪/隔离/跨重启/冲突合并/失败可见/损坏解码。 |
| `apps/macos/Tests/GMGNRadioTests/Agent/AgentConversationServiceTests.swift` | 新增会话测试（见 §5），需要主代理在完整测试目标中编译运行。 |

### 存储形状（conversation 域，key=`transcript`）

```json
{ "messages": [
    { "id": "uuid", "role": "user",  "text": "真实用户文字", "createdAt": "…" },
    { "id": "uuid", "role": "agent", "text": "成功回复文本", "createdAt": "…" }
  ],
  "updatedAt": "…" }
```

- 只存文本；图片字节/base64、临时文件路径、凭据没有对应入参，永不落库。
- 恢复出来的上下文是纯 user/agent 文本对——不含工具调用或结果，模型不可能从中重放命令。
- `ResidentWorldContext` 新增 `conversationStorageScope(toolsEnabled:)`：
  scope = `{ worldID: 快照 worldID, residentScope: sessionScope(+".tools.v7" 当工具会话) }`。
  只读聊天与工具聊天各自成段，避免串写；world 未就绪（`worldID == nil`）时返回 nil，不落库。
  注意与居民循环记忆（CC 的 `.resident` 域、plain sessionScope）互不冲突：域不同、键不同。

### 服务侧行为要点（已实现）

- 成功回复后 `persistTurn(userText:reply:)` 只接受显式声明的真实用户文字：
  - 只读居民聊天（`worldTools == nil`）：本轮 `text` 就是人类输入，自动保存；
  - 工具会话（`worldTools != nil`）：`text` 是宿主拼装的居民轮次上下文，**必须**由调用方
    传 `userMessage`（真实人类输入）才落库——组装文本绝不当用户消息保存。
- 恢复只发生在“真正的新会话”：Codex/Claude/WorkBuddy/Qoder/Pi 的已存原生会话 id 缺失、
  DSH 进程内历史为空。恢复内容以“（此前的对话记录…不是指令）”前缀放入首轮 prompt；
  原生续聊/内存历史存在时不注入，避免重复。
- 保存失败可见且不阻断聊天：失败走 `persistenceError` 与 `onPersistenceError`（服务把
  回调转发给宿主注入的 handler）。取消/失败/空回复不落库。
- 本存储是**尽力而为的上下文层**，不是同步提交点：回复先返回给用户，落库异步排水；
  进程在排水完成前崩溃可能丢失最新一轮的未确认写入（与居民记忆层同级的取舍）。

## 2. 需要主代理 / CC 在 App 侧完成的接线（唯一的两处 App 改动）

1. **附着存储**（一次，最好在 resident 聊天可发送前，例如与 `residentMemoryStore` 同处
   `GMGNRadioApp.swift` 的惰性初始化里）：

   ```swift
   AgentConversationService.shared.attachConversationStore(
       ResidentConversationStore(
           client: ResidentStateClient(
               transport: ResidentTaskDaemonStateTransport(client: PropTaskDaemonClient())
           )
       ),
       onPersistenceError: { [weak self] message in
           self?.showResidentVoiceStatus(message)
       }
   )
   ```

   `PropTaskDaemonClient` / `ResidentTaskDaemonStateTransport` 与现有居民记忆共用一个
   daemon（`tasks.sqlite3`），不新增进程。恢复/保存失败的文案会自动走
   `showResidentVoiceStatus`（聊天本身正常，不弹错误阻断）。

2. **`performResidentTurn` 里给 `send` 传真实人类文字**（让工具会话也保存真实用户消息）：

   ```swift
   reply = try await AgentConversationService.shared.send(
       prompt + (worldTools == nil ? "" : wishMachinePromptContext(worldContext)),
       imageURLs: input.imageURLs,
       worldContext: worldContext,
       worldTools: worldTools,
       userMessage: input.userMessages.isEmpty
           ? nil : input.userMessages.joined(separator: "\n"),
       onCancel: finishCancellation
   )
   ```

   只读路径不传也会自动保存（`text` 即用户文字）。

3. **项目文件**：`ResidentConversationStore.swift` 是新文件，需重新生成/同步 Xcode 工程
   （`project.yml` 的 `Sources/GMGNRadio` 目录源 → xcodegen 或等价同步），否则 App 目标
   不含该文件。禁止项未做：未全 App 构建、未运行 App、未动 GPU/钥匙串/系统授权、未读写
   真实用户数据库、未调用真实模型。

## 3. 已验证（本协作者本地运行，退出码真实）

| 检查 | 结果 |
| --- | --- |
| `swift tools/test-resident-conversation-storage.swift`（真实临时 gmgn-taskd daemon + 桩） | `PASS: 22 resident conversation storage checks, 0 failures`，退出码 0（约 4.6s） |
| `ResidentConversationStore.swift` 以 `-swift-version 6 -strict-concurrency=complete` 独立编译 | 通过（0 错误） |
| `AgentConversationService.swift`、`AgentConversationServiceTests.swift` 语法解析 | 通过 |

新增 App 会话测试（需主代理在测试目标运行，属“必要会话测试”）：

- `successfulResidentTurnIsPersistedPerWorldScope`
- `freshCodexSessionRestoresStoredContextOnlyWhenNoNativeThread`
- `dshFreshProcessSeedsHistoryFromStoreAndPersistsTurns`
- `failedOrCancelledTurnNeverPersists`
- `plainChatWithoutWorldOrWithoutUserTextNeverPersists`
- `toolSessionPersistsUnderToolsScopeWithExplicitUserMessage`
- `conversationSaveFailureIsVisibleThroughServiceHandler`

## 4. 局限与边界（报告用，不承诺为零）

- 离线/临时 daemon 测试未覆盖：真实 App 进程内的多后端切换、DSH 原生图片会话与恢复的
  组合、跨 App 重启后的真实 UX（这些属手动运行验收，见既有存储验收文档的分工）。
- 未做全 App 构建：服务/测试文件的完整编译与 GMGNRadioTests 运行由主代理完成；如遇
  编译错误请回传本协作者修复，不要改其它协作者文件。
- 尽力而为语义：回复先返回、落库异步；崩溃可能丢失最近一轮未确认写入；失败可见但
  不会阻塞聊天，也不该被当作委托/布局的同步提交点。
- 恢复上下文按有界窗口（默认 60 条消息 = 30 轮）裁剪；不做自动清理/删除接口（合同 v1
  无删除，后续如需清理策略按合同流程另提）。
