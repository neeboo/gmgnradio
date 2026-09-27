# VoiceMem Rust 记忆快照 IPC 合同（Rust 后台 ↔ Swift 接线，冻结）

冻结日期：2026-09-08。本文件是「VoiceMem 选择性 Rust 移植」新增记忆方法的唯一合同来源
（additive IPC），与 `docs/plans/2026-09-07-rust-taskd-contract.md`、
`docs/plans/2026-09-08-resident-storage-contract.md`、`docs/plans/2026-09-08-voicemem-rust-port.md`
并行使用。实现范围只在 `services/gmgn-taskd/**`；Swift 接线由后续 DSH 任务按本文件执行。
本文件不修改既有 `configure / snapshot / submit / cancel / retry / publish_message /
ack_message / state_read / state_commit / event_read / message_read / message_ack` 的任何
请求/回复形状、行为或错误码。

## 0. 设计定位与边界

- 复用同一 `gmgn-taskd` 进程、同一 `tasks.sqlite3`、同一专属存储线程单写。不新开进程、
  不建第二数据库、不新增 writer、不加 GPU 推理/向量服务。
- 替换「未完成的 durable raw-transcript 路径」：daemon **不落库任何会话原文**。
  会话原文只以**易失 pending turns** 存在于 daemon 进程内存（scope 键控），
  崩溃即丢（见 §2.4）。
- 长期记忆是每个 `(worldID, residentScope)` **一版带版本号的记忆快照**，分为
  **事实/偏好**（facts/preferences）与**有依据的关系/经验笔记**（notes）两段；
  快照文本与其派生向量在**同一事务**内原子提交。
- 语义压缩（compaction）与向量嵌入（embedding）走**显式配置的 provider**（远端推理）；
  缺失配置必须显式呈现 unavailable，不得把词法哈希/截断冒充语义向量，不得伪造成功。
- VoiceMem 参考提交 `a450911fc8cbb44c46d810aace2f3288bad287e4`；本移植只取
  SessionBuffer「commit-after-durability」与有界事实/关系整合语义（出处与偏差见 §9）。

## 1. scope 与通用约束

scope 统一内嵌对象，与 resident 合同相同：

```json
"scope": { "worldID": "marble-living-cabin", "residentScope": "resident-…" }
```

- `worldID` / `residentScope`：非空、≤200 字节、无首尾空白、无控制字符；两个维度都参与隔离。
- 沿用一行一 JSON 的 Unix socket 帧；请求 `id` 为 1—200 UTF-8 字节字符串；收发帧上限 12 MiB。
- 请求/回复沿用 camelCase；新方法顶层 params **deny_unknown_fields**（拼错字段即
  `invalid_memory_<op>` 类错误，绝不静默丢字段）。
- 凭据卫生：与既有 `publish_message / state_commit` 一致，任何新方法入参若包含任一已配置
  origin 的 token（递归检查），整体拒绝（`invalid_memory_<op>`），不落盘、不进日志。
- 冻结常量（§2/§3 通篇复用）：

| 常量 | 值 | 说明 |
| --- | --- | --- |
| `PENDING_TURNS_LIMIT` | 200 | 每 scope 易失 pending 缓冲上限，超出丢最旧（FIFO） |
| `TURN_TEXT_LIMIT` | 2000 字符 | 单条 user/agent turn 文本上限 |
| `QUERY_TEXT_LIMIT` | 500 字符 | `memory_query` 查询文本上限 |
| `TOP_K_MAX` | 20（默认 8） | 向量检索返回上限（每次 `memory_query`） |
| `FACTS_LIMIT` | 200 | 快照 facts 段条数上限 |
| `NOTES_LIMIT` | 80 | 快照 notes 段条数上限 |
| `ENTRY_TEXT_LIMIT` | 400 字符 | 单条事实/笔记文本上限 |
| `OBSERVED_AT_LIMIT` | 32 字符 | `observedAt`（建议 `YYYY-MM-DD` 或 ISO 日期）上限 |
| `GROUNDING_LIMIT` | 200 字符 | `grounding` 上限 |
| `EMBEDDING_DIM_LIMIT` | 8192 | 维度上限，且 >0 |
| `SNAPSHOT_LIMIT` | 1 MiB | 单版快照序列化上限（读回复/入 prompt 前检查） |

