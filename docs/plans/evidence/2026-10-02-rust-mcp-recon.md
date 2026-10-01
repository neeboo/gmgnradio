# Rust 侧 MCP 面：勘察结论与切换清单

**日期**：2026-10-02 · **HEAD**：`6168747` · **设计依据**：[2026-10-02-rust-world-authority-and-mcp.md](../2026-10-02-rust-world-authority-and-mcp.md)

本文是那次勘察的可复核结论 + 落地清单。四份勘察答案在前，落点清单在后。

---

## 1. DSH 侧到底怎么挂一个 MCP server

**结论：用 composition 的插件行，字段来自 `@deepseek-ai/dsh-mcp-client` 自己的配置面；`session/new` 那条 ACP 的 `mcpServers` 是另一条路，本机这条链路没走它。**

### 1.1 生产路径用的是 composition（`ResidentDSHConfiguration.swift`）

`ResidentDSHComposition.residentYAML` 生成一份 cordis YAML，每行一个插件：`- id:` / `name:` / 可选的 `config:`。`@deepseek-ai/dsh-mcp-client` 就是**一个这样的插件**，所以挂 MCP server == 加一行。

### 1.2 该插件的真实配置字段（权威来源）

`/Users/ghostcorn/.nvm/versions/node/v25.5.0/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-mcp-client/README.md`（版本 `0.1.5-rc.3`）"Minimal configuration" 一节：

```yaml
- id: mcp-github
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: github
    transport: stdio
    command: npx
    args: ['-y', '@modelcontextprotocol/server-github']
    env:
      GITHUB_TOKEN: !!js process.env.GITHUB_TOKEN
```

字段表（同 README）：

| 字段 | 默认 | 含义 |
|---|---|---|
| `transport` | 必填 | `stdio` 或 `streamable-http` |
| `serverName` | 必填 | 工具名命名空间；`[A-Za-z0-9_-]{1,32}`，同一注册域内唯一 |
| `command` / `args` / `env` / `cwd` | — | stdio：可执行文件、参数、**叠加在擦洗过的环境之上**的额外环境、工作目录 |
| `url` / `headers` | — | streamable-http 的端点与请求头 |
| `toolCallTimeoutMs` | `60,000` | 每次 `tools/call` 的超时 |
| `failOnStartupError` | `false` | 首次连接/工具同步失败时是否让插件加载失败 |
| `reconnect.enabled` | `true` | 断线自动重连 |

**工具命名**：客户端看到的每个工具是 `mcp__<serverName>__<rawName>`（README "Tool naming and coexistence"，与 Claude Code / Codex 同形）。同一个 tool 名出现在两个 server 上会各自带命名空间共存；**同一个 serverName 被两行用**⇒后者加载失败——所以"同一个工具同时存在于两处"在这条链路上会以"名字空间被占"或"两套同名工具"的形式暴露。

**官方包在真机上确实装了**：`…/dsh/node_modules/@deepseek-ai/dsh-mcp-client/`（`lib/index.js` + `package.json` + 17 KB README）。所以 `mountedPluginPackages` 的链接机制能找到它。

### 1.3 另一条路：ACP `session/new` 的 `mcpServers`

`Agent/ResidentDSHTransport.swift:217` 已经在发 `params: ["cwd": cwd.path, "mcpServers": [String]()]`。ACP schema 里这个数组的元素是 `McpServer`：

- `McpServerStdio`：`{name, command, args, env}`（`required: [name, command, args, env]`，`env` 是 `[{name, value}]`），schema 原文 "All Agents MUST support this transport"；
- 另有 `http` / `sse` / `acp`（后两个需要 agent 先声明 `mcp_capabilities`）。

schema 文件：`…/node_modules/@agentclientprotocol/sdk/schema/schema.json`（`$defs.McpServer` / `McpServerStdio` / `NewSessionRequest`，`NewSessionRequest.required = [cwd, mcpServers]`）。