## 2. 数据模型

### 2.1 快照（durable，每 scope 一版）

```json
{
  "schemaVersion": 1,
  "revision": 3,                 // 成功提交计数，同 resident 合同 §2.2 语义
  "vectorGeneration": 3,         // 单调自增；快照与向量同代，绝不混用旧代
  "processedWatermark": 12,      // 已入快照的最高 turn watermark
  "nextWatermark": 15,           // 下一个 memory_turn 将拿到的 watermark
  "embedding": { "model": "…", "dimensions": 384 },
  "sections": {
    "facts": [ { "id": "<uuid>", "category": "fact|preference",
                 "text": "…", "observedAt": "…", "grounding": "turn:7" } ],
    "notes": [ { "id": "<uuid>", "category": "relationship|experience",
                 "text": "…", "observedAt": "…", "grounding": "turn:7" } ]
  }
}
```

- `schemaVersion` 恒为 1（本冻结版本）；将来加列/加段时递增并冻结新版本。
- `facts` 段：关于居民/世界的**原子长期事实与偏好**（对应 VoiceMem 左脑 additive facts）。
  category ∈ `fact | preference`。`grounding` 可选（缺省省略该字段）。
- `notes` 段：**有依据的关系/经验/沟通笔记**（对应 VoiceMem 右脑 heartnotes / relationship /
  response-experience）。category ∈ `relationship | experience`。**grounding 必填**，必须能
  追溯到被观察的 utterance（如 `turn:<watermark>`）或事件；无依据的笔记由校验拒绝。
- 条目 `id`：UUID 形态规范化为小写连字符；跨版本稳定，供 CC 引用与校正/删除。
- 快照不保存：宿主 prompt、隐藏工具结果、图片字节、凭据、未送达/被打断的回复（见 §7）。
- 单版内条目数受 `FACTS_LIMIT / NOTES_LIMIT`、条目文本受 `ENTRY_TEXT_LIMIT` 约束；
  provider 输出超限 → 压缩失败（见 §2.5），旧快照原样保留。

### 2.2 双段语义（移植边界，冻结）

- 事实段只收录**长期成立**的内容；一次性请求（求推荐、求问答、当下指令）不是记忆。
- notes 段是**画像/关系/经验类内部笔记**，只给回复语气与话题选择参考，**禁止对用户照读**；
  不得把**单次情绪的即时状态**提升为稳定人格/特质（VoiceMem 明确要求区分）。
- 校正与删除由下一次压缩显式表达（`removed` + 新条目替换，见 §5 provider 输出）；本移植是
  快照式整合而非 VoiceMem 的纯 additive 追加流（偏差记录见 §9）。

### 2.3 pending turns（易失）

- 每个 scope 一条易失 pending 缓冲（daemon 进程内存，`PENDING_TURNS_LIMIT` 有界 FIFO）。
- 缓冲是压缩输入、也是「本会话尚未进入长期记忆的上下文」；CC 可读取以拼回复上下文，
  取完不自动清空——**只有压缩成功落库后**才清空（§2.4）。
- turn：`{ turnID, watermark, role: user|agent, text, interrupted }`；watermark 每 scope
  单调递增（≥ `nextWatermark`）。只接受真实用户文字与**已成功送达**的 agent 回复；
  打断/未播放/未送达的回复不入缓冲（由 CC 侧保证，daemon 无法自证来源，见 §7）。

### 2.4 commit-after-durability（冻结，移植自 VoiceMem SessionBuffer）

- turn 保持 pending、可被检索/渲染，直到一次 `memory_compact` **在持久事务里提交了新快照**。
- 提交成功后该 scope 缓冲内 `watermark ≤ processedWatermark` 的 turns 全部清空；
  watermark > processedWatermark 的 turns 保留，留待下次压缩。
- 压缩失败（provider 错、输出校验失败、embedding 不可用、CAS 冲突）→ **快照与向量都不变**，
  旧快照保留、pending 不清空，CC 可重试。
- 崩溃语义：daemon 重启后易失 pending 缓冲丢失（未压缩原文不恢复）；已提交快照与
  `processedWatermark / nextWatermark` 持久不变。不产生半截事实。
- 防串写：turn 追加按 append 时的 scope 入各自缓冲；压缩启动时快照该 scope 的缓冲快照，
  提交是单 scope、单事务、CAS 化的写；取消/断连/scope 变化后的迟到完成不能写进别的 scope，
  也不能在别人已提交后覆盖（见 `memory_conflict`）。

### 2.5 原子快照/向量一致性（冻结）

- 每次成功 `memory_compact` 使 `vectorGeneration +1`；新快照文本与新代向量在**同一事务**
  内写入/重建。任何失败整事务回滚 → 库中永不出现「新快照 + 旧向量」或「旧快照 + 新向量」。
- 查询只查**当前 `vectorGeneration`** 的本 scope 向量分区；旧代向量在提交时被替换，不可能被
  当作当前记忆返回。
- sqlite-vec 静态链接（pinned `sqlite-vec = "=0.1.9"`，MIT/Apache-2.0，已做静态注册探针）。
  每个 scope 使用独立 vec0 分区（表名由 scope 哈希派生）：KNN 只在**本 scope** 行内排序，
  从结构上保证「先 scope 过滤、后 top-k」；不得用单库全局 top-k 再过滤。
- 距离度量冻结为 cosine（建表 `distance_metric=cosine`），返回 `distance` 升序。

## 3. IPC 方法（冻结 JSON）

以下七个方法名不与既有方法冲突；成功后 `{"id":…,"result":…}`，失败
`{"id":…,"error":{"code":…,"message":…}}`。错误码见 §6。

### 3.1 `memory_configure`

配置压缩/嵌入 provider（daemon 内存保存，永不落盘；重启后需重配）。

```
params  { "kind": "compaction" | "embedding",
          "endpoint": "<origin>", "token": "…",
          "model": "…" (可选, ≤200 字节) }
result  { "configured": true }
```

- `endpoint` 校验复用 `configure` 的 origin 规则（仅 HTTPS 或 loopback HTTP；无路径/用户/
  密码/query/fragment；禁重定向）。
- `token` 约束同 `configure`（1—8192、可打印 ASCII）。**不得**出现在命令行、日志、数据库。
- embedding `model` 为配置提示；真实 model/维度以 provider 首次响应为准并写入快照；后续批次
  model+维度必须与库内记录一致，否则 `embedding_dimension_mismatch`（见 §4.2）。

### 3.2 `memory_status`

```
params  { "scope": {…} }
result  { "configured": { "compaction": bool, "embedding": bool },
          "memory": null | {
            "schemaVersion": 1, "revision": n, "vectorGeneration": n,
            "processedWatermark": n, "nextWatermark": n,
            "embedding": { "model": "…", "dimensions": n },
            "entryCounts": { "facts": n, "notes": n } },
          "pendingTurns": n }
```

- 只读、无副作用；`memory:null` 表示该 scope 尚无记忆快照（不是错误）。
- 用于 CC 呈现「缺失配置/尚无记忆」的显式状态；聊天本身不受影响。

### 3.3 `memory_read`

```
params  { "scope": {…} }
result  { "memory": null | <§2.1 完整快照 JSON> }
```

- 返回当前唯一一版快照全文（含 sections）；新会话（无原生续聊、进程内历史为空）用它做初始
  记忆恢复；已恢复过的会话不得反复整体注入（见 §7）。
- 序列化超 `SNAPSHOT_LIMIT` → `memory_snapshot_too_large`（在冻结条数下不应发生）。