**没有选它**，理由两条：① 本仓的 DSH 入口是 `packages/examples/acp-demo/lib/bin.js` 那份 composition，不是 `dsh --profile acp`，而 `dsh` 自己的 lib/*.js 里**一处都没有** `mcpServers`/`mcpCapabilities`（`grep` 5 个 bundle 全 0 命中）——没有任何证据表明这个 ACP agent 会去连它；② ACP 那条路的 `env` 是 `[{name,value}]` 数组，塞进本仓的 composition 行语法反而要再造一套校验。composition 那条路是**同一份 YAML 上的一次纯加法**，校验器已经在那里。

### 1.4 本仓为什么必须扩校验器

`validateComposedConfig` 是"对自己发出的行语法的自证"，任何未请求的行 ⇒ fail closed（`compositionAllowedRows` + 行数断言）。所以新增 MCP 行必须同时扩它，否则要么挂不上、要么把白名单放宽成"随便什么行都行"。落地做法见 §5.2。

---

## 2. 现在 agent 能用的工具（逐个）

工具定义分两处产生，最终都汇成一份 schema JSON 交给 DSH 私有插件 `gmgn-host-tools.mjs`（`ResidentDSHHostToolsBridge.swift:255` 定义文件名；`AgentConversationService.swift:1422` 起 channel，`:1450` 把 `channel.pluginFileURL.path` 交给 composition）。

| # | 工具 | 声明处 | 入参要点 | 只读/动作 | 谁校验 |
|---|---|---|---|---|---|
| 1 | `inspect_world` | `WorldAgentToolContract.swift:45` | 无 | 只读 | Swift |
| 2 | `list_places` | `:50` | 无 | 只读 | Swift |
| 3 | `list_available_activities` | `:55` | 无 | 只读 | Swift |
| 4 | `plan_route` | `:60` | 目标 | 只读 | Swift |
| 5 | `move_to` | `:72` | 目的地 | 动作 | Swift |
| 6 | `start_activity` | `:84` | activity / 目标 | 动作 | Swift |
| 7 | `stop_activity` | `:96` | — | 动作 | Swift |
| 8 | `look_at` | `:107` | 目标 | 动作 | Swift |
| 9 | `set_world_weather` | `:119` | weather | 动作 | Swift |
| 10 | `move_live_camera` | `:132` | 相机 | 动作 | Swift |
| 11 | `complete_world_goal` | `:144` | goal | 动作 | Swift |
| 12 | `read_resident_state` | `ResidentLoopTools.swift:27` | 无 | 只读 | Swift（读 `resident_states`） |
| 13 | `update_resident_intent` | `:32` | intent | 动作 | Swift |
| 14 | `read_owned_props` | `ResidentPropToolBridge.swift:53` | 无 | 只读 | Swift 读世界，世界由 **Rust** 存 |
| 15 | `list_placement_surfaces` | `:53` | 无 | 只读 | Swift 几何 |
| 16 | `preview_prop_placement` | `:53` | object_id/surface_id/x/y/z/yaw | 只读（只验证） | Swift 几何 |
| 17 | `apply_prop_placement` | `:53` | 同上 + `layout_revision` | 动作 | Swift 几何 → **Rust `world_commit`** |
| 18 | `withdraw_prop` | `:53` | object_id + layout_revision | 动作 | 同上 |
| 19 | `undo_prop_placement` | `:53` | layout_revision | 动作 | 同上 |
| 20 | `hold_prop` | `:53`（`slot` 见 `:66-70`） | object_id, **slot ∈ {rightHand, back, waist}**（可省＝rightHand）, layout_revision | 动作 | Swift 挂点语义 → Rust 落盘 |
| 21 | `adjust_held_prop_grip` | `:53` | object_id, offset_x/y/z, rotation_yaw, layout_revision | 动作 | Swift |
| 22 | `return_held_prop` | `:53` | object_id, layout_revision | 动作 | Swift |
| 23 | `enable_prop_capability` | `:53` | object_id, capability（当前仅 `coffee.brew`） | 动作 | Swift |
| 24 | `submit_wish_generation` | `ResidentWishMachineTools.swift:50` | `attachment_id`, `name`, `size_intent{axis,meters,source}` **或** `height_meters`, `pending_id`, `destination` | 动作 | 尺寸 → **Rust**（`size_intent` 语义在 `model.rs`） |
| 25 | `read_wish_generation` | `:50` | `wish_id`（可省） | 只读 | Swift |
| 26 | `read_wish_machine_contract` | `:50` = `WishMachineContract.swift:55` | 空 | 只读 | Swift（契约本体） |
| 27 | `retry_wish_generation` | `:50` | wish_id | 动作 | Swift → Rust `retry` |
| 28 | `cancel_wish_generation` | `:50` | wish_id | 动作 | Swift → Rust `cancel` |
| 29 | `claim_wish_output` | `:50` | wish_id | 动作 | Swift |
| 30 | `resume_wish_continuation` | `:50` | wish_id, confirm_resume | 动作 | Swift |
| 31 | `search_wish_reference_images` | `ResidentWishReferenceTools.swift:195` | query | 只读 | Swift（网络） |
| 32 | `register_wish_reference_image` | `:204` | 图片 | 动作 | Swift |
| 33 | `capture_space_photo` | `ResidentVisionTools.swift:24` | 无 | 只读 | Swift（全舞台相机） |
| 34–38 | `read_radio_state`, `read_current_track`, `list_music_playlists`, `read_music_playlist`, `prepare_music_track` | `ResidentMusicToolBridge.swift:9-11` | 见各自 schema | 3 只读 / 2 动作 | Swift |
| — | `memory_read` / `memory_query` / `memory_recall` | 经 `ResidentMemoryClient.swift:158,171,195` 走 **Rust** | scope/query/topK | 只读 | **Rust**（`memory_status` 恒 `pendingTurns:0`） |
| 39 | `capture_space_photo` 之外的 `ResidentVisionToolbox.toolNames` | `:25` | — | — | — |

**已经在 Rust 侧校验的**（其余一律只在 Swift）：

- `size_intent` 的形状/轴/出处/米数：`services/gmgn-taskd/src/model.rs:83-92`（`SizeIntent::validate` → `invalid_size_intent`），`axis=height` 与 `heightMeters` 的一致性：`model.rs:412-419` → `size_intent_conflict`；回执回显一致：`model.rs:499-503` → `size_intent_echo_conflict`。
- `submit` 的其它字段（名字/出处/endpoint/PNG）：`model.rs:383-430`。
- `world_*` 全部入参：`world.rs`（`invalid_world_id` / `invalid_domain` / `invalid_op` / `invalid_op_count` / `revision_conflict` / `request_id_conflict` / `world_id_mismatch` …）。
- `memory_*` 全部入参：`memory.rs`。
- 世界几何（碰撞/通道/承托面）**不在 Rust**：那是 Swift `ResidentPropPlacementError` 的判定；Rust 只存 `op` 携带的 `object` 值（`world.rs:1219` 起），`metadata` 里的保留键是 `gmgn.generated-prop.v1` / `gmgn.support-surface.v1`（`world.rs:91,93`），字段语义由 Swift 写、Rust 原样保存。

**"信息不足"的既有词汇**（`WishMachineContract.swift:65-67,83-91`）：code `insufficient_input`，needs `size_axis` / `size_meters`，回执键 `question` / `pending_id`，且 `Code.needsInput` 的注释明写**是成功通道（`isError: false`）**，其余是错误。宿主桥把 `isError` 翻成协议级错误（`ResidentDSHHostToolsBridge.swift` 的 refusal/`isError` 路径），所以"信息不足"必须走成功通道——否则模型看到的是一次故障，而不是一个要问用户的问题。

---

## 3. Rust 侧现状

- **进程与锁**：`gmgn-taskd`，私根 `/Users/<u>/Library/Application Support/gmgn radio/TaskService`，socket 必须在该私根内（`main.rs:60-68`），目录 0700、socket 与文件 0600（`main.rs:86-87`，`umask(0o077)` 在 `main.rs:40`）。**独占锁**：`main.rs:69-70` `fs2::FileExt::try_lock_exclusive(&lock)` 锁 `<root>/taskd.lock`，失败即 `already_running`。真机实测：`/tmp/gmgn-live/` 下 `t.sock`（`srw-------`）、`taskd.lock`、`tasks.sqlite3` 三个文件。
- **帧**：每行一个 JSON 对象，收发上限均 12 MiB（`model.rs:10` `FRAME_LIMIT`），**请求 `id` 必须是 1–200 字节的字符串**（`daemon.rs:561-567`），否则 `{"id":null,"error":{"code":"invalid_request_id"}}`。错误信封：`json!({"id":id,"error":{"code":code,"message":code}})`（`daemon.rs:968`，`message` 与 `code` 同值）。
- **方法清单**（`daemon.rs` dispatch）：`configure`(79) `snapshot`(95) `submit`(108) `cancel`/`retry`(114) `failover`(123) `providers_status`(141) `provider_probe`(166) `state_read`(235) `state_commit`(251) `world_snapshot`(280) `world_commit`(287) `world_import`(306) `world_facts_read`(325) `world_records`(335) `world_cursors`(345) `world_blob_put`(355) `world_blob_get`(365) `event_read`(372) `message_read`(386) `message_ack`(405) `memory_status`(421) `memory_read`(429) `memory_query`(437) `memory_turn`/`memory_pending`/`memory_ingest`(453 → 专门错误码 `memory_original_text_layer_removed`) `memory_recall`(456) 其余 `unknown_method`(472)。
- **`resident.rs` 那批表**：`resident_states` / `resident_requests` / `resident_events` / `resident_message_acks` 通过 `state_read`/`state_commit`/`event_read`/`message_read`/`message_ack` **已经是权威**（`resident::read_state` / `resident::commit` / `read_events` / `read_messages` / `ack`；schema 见 `resident.rs`）。幂等由 `resident_requests`（`request_id_conflict` / `replayed`）与 `world_records` 的 `revision` 共同承担。
- **事件推送**：`state_commit` / `world_commit` / `world_import` 在同一事务后 `s.changed.send_modify(...)`（`daemon.rs:275,301,320`）唤醒订阅者；`world_facts` 按 `seq` 增量读，`world_cursors` 记录每个消费者推进到哪（消费者名单已含 **`mcp`**：`world.rs:88`）。
- **世界数据的形状**：`world_records` 两个域 `worlds` / `objects`（`world.rs:64,66`），世界键 `state`（`world.rs:68`）；`world_snapshot` 返回 `{record:{recordRevision,boundarySeq,stateSha256,objects[],state}}`（`world.rs:572-609`）；`world_commit` 的 `op` 词表恰好五个：`replaceState` / `upsertObject` / `deleteObject` / `setWorldFacts` / `advanceCursor`（`world.rs:1122-1280`，现在也导出为 `world::OPS`）。

---

## 4. 能复用多少

**直接就是 MCP 工具的天然后端**（无需新 Rust 语义，只差一层协议翻译）：

| MCP 工具 | taskd 方法 | 为什么能直接用 |
|---|---|---|
| `gmgn_capability_contract` | `capability_contract`（**本次新增，只读**） | 由权威按自己的常量生成，见 §5.1 |
| `gmgn_world_read` | `world_snapshot` | 权威快照，含 `stateSha256`，物件/位置/手持/挂点/是否摆放都在 `state` 里 |
| `gmgn_world_records_read` | `world_records` | 记录表原样 |
| `gmgn_world_facts_read` | `world_facts_read` | 按 `seq` 增量 |
| `gmgn_world_cursors_read` | `world_cursors` | 消费者进度 |
| `gmgn_prop_jobs_read` | `snapshot` | 任务账本 |
| `gmgn_prop_submit` | `submit` | **`size_intent` 校验已在 Rust**（零改动即继承 `invalid_size_intent` / `size_intent_conflict`） |
| `gmgn_prop_cancel` / `gmgn_prop_retry` | `cancel` / `retry` | 幂等键复用 |
| `gmgn_world_commit` | `world_commit` | `requestID` 幂等 + `expectedRevision` CAS + `ops` 词表全在 Rust 校验 |

**暂时不能搬到 Rust 的**（这就是"按可行性取舍"的取舍本身）：

- **`apply_prop_placement` / `withdraw_prop` / `hold_prop`(slot) / `adjust_held_prop_grip` / `return_held_prop` 这类"带语义的动作"**：它们的语义（承托面几何、碰撞、通道、挂点骨骼相对偏移、最长边可持上限）今天**只在 Swift**（`ResidentPropToolBridge.swift`、`ResidentPropPlacementError`、`PropAttachmentSlots`）。Rust 存的是 `object` 的**不透明值**。要在 Rust 侧提供同名工具，就必须把这份 schema 与几何判定一起搬到 Rust —— 那是一次独立的迁移，**不是**加一个 MCP server 能顺带完成的。硬在 `gmgn-mcpd` 里造一个"place_prop"只会产生第二份位置/挂点真相，正是本次要消灭的形状。所以本切片只提供**通用动作通道** `gmgn_world_commit`（`op` 词表由权威校验），并在工具描述里写明"摆放/移动/改尺寸/手持换挂点都是通过这里的物件操作表达的"。
- **`submit_wish_generation` 的 MCP 入参**：设计 §6.6 明确"不定义，交由许愿机那条线定义后再对齐错误码"。本切片提供的是**底层生成任务**工具 `gmgn_prop_submit`（`jobID` / `endpoint` / `name` / `pngBase64` / `source` / `heightMeters` / `sizeIntent`），不碰许愿机的授权与草稿账本。
- `event_read` / `message_read` / `message_ack`：通道纪律上属于**事件通道（推送）**，MCP 是**命令通道（按需）**。本次没有把它们做成工具；`gmgn_world_facts_read` 已经能回答"刚才发生了什么"（按 seq 增量）。把它们做成工具会把推送语义塞进拉取面，破坏"只读资源与动作工具分开"。
- `world_blob_put` / `world_blob_get`：仅 12 MiB 帧内的 base64 大对象，MCP over stdio 的面不适合搬运二进制；留待需要时再定。

---

## 5. 落了什么

### 5.1 `services/gmgn-taskd`：一个只读方法 `capability_contract`

- `src/contract.rs`（新）：`describe()` 无参数、不读不写任何状态，把**权威自己的常量**摊成契约：`model::FRAME_LIMIT`、`model::SIZE_INTENT_MIN_METERS/MAX_METERS`、`world::{CONSUMERS, OPS, DEFAULT_READ_LIMIT, MAX_READ_LIMIT, MAX_OPERATIONS, MAX_FACTS, FACT_PAYLOAD_LIMIT, WORLD_RECORD_LIMIT, OBJECT_RECORD_LIMIT, WORLD_DOMAIN, OBJECT_DOMAIN, WORLD_KEY}`、保留 metadata 键，以及**全部 160 个错误码**。
- `src/daemon.rs`：新增 dispatch 分支 `"capability_contract" => Ok(contract::describe())`，放在 `world_snapshot` 之前，注释写明"无参数、不读不写、不需要授权"。
- `src/world.rs`：新增 `pub const OPS: [&str; 5]`（与 `apply` 的 match 同名并列出）。
- **错误码表不是手写的**：`contract.rs` 的测试 `the_published_codes_are_exactly_the_authoritys_own` 从 `include_str!` 进来的 12 份源码里按行规则重新导出（行内出现 `Err(` / `ok_or` / `map_err` / `bounded(` / `identity(` / `glb_container(` / `object_text(` / `fail(` / `error(` / `failure(` / `code:` / `code =` 之一，且该行里的字面量是"小写 snake_case、含 `_`、≥6 字符"），并**双向断言相等**；`every_published_code_appears_in_the_sources` 再钉一条"发布的码必须在源码里真的存在"。这两个测试是"注入编造字段/漏掉一个码 ⇒ FAIL"的执行体。
  - 这个测试是**真机跑出来的**：第一次对真 `gmgn-taskd` 发 `world_commit` 时返回了 `world_id_mismatch`，而当时手写的表里没有它 —— 现在它在了。

### 5.2 `apps/macos/.../ResidentDSHConfiguration.swift`：把 MCP server 当一行挂上（默认关闭）

局部 edit，全部是加法：

- `ResidentDSHMCPServer`（新结构）：`command` / `socketPath` / `grantPath?`，`isWellFormed` 要求绝对路径且不含 `'` / `,` / 换行，`argumentsText` 生成 `[--socket, <sock>(, --grant, <grant>)?]` 的行内列表原文。
- `residentYAML(…, mcpServer: ResidentDSHMCPServer? = nil)`：非 nil 时追加
  ```yaml
  - id: gmgn-mcp
    name: '@deepseek-ai/dsh-mcp-client'
    config:
      serverName: gmgn
      transport: stdio
      command: '<abs>/gmgn-mcpd'
      args: [--socket, <abs sock>, --grant, <abs grant>]
  ```
- `makeResidentSandbox(…, mcpServer: … = nil)`：畸形请求＝没请求；校验后**只为请求了 MCP 的 composition**把 `@deepseek-ai/dsh-mcp-client` 链进沙箱（`optionalMountedPackages` + `optionalPackagePaths`，checkout 路径 `packages/mcp/mcp-client`）。
- `validateComposedConfig(_:hostToolsPluginPath:mcpServer:)`：`gmgn-mcp` 行只在请求时允许；`name` 必须精确等于官方包名，`config` 恰好四个键，`serverName`＝`gmgn`、`transport`＝`stdio` 且都不带引号，`command` 带引号且**逐字等于调用方给的路径**，`args` 不带引号且**逐字等于由这些事实重新生成的文本**；行数断言加上这一行。未请求而出现该行 ⇒ **拒绝**。
- `declaresImageInput` / `privateMCPServer(in:)`：发送时的读回只认"这段代码自己可能发出的那一行"（二进制必须以 `/gmgn-mcpd` 结尾、参数表必须能往返），否则不解锁图片判据。
- **默认关闭的实际含义**：`mcpServer` 默认 nil，`mcpServer:` 不传时发射字节、链接的包集合、行数断言与改动前逐位相同 —— 既有 189 条 `test-resident-image-transport` 判据原样通过。

### 5.3 `services/gmgn-mcpd`（新 crate）：MCP stdio server

- 依赖 `rmcp 3.5.0`（官方 SDK，`server` + `macros` + `transport-io`）、`serde` / `serde_json`（`float_roundtrip`，与权威同一条口径）、`tokio`。**不依赖 `rusqlite` / `sqlite-vec` / `fs2` / `libc`，也没有任何网络栈**（`tests/no_direct_authority.rs` 断言）。
- `src/taskd.rs`：UDS 上的 NDJSON 客户端，帧上限 12 MiB，**`id` 是字符串**，跳过来自订阅通道的 `event` / `message` 帧，权威错误码**原样**承载。
- `src/catalog.rs`：**工具定义的唯一来源**（10 个工具：6 只读 + 4 动作），`tools/list`、契约里的 `mcp.tools`、dispatch 都读它。
- `src/grant.rs`：动作工具的授权，**继承**私有 host-tools 的 grant 文档形状（`state == "armed"` + `tools[].name`），并且 grant 里的 `socketPath` 必须与本次服务的 socket 一致（否则 `mcp_grant_socket_mismatch`）；没有 grant ⇒ `mcp_grant_not_configured`。只读工具从不看它。
- `src/server.rs`：`ServerHandler`（`get_info` / `list_tools` / `call_tool`）。**只读工具与动作工具分开**；`gmgn_prop_submit` 在"一个尺寸都没给"时走**成功通道**的结构化 `insufficient_input`（`isError: false` + `ok: false` + `needs` + `question` + `pending_id`），其中 `pending_id` 就是权威的幂等键，所以"回填它再提交"是**真的**续同一次委托，不需要本进程存任何草稿；权威错误码一律原样透传（`invalid_size_intent` 不会变成别的词）。
- `src/main.rs`：`--socket <abs>`（必填）、`--grant <abs>`（可选）、`--server-name`（默认 `gmgn`）、`--list-tools`（打印本 build 的工具目录，用来回答"定义在哪一处"）。**不开任何端口**，只有 stdio。
- 一次真实的 stdio 会话往返见 §7。

### 5.4 新增/改动清单

| 文件 | 动作 |
|---|---|
| `Cargo.toml`（仓库根） | 新增：`[workspace] members = ["services/gmgn-taskd", "services/gmgn-mcpd"]` + `[profile.release] strip/lto`（成员自己的 `[profile]` 会被工作区忽略，所以发布轮廓必须搬到根清单，取值与 `gmgn-taskd` 原来逐字相同） |
| `Cargo.lock`（仓库根） | 新增：由 `services/gmgn-taskd/Cargo.lock` 原样复制后由 cargo 追加 `rmcp`/`rmcp-macros`/`schemars` 等新条目，**没有改动任何已有条目的版本**。`services/gmgn-taskd/Cargo.lock` 留在原处（未删除），工作区模式下不再被读取 |
| `services/gmgn-taskd/src/{contract.rs,daemon.rs,world.rs,main.rs}` | 新文件 + 3 处局部 edit |
| `services/gmgn-mcpd/{Cargo.toml,src/*,tests/*}` | 新 crate（4 个源文件 + 2 个集成测试） |
| `apps/macos/Sources/GMGNRadio/Agent/ResidentDSHConfiguration.swift` | 局部 edit（§5.2），基准 `git show HEAD:<file>` |
| `tools/test-resident-dsh-mcp-mount.swift` | 新 harness（39 条判据） |
| `Makefile` | `_test-harnesses` 里加一行跑上面那个 harness（单行、可整行摘掉） |
| `docs/plans/evidence/2026-10-02-rust-mcp-recon.md` | 本文 |

`git status --short` 在开工时**是空的**，HEAD = `6168747`。

---

## 6. 切换时 Swift 侧必须删掉什么

**只有在把 agent 的工具面真正切到 MCP 之后**才删；在那之前两边都活着是**故意的**（本切片默认关闭）。

MCP 工具名一律带 `gmgn_` 前缀，DSH 又加一层 `mcp__gmgn__`；Swift 侧现在**没有任何**工具名带这个前缀（见 §2 全表），所以两套词汇**不可能撞名**——"同一个工具同时存在于两处"在命名上已被排除，并被 `catalog.rs` 的 `every_mcp_tool_name_is_namespaced_away_from_the_swift_tool_face` 钉住（往 catalog 里粘一个 Swift 名字 ⇒ FAIL）。

按"Rust 已经有权威后端"排序，切换时可以删掉的 Swift **声明**（不是删文件，是删那一批工具的 schema/描述与 dispatch 分支）：

| Swift 工具 | 声明处 | 对应的 MCP 工具 |
|---|---|---|
| `submit_wish_generation`（**尺寸那一半**） | `ResidentWishMachineTools.swift:50`、schema `:59-75` | `gmgn_prop_submit`（`size_intent` 语义本来就是 Rust 的） |
| `retry_wish_generation` / `cancel_wish_generation` | `ResidentWishMachineTools.swift:50` | `gmgn_prop_retry` / `gmgn_prop_cancel` |
| `read_wish_machine_contract`（**尺寸/范围/错误码那几段**） | `WishMachineContract.swift:55`、`:160-196` | `gmgn_capability_contract`（数字改为权威生成，不再由 Swift 各存一份） |
| `read_owned_props` / `list_placement_surfaces`（**只读那一半**） | `ResidentPropToolBridge.swift:53` | `gmgn_world_read` / `gmgn_world_records_read` |
| `apply_prop_placement` / `withdraw_prop` / `undo_prop_placement` / `hold_prop` / `adjust_held_prop_grip` / `return_held_prop` / `preview_prop_placement`（**落盘那一半**） | `ResidentPropToolBridge.swift:53` | `gmgn_world_commit`（几何/挂点判定**留在 Swift**；切完这一半之后，`layout_revision` 的语义要改成 `expectedRevision`） |

**切换时必须同时做的两件事**：

1. **删掉上表的 Swift 声明**，并跑一条"同一工具不得同时存在于两处"的断言：MCP 侧已有 `catalog.rs::every_mcp_tool_name_is_namespaced_away_from_the_swift_tool_face`（前缀隔离 + 双下划线禁止）。切完后还要**再加一条**：从 `ResidentWorldToolSession.allowedToolNames ∪ additionalTools.keys`（`ResidentWorldToolSession.swift:30-49`）与 MCP `tools/list` 求交集，交集非空 ⇒ FAIL。这条属于 agent 工具入口那条线（设计 §6.6 划给许愿机 MCP/skill 化），**本次没有落**，见 §8。
2. **把默认关闭改成按轮开关**：`makeResidentSandbox(mcpServer:)` 与 `ResidentDSHConfiguration` 的调用点（`AgentConversationService.swift:1439-1458`）要在**同一轮**里同时决定"挂不挂 MCP 行"和"写不写 grant"。`gmgn-mcpd` 的 `--grant` 就是那份 grant 的路径；`grantPath` 缺失时它只提供只读。

---

## 7. 真实 JSON-RPC 往返（真 `gmgn-taskd` + 真 `gmgn-mcpd`）

环境：`./target/debug/gmgn-taskd --root /tmp/gmgn-live --socket /tmp/gmgn-live/t.sock --concurrency 2`，然后 `./target/debug/gmgn-mcpd --socket /tmp/gmgn-live/t.sock --grant /tmp/gmgn-live/grant.json`（grant `state=armed`，白名单 `gmgn_world_commit` / `gmgn_prop_submit` / `gmgn_prop_cancel`）。

完整往返（原文，含请求与响应两侧）保存在 `docs/plans/evidence/2026-10-02-rust-mcp-transcript.txt`。关键几步：

```
--> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"transcript","version":"1"}}}
<-- {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"gmgn-mcpd","version":"0.1.0"},"instructions":"…"}}

--> {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
<-- {"jsonrpc":"2.0","id":2,"result":{"tools":[ … 10 个，6 只读 + 4 动作，annotations.readOnlyHint 与 kind 同源 … ]}}

--> {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"gmgn_capability_contract","arguments":{}}}
<-- {"jsonrpc":"2.0","id":3,"result":{"isError":false,"structuredContent":{"ok":true,"authority":"gmgn-taskd",
     "contract":{"authority":"gmgn-taskd","ipc":{"frame_limit_bytes":12582912,"id_limit_bytes":200,…},
       "size_intent":{"axes":["longest","height"],"sources":["user","suggested","default"],"min_meters":0.01,
         "max_meters":3.0,"applies":["normalize","echo"],…},
       "world":{"domains":["worlds","objects"],"consumers":["world","ui","agent","cloud","mcp"],
         "ops":[{"op":"replaceState","requires":["state"]},…5 个…],"max_operations":512,…},
       "error_codes":[{"code":"invalid_size_intent","reason":"…"},…160 个…]},
     "mcp":{"server":"gmgn","transport":"stdio","naming":"tools appear to the client as mcp__gmgn__<tool>",…}}}}

--> {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"gmgn_world_commit","arguments":{"worldID":"living-cabin","requestID":"transcript-1","expectedRevision":0,"producer":"gmgn-mcpd-transcript","intent":{"why":"transcript: create the world record"},"ops":[{"op":"replaceState","state":{"worldID":"living-cabin","revision":1,"room":"cabin"}}]}}}
<-- {"jsonrpc":"2.0","id":5,"result":{"isError":false,"structuredContent":{"ok":true,"authority":"gmgn-taskd","method":"world_commit",
     "result":{"revision":1,"seq":1,"replayed":false,"changedWorldKeys":["revision","room","worldID"],
       "stateSha256":"449df4d9daabf08bf234abaffcc6ac9eb1eba8477c853b63f880519069c7a4e0",…}}}}

--> {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"gmgn_world_read","arguments":{"worldID":"living-cabin"}}}
<-- {"jsonrpc":"2.0","id":6,"result":{"isError":false,"structuredContent":{"ok":true,"method":"world_snapshot",
     "result":{"record":{"recordRevision":1,"boundarySeq":1,
       "state":{"objectStates":{},"revision":1,"room":"cabin","worldID":"living-cabin"},
       "stateSha256":"449df4d9daabf08bf234abaffcc6ac9eb1eba8477c853b63f880519069c7a4e0",…}}}}}
       ↑ 与上一步 world_commit 回执的 stateSha256 逐位相同：读到的就是权威刚落盘的那份

--> {"jsonrpc":"2.0","id":7,"method":"tools/call", …同一个 requestID 原样重放…}
<-- …"replayed":true, "stateSha256":"449df4d9…"（幂等：第二次不产生新事实）

--> …id 71：expectedRevision=1 的 setWorldFacts… <-- ok:true, revision:2, changedWorldKeys:["weather"]
--> …id 72：expectedRevision=0（陈旧）…        <-- isError:true, code:"revision_conflict"
--> …id 73：worldID 与世界文档里的不同…        <-- isError:true, code:"world_id_mismatch"

--> {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"gmgn_prop_submit","arguments":{"jobID":"1111…","endpoint":"https://generator.test","name":"白色长剑","pngBase64":"aGk=","source":{…}}}}
<-- {"jsonrpc":"2.0","id":8,"result":{"isError":false,"structuredContent":{"ok":false,"authority":"gmgn-taskd",
     "code":"insufficient_input","status":"insufficient_input","needs":["size_axis","size_meters"],
     "question":"这件东西要做多大？…","pending_id":"1111…",
     "size_intent":{"axes":["longest","height"],"min_meters":0.01,"max_meters":3.0,…}}}}
     ↑ isError:false —— 信息不足走的是**成功通道**；尺寸范围也是从权威读来的，不是本进程写死的

--> …id 9：gmgn_prop_cancel {"id":"not-a-uuid"}  <-- isError:true, code:"invalid_id"（权威的码，原样）
--> …id 10：gmgn_does_not_exist                    <-- isError:true, code:"unknown_tool"

=== gmgn-mcpd exit code: 0 ===
=== 11. gmgn-mcpd 已经退出；权威毫发无损 ===
taskd still serving: {"id":"probe","result":{"authority":"gmgn-taskd",…}}
world survived the MCP process: {"recordRevision":2,"stateSha256":"23eae966…","state":{"objectStates":{},"revision":1,"room":"cabin","weather":"clear","worldID":"living-cabin"}}
mcpd processes alive: 0
```

---

## 8. 断言与注入 FAIL

| 断言 | 执行体 | 注入什么会 FAIL |
|---|---|---|
| 工具定义只有一处 | `catalog.rs::every_mcp_tool_name_is_namespaced_away_from_the_swift_tool_face`、`the_contract_block_lists_exactly_the_dispatched_tools`、`tests/mcp_stdio.rs::tools_list_matches_the_shipped_catalog` | 往 catalog 里粘一个 Swift 名字（无 `gmgn_` 前缀）⇒ FAIL；`tools/list` 与 `--list-tools` 不一致 ⇒ FAIL |
| 只读契约读得到、且与权威一致 | `contract.rs::the_published_codes_are_exactly_the_authoritys_own`（双向）、`every_published_code_appears_in_the_sources`、`capability_contract_matches_the_authority`；`tests/mcp_stdio.rs::…refuses_honestly`（canary 逐字节比对，`world_snapshot` 的入参必须与调用方给的一字不差） | 契约里少一个权威会返回的码 / 多一个不存在的码 / 数字与常量不一致 / MCP 面自己重写一遍快照 ⇒ FAIL |
| 信息不足走成功通道 | `tests/mcp_stdio.rs::a_real_session_lists_reads_and_refuses_honestly` 第 4、4b 步（`isError == false` + `ok == false` + `code == "insufficient_input"`） | 改成 `isError: true` ⇒ FAIL。**为什么宿主桥不允许**：私有 host-tools 桥把 `isError` 翻成协议级错误（`ResidentDSHHostToolsBridge.swift` 的 refusal/`isError` 路径），模型看到的会是一次"工具坏了"，而不是"这句话要问用户"；`WishMachineContract.Code` 的注释也把这条写死了（`insufficient_input` 是成功通道，其余是错误） |
| MCP 进程被杀不影响权威 | `tests/no_direct_authority.rs`（4 条：源码里出现 `rusqlite`/`sqlite3`/`store::Database`/`taskd.lock`/`try_lock_exclusive`/`fs2::`/私根路径 ⇒ FAIL；清单里出现存储栈或任何网络栈 ⇒ FAIL；本 crate 里出现 `TcpListener`/`UnixListener` ⇒ FAIL；两个进程必须在同一个工作区但是不同 crate） | 让 MCP 直接写库（加 `rusqlite` 或打开 `<root>/tasks.sqlite3`）⇒ FAIL |

另外 `make test-harnesses` 里的 `tools/test-resident-dsh-mcp-mount.swift`（39 条）是 composition 那一半的注入判据：换二进制/换 socket/换 grant 文件/丢或加 `--grant`/改 `serverName`/换 `transport`/命令不带引号/多一个 config 键（含从外面放宽 `toolCallTimeoutMs`）/`name` 指向别的包/删掉 config/追加第二行/相对路径/含逗号或引号的路径 —— 全部 FAIL；以及"没请求 MCP 时不得链接 `dsh-mcp-client`"和"请求了而安装里没有该包 ⇒ fail closed"。

---

## 9. 需要真机确认什么

1. **`@deepseek-ai/dsh-mcp-client` 在真机安装里存在**（本机 `dsh 0.1.5-rc.2` 的 `node_modules/@deepseek-ai/dsh-mcp-client` 有，版本 `0.1.5-rc.3`）。`linkMountedPackages` 在缺失时**整个沙箱构建失败**（`dshSecurityPatchUnavailable`），这是有意的 fail-closed，但真机上必须确认它不会把**基线**沙箱一起打死 —— 基线不链接它（已由 harness 第 33-35 条钉住）。
2. **`gmgn-mcpd` 二进制必须进 app bundle 的 `Contents/Helpers/`**（与 `gmgn-taskd` 同目录）。现在 `tools/build-taskd-helper.sh` 只构建/安装 `gmgn-taskd`。在把它加进构建阶段之前，`mcpServer.command` 只能指向一个**开发用绝对路径**，正式挂载不可用。这一步本次**没有做**（要改 Xcode 构建阶段，超出"最小 edit"）。
3. **ACP 那条 `mcpServers` 是否被这个 entry 真的消费**：本机 grep 无命中，但如果真机上 DSH 换了 entry（`GMGN_DSH_ACP_ENTRY`），composition 那条路依然有效，ACP 那条仍需实测。
4. **grant 文档的写入时机**：`GMGN_MCP_GRANT` 对应的文件是 `ResidentDSHHostToolsChannel` 写的那份 `gmgn-host-tools.grant.json`（`ResidentDSHHostToolsBridge.swift:660` `writeGrantLocked`）。MCP 面读的是**同一份**，所以"arm/revoke 与 tool 白名单"天然同源；真机要确认的是"同一条路径被两条消费者同时读"没有竞态（读是原子的 `read_to_string`，最坏读到旧的一份，方向安全）。
5. **`gmgn_world_commit` 作为摆放通道的可用性**：现在 agent 拿到的 `op` 词表是权威校验的原始形状，但"承托面/碰撞/挂点"的判定还在 Swift。真机上要让 agent 真能"摆"，要么让它用 `apply_prop_placement`（Swift，现状），要么把那份几何搬到 Rust（独立迁移）。