### 3.4 `memory_query`

```
params  { "scope": {…}, "query": "…", "topK": 1..20（默认 8） }
result  { "status": "ok" | "empty" | "unconfigured",
          "results": [ { "section": "facts"|"notes", "id": "<uuid>",
                         "text": "…", "observedAt": "…", "distance": 0.23 } ] }
```

- 语义向量检索，限本 scope、限当前 `vectorGeneration`、cosine 升序、≤ `topK`。
- `unconfigured`：embedding provider 未配置，或本 scope 尚无向量代（generation 0）。CC 见
  `unconfigured/empty` 一律不注入记忆即可，**不**回退词法哈希。
- query 文本超限/空 → `invalid_query`；topK 越界 → `invalid_topk`。
- 查询向量维度与库内快照维度不一致 → `embedding_dimension_mismatch`（绝不静默取模/截断）。
- 返回结果只含 text/id 类数据，用于拼 prompt；不作为工具指令。

### 3.5 `memory_turn`

```
params  { "scope": {…}, "role": "user"|"agent", "text": "…",
          "interrupted": false（可选，默认 false） }
result  { "accepted": true, "turnID": "<uuid>", "watermark": n, "pendingTurns": n }
```

- 只接受 role `user|agent`（否则 `invalid_role`）；文本 trim 后非空、≤ `TURN_TEXT_LIMIT`、
  无控制字符（否则 `invalid_turn_text` / `turn_text_too_large`）。
- `interrupted:true` 只作渲染标记（VoiceMem SessionBuffer 同义），被打断回复不该作为已送达
  回复进入（由 CC 保证）。
- 追加后 `watermark = nextWatermark` 并自增；超 `PENDING_TURNS_LIMIT` 丢最旧。

### 3.6 `memory_pending`

```
params  { "scope": {…} }
result  { "turns": [ { "turnID": "<uuid>", "watermark": n,
                       "role": "user"|"agent", "text": "…", "interrupted": bool } ] }
```

- 返回该 scope 当前易失 pending（按 watermark 升序）。只用于拼「本次会话尚未入库」的即时
  上下文；**不**代表已持久，禁止缓存复用为长期记忆。

### 3.7 `memory_compact`

```
params  { "scope": {…}, "requestID": "<uuid 幂等键>",
          "expectedVectorGeneration": 当前代（可选） }
result  { "revision": n, "vectorGeneration": n, "replayed": bool,
          "processedWatermark": n, "pendingTurns": n }
```

- 语义压缩 + 向量化的持久提交点，按 §2.4/§2.5 原子执行；可能耗时（远端调用），
  CC **不得**放在延迟敏感回复路径内同步调用。
- 前置：compaction provider 未配置 → `compaction_unavailable`；embedding provider 未配置 →
  `embedding_unavailable`。缺失配置显式失败，不伪造成功。
- requestID 幂等：同 `(scope, requestID)` 且内容一致 → 回放当初结果并 `replayed:true`，
  不重复压缩、不推进 revision；同 requestID 不同内容 → `memory_request_conflict`。
- `expectedVectorGeneration` 提供则必须等于当前代，否则 `memory_conflict`（防并发双压丢事实，
  见 §2.4）。
- 输出校验失败（形状/超限/坏类别/notes 缺 grounding）→ `compaction_rejected`，旧快照保留、
  pending 保留。provider/网络错 → `memory_compact_failed`（内部可含远端分类）。
- 成功后：revision+1、vectorGeneration+1、pending 中 `≤ processedWatermark` 的 turns 清空。

## 4. Provider（压缩与嵌入；配置走 §3.1）

### 4.1 compaction provider

- 语义压缩是**真实 provider 调用**，不是拼接/截断。daemon 把上一版快照（若有）+ 当前 pending
  turns 组成上下文发出，并附压缩/类别/防幻觉规则 prompt。
- provider 输出（frozen envelope）必须是 JSON object：

```json
{ "facts":  [ { "category": "fact|preference", "text": "…",
                "observedAt": "…", "grounding": "…" } ],
  "notes":  [ { "category": "relationship|experience", "text": "…",
                "observedAt": "…", "grounding": "…" } ],
  "removed": [ "<上一版 entryID>", "…" ] }
```

- daemon 确定性校验（不靠模型自觉）：两段均为数组、逐条字段类型/长度/类别白名单、notes
  grounding 非空、id 由 daemon 统一生成、`removed` 必须引用上一版存在的 id 且不出现在新数组、
  facts≤`FACTS_LIMIT`、notes≤`NOTES_LIMIT`。任一违反 → `compaction_rejected`。
- `removed` + 新条目替换即校正/删除机制；旧版仍按原样保留在被替换前的版本号里（可读性要求
  下可重新压缩，但不提供历史版本读接口，见 §10 开放点）。
- 压缩上下文中**永不**包含宿主 prompt、工具结果、图片字节、凭据、模型内部输出。

### 4.2 embedding provider

- 独立能力：把事实/笔记文本与查询文本映射为向量。provider 不可用时检索路径显式
  `unconfigured`/错误，与压缩能力无关。
- 输出须含稠密 float 向量；`NaN/Inf/0 维/超限维` → `invalid_vector`；每次提交与查询的
  model+维度必须与库内记录一致，否则 `embedding_dimension_mismatch`。
- 绝不把自定义哈希当语义向量、不静默用哈希兜底。

## 5. 存储与迁移（实现归属，冻结语义）

- 同一 `tasks.sqlite3`；`schema_migrations` 新增 **v3 `memory-storage-v1`**：记忆元数据/
  快照行 + scope 派生 vec0 分区 + rowid↔条目映射 + requestID 幂等表。每步 DDL 与版本行同事务；
  失败整步回滚，旧库保持可用。
- 快照（单 scope 单行 JSON）与向量代在同一事务写入/替换；daemon 重启后快照、watermark 计数、
  向量分区全部按库恢复；vec0 表数据即库文件内容（重启持久）。
- 迁移只做加法；不触碰 `jobs/events/messages/resident_*` 既有表与既有行。

## 6. 错误码一览（稳定，新增部分）

| code | 含义 |
| --- | --- |
| `invalid_scope` | scope 越界（复用 resident 语义） |
| `invalid_memory_status` / `invalid_memory_read` / `invalid_memory_query` / `invalid_memory_turn` / `invalid_memory_pending` / `invalid_memory_compact` / `invalid_memory_configure` | 请求 JSON 形状错误或含已配置凭据 |
| `invalid_kind` / `invalid_token` / `invalid_endpoint` | `memory_configure` 参数非法 |
| `invalid_role` | `memory_turn.role` 非 user/agent |
| `invalid_turn_text` / `turn_text_too_large` | turn 文本非法/超 `TURN_TEXT_LIMIT` |
| `invalid_query` / `invalid_topk` | 查询空/超限；topK 越界 |
| `memory_snapshot_too_large` | 快照超 1 MiB（不应发生） |
| `compaction_unavailable` / `embedding_unavailable` | 对应 provider 未配置（显式 unavailable） |
| `compaction_rejected` / `embedding_rejected` | provider 输出未通过确定性校验 |
| `memory_compact_failed` | 压缩提交前失败（provider/网络/存储） |
| `invalid_vector` / `embedding_dimension_mismatch` | 向量非法/维度不一致 |
| `memory_conflict` | `expectedVectorGeneration` ≠ 当前代（并发/陈旧） |
| `memory_request_conflict` | 同 requestID 不同内容 |
| `memory_storage_failed` / `memory_history_unavailable` | 存储层故障 / 已存数据损坏 |

## 7. 接线约束（CC/DSH Swift 侧必须遵守）

1. 只向 `memory_turn` 提供**真实用户文字**与**已成功送达的回复文本**；绝不提供宿主 prompt、
   隐藏工具结果、图片字节、未播放/被打断语音、凭据或组装上下文。
2. `memory_compact` 放后台；**不能**阻塞回复首字。压缩失败用 §6 错误或 `memory_status`
   呈现，聊天不中断。
3. `memory_read` 只在**真正新会话**（无原生续聊、进程内历史为空）恢复快照；原生续聊/内存
   历史存在时不得重复注入历史。
4. `memory_pending` 用于拼接本次会话尚未入库的即时上下文；不得缓存为长期记忆。
5. `memory_query` 有界：每次回复只取 ≤ `topK` 且拼入的上下文遵守应用已有长度预算。

## 8. 验收测试（Rust 侧 Task 2，离线 fixture）

cargo test + 临时库进程回归覆盖：非法输入矩阵与 scope 隔离；stale revision/CAS 与
same-requestID 回放（先于一切）；快照双段验证、`FACTS_LIMIT/NOTES_LIMIT/ENTRY_TEXT_LIMIT`
有界、fact vs note 分离、日期/名字/数字精确保留（fixture）、校正与删除（`removed`）、
单次情绪不晋升为 traits（fixture）、压缩失败旧快照保留；commit-after-durability（成功提交前
pending 不清、提交后清、崩溃丢易失、不串 scope）；sqlite-vec 静态注册、insert/query、cosine
排序、**先 scope 过滤后 top-k**、零/NaN/维度/model 不一致拒绝、update/delete 与重启持久
（临时库）；provider 路径：loopback fixture HTTP 真实 reqwest 调用 compaction/embedding，
缺失配置返回显式 unavailable，绝无词法哈希冒充。

## 9. VoiceMem 出处与移植偏差（冻结记录）

- 参考提交：`xzf-thu/VoiceMem` @ `a450911fc8cbb44c46d810aace2f3288bad287e4`（Apache-2.0）。
- 移植语义出处（真实源码路径，仅语义参考非逐行复制）：
  - `web/session_context.py` — `SessionBuffer`：turn 在持久记忆确认前保持可用、确认后才移除
    （commit-after-durability）、打断标记与逐 session/space 隔离。
  - `voicemem/leftbrain/extract_facts_openai.py` — additive 事实抽取与垃圾过滤：一次性请求/
    助手自述不抽、属性冲突场景（`attribute`）为校正保留接口。
  - `voicemem/leftbrain/memory_repository.py` / `memory_repository_v2.py` — 有界事实整合与
    `update_memory` 校正。
  - `voicemem/orchestrator.py`（`Ingest`/`_finish_ingest`）与 `voicemem/rightbrain/brain.py`
    `RightBrain.write`、`experience_repository.py` — 右脑（画像/关系/经验）写入与情绪归因；
    `merged_extraction.py` — 明确「单次情绪不是人格」、一次性请求不抽。
- 选择性偏差：文本双段（facts/preferences 与 notes）单快照替代左脑 mem0/Qdrant + 右脑图；
  快照式整段整合替代纯 additive 追加（用 `removed`+替换表达校正/删除）；无音频/声纹/场景/
  多说话人；无真实用户数据库、无模型下载；向量库 sqlite-vec 0.1.9 替代 Mem0+Qdrant。
- 许可证/声明：VoiceMem Apache-2.0 与 sqlite-vec MIT/Apache-2.0 通知随实现模块文档与
  `docs/plans/evidence/2026-09-08-voicemem-rust-core.md` 记录；派生语义不复制上游原文。

## 10. 开放点（不改动已冻结形状，需 CC/DSH Swift 确认）

1. notes 是否需要对回复 tone 的「禁止照读」标记字段（当前由 CC 用文本前缀区分，同 VoiceMem
   `build_memory_context`）。
2. 是否需要在 `memory_read` 之外提供历史版本只读接口（本冻结只有当前一版）。
3. `memory_query` 是否按 section 分权重（当前返回结果已含 section，排序统一 cosine）。
4. provider 输出 envelope 若需接入既有 wish 式远端（非 OpenAI-compatible），需单独同步。
