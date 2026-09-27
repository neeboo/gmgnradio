# World/Resident 持久存储合同（Rust 后台，与 CC 冻结）

冻结日期：2026-09-08。本文件是 `state_read / state_commit / event_read / message_read / message_ack`
五组新增 IPC 的唯一合同来源，与 CC 的 Swift 侧计划保持一致。实现范围只在
`services/gmgn-taskd/**`；Swift 接线与居民计划由 CC 负责。

同日（2026-09-08）主代理定稿两处此前开放的语义，正文已按定稿更新，CC 接线请以此为准：

- **revision 是成功提交的计数**（§2.2 规则 2）：每个新 requestID 且 CAS 成功的
  提交都使 revision +1，即便 value 未变、只有事件/消息新增；同 requestID 的完全
  重放保持该 requestID 当初的 revision。不再保留“value 未变则不推进 revision”
  的 content-only 语义。
- **分页即水位**（§2.3 / §2.4）：`event_read / message_read` 参数只有
  scope / after / limit（message 另加 consumer），没有 base64 不透明 cursor，
  也没有任何 cursor 兼容字段；`nextCursor` **恒返回非负整数**——本页有数据时等于
  本页最后一条 sequence，无数据时等于本次入参 after。这是实时事件轮询的水位，
  不是“是否还有下一页”的标志。

## 1. 设计定位与边界

- 复用现有 Rust 后台进程（`gmgn-taskd`）的**单写存储线程**与同一个
  `tasks.sqlite3`；不另开服务、不建第二数据库、不新增 writer。
- 保留 `jobs / events / messages / message_acks` 的既有完整合同不变
  （快照、订阅、wish 消息、`task.stateChanged` 等行为与错误码原样）。
- 新增的是 world/resident 作用域内的持久 state、事件流与消费者消息
  （inbox）：这些行**不要求 job 外键**，可脱离许愿任务独立存在。
- 事件、消息的**序号可全局单调**，但所有查询严格按 `scope` 过滤。
- 事件 v1 不做自动清理：重要事实不自动删除，删除/保留策略留待后续
  显式合同变更（见 §7 待办）。

## 2. 冻结的 JSON 合同

所有请求/回复沿用既有一行一 JSON 的 Unix socket 帧格式；请求
`id` 仍为 1—200 字节字符串，整帧仍受 12 MiB 上限。scope 是统一内嵌对象：

```json
"scope": { "worldID": "marble-living-cabin", "residentScope": "resident-…" }
```

- `worldID` / `residentScope`：非空、≤200 字节、无首尾空白、无控制字符。
- 数据行归属由 `(worldID, residentScope)` 精确确定；两个维度都参与隔离。

### 2.1 `state_read`

```
params  { scope, domain, key }
result  { "record": null }
    或  { "record": { "revision": 3, "value": { …JSON object… } } }
```

- `domain` 枚举：`resident | world | wish | inbox | conversation`。
- `key`：≤200 字节字符串（`"mood"`、`"placement/chair-1"` 均可）。
- 无记录返回 `record: null`，不是错误。

### 2.2 `state_commit`

```
params  {
  scope, domain, key,
  expectedRevision: 0|正整数,        // 0 = 创建；否则必须等于当前 revision
  requestID: 幂等键,
  value: { …JSON object… },          // ≤256 KiB 序列化
  events?:   [ { id, kind, payload: {…} } ],   // 可选
  messages?: [ { id, kind, payload: {…} } ]    // 可选
}
result  { "revision": 1, "replayed": false }
```

原子性：状态更新、附带事件、附带消息与幂等记录**在同一个事务**内提交；
任一步失败整体回滚（状态不变、事件/消息不入库、requestID 不留痕）。

语义规则（冻结）：

1. **CAS**：`expectedRevision` 必须等于该 key 当前 revision，否则
   `revision_conflict`。记录不存在时只有 `expectedRevision=0` 可创建。
2. **revision 语义（2026-09-08 定稿）**：revision 是**成功提交的计数**——
   每个新 requestID 且 CAS 成功的提交都使 revision +1，即便 value 与当前值
   JSON 语义相等、只是附带追加了事件/消息；同 requestID 的完全重放保持该
   requestID 当初记录的 revision 并返回 `replayed: true`。因此两个写入者即使
   观察到相同的 expectedRevision、写的 value 也相同，只要事件/消息事实不同，
   后提交者必然 `revision_conflict`——CAS 不会因为 value 相同而失效。旧
   expectedRevision（含对已存在 key 传 0）一律拒绝。
3. **requestID 幂等**：同一 `(scope, domain, key, requestID)` 且内容
   （value + events + messages，JSON 对象按键排序做规范化摘要）完全一致
   时**回放**：不重放事件/消息、不推进 revision，返回该 requestID 当初的
   revision 与 `replayed: true`。同 requestID 不同内容 → `request_id_conflict`。
   JSON 键顺序不影响内容相等；数组顺序属于内容。
4. **事件/消息 id 去重（scope 内唯一）**：同 `(scope, id)` 再次出现且
   kind+payload 相同 → 幂等跳过（不产生新序号）；内容不同 →
   `event_id_conflict` / `message_id_conflict`。不同 scope 可用相同 id
   携带不同内容。
5. 事件/消息 item 的 `id`：UUID 形态会规范化为小写连字符形式；其余
   不超过 200 字节的无控制字符串按原样接受（见 §6 待 CC 确认）。
   `kind` 为 ≤200 字节字符串；`payload` 必须是 JSON object、≤256 KiB。
6. 凭据卫生：与既有 `publish_message` 一致，`state_commit` 入参若包含
   任一已配置 origin 的 token，整体拒绝（`invalid_state_commit`），
   值/载荷不落盘。

### 2.3 `event_read`

```
params  { scope, after?: 非负整数序号, limit?: 1…500（默认 100） }
result  { "events": [ { "sequence": 12, "id": "…", "kind": "…", "payload": {…} } ],
          "nextCursor": 非负整数 }        // 恒返回
```

- 读取该 scope 的事件流：返回 `after`（默认 0）之后、按 sequence 升序、
  最多 `limit` 条的事件。
- **`nextCursor` 恒返回非负整数**：本页有数据时 = 本页最后一条的 `sequence`；
  无数据时 = 本次入参 `after`。它不是“是否还有下一页”的标志，而是**实时轮询
  水位**——客户端每次都把本地水位推进到 `nextCursor` 再发起下一次读取；整页
  取满后用 `nextCursor` 续读即可取尽余量，空页则水位原地不动。协议没有 base64
  不透明游标，也不接受 `cursor` 兼容字段（多余参数报 `invalid_event_read`）。
- 事件只追加、不删除、不重放：`after` 边界就是“已读到的最大 sequence”。
- `limit` 缺省 100；`<1` → `invalid_limit`；`>500` → `limit_exceeded`；
  `after < 0` → `invalid_cursor`。
- 序号是跨 scope 全局 AUTOINCREMENT，但 SQL 严格按 scope 过滤，
  不同 scope 各自单调连续可续读。

### 2.4 `message_read`

```
params  { scope, consumer: world|ui|agent, after?: 非负整数序号,
          limit?: 1…500（默认 100） }
result  { "messages": [ { "sequence": 7, "id": "…", "kind": "…", "payload": {…} } ],
          "nextCursor": 非负整数 }        // 恒返回
```

- 只返回该 scope 内、该 consumer **尚未 ACK** 的消息，按 sequence 升序。
- 一个消息对 `world / ui / agent` 三个消费者独立投递：一者 ACK 不影响
  其余两者；连接断开不丢消息，未 ACK 消息在重启后仍按序可得。
- `nextCursor` 水位语义与 `event_read` 完全相同：恒返回、有数据 = 本页最后
  一条 sequence、无数据 = 入参 `after`；续读只用 `after`，不接受 `cursor`
  参数。建议按序 ACK 已处理消息：`after` 推进会越过未读消息，乱序 ACK 可能
  使中间未 ACK 消息只能从头重读。

### 2.5 `message_ack`

```
params  { scope, consumer: world|ui|agent, id }
result  { "acknowledged": true }
```

- 只允许 ACK **同 scope 已存在**的消息：id 不在该 scope →
  `message_not_found`。重复 ACK 幂等。
- 消费成功之后才 ACK；ACK 失败只重试 ACK，不重执行业务动作。

## 3. 存储与迁移

同一 `tasks.sqlite3`，用显式版本表管理：

```sql
CREATE TABLE IF NOT EXISTS schema_migrations(
  version INTEGER PRIMARY KEY, name TEXT NOT NULL);
```

- **v1 `taskd-v1`**：原 jobs/events/migrations + messages/message_acks
  的幂等 DDL。旧库打开时记录 v1 不动任何行；新库按序建齐。
- **v2 `resident-storage-v1`**：`resident_states`、`resident_requests`、
  `resident_events`、`resident_messages`、`resident_message_acks`
  （各列与索引见 `src/resident.rs::schema`，含 `(scope, sequence)` 索引与
  consumer CHECK）。
- 每步 DDL 与版本行在同一事务；失败整步回滚，**旧库保持可用**，进程以
  `storage_unavailable` 家族错误拒绝启动并保留原库。

主要表要点：

- `resident_states` 主键 `(world_id, resident_scope, domain, key)`，
  存 `revision / value / updated_at_ms`。
- `resident_requests` 主键 `(…, request_id)`，存该次提交的 `revision` 与
  内容摘要 `hash`，支撑跨重启回放。
- `resident_events` / `resident_messages`：`sequence` 全局自增 +
  `UNIQUE(world_id, resident_scope, id)`。
- `resident_message_acks` 主键 `(world_id, resident_scope, sequence, consumer)`。

## 4. 错误码一览（稳定，`error.code` 原样回显）

| code | 含义 |
| --- | --- |
| `invalid_scope` / `invalid_domain` / `invalid_state_key` / `invalid_request_id` / `invalid_revision` | 参数越界或非法 |
| `invalid_state_value` / `state_value_too_large` | value 非对象 / 超 256 KiB |
| `invalid_event_id` / `invalid_event_kind` / `invalid_event_payload` / `event_payload_too_large` | 事件 item 非法 |
| `invalid_message_id` / `invalid_message_kind` / `invalid_message_payload` / `message_payload_too_large` | 消息 item 非法 |
| `revision_conflict` | expectedRevision ≠ 当前（0 不能覆盖已存在） |
| `request_id_conflict` | 同 requestID 不同内容 |
| `event_id_conflict` / `message_id_conflict` | scope 内同 id 不同内容 |
| `invalid_consumer` | consumer 非 `world/ui/agent` |
| `invalid_cursor` / `invalid_limit` / `limit_exceeded` | `after` < 0 → `invalid_cursor`；`limit` <1 或 >500 分别 → `invalid_limit` / `limit_exceeded` |
| `message_not_found` | ACK 的消息不在该 scope |
| `invalid_state_read` / `invalid_state_commit` / `invalid_event_read` / `invalid_message_read` / `invalid_message_ack` | 请求 JSON 形态错误或含已配置凭据 |
| `resident_storage_failed` / `resident_history_unavailable` | 存储层故障 / 已存 JSON 损坏（不应发生） |

## 5. 验收与回归

Rust 单元测试（`cargo test`）覆盖：v1 库迁移升级保留旧行与旧消息合同、
失败迁移回滚、CAS 创建/更新/陈旧拒绝、requestID 同内容回放同 revision、
异内容冲突、事件/消息 id 幂等与冲突、跨 scope 隔离、value 未变但新
requestID 仍推进 revision、**并发同 expected / 同 value / 异事实只有一个
成功（防 CAS 失效）**、分页 `nextCursor` 恒返回且空页等于入参 after、ACK
跨重开恢复、ACK scope 匹配、非法参数矩阵。

进程级回归 `tools/test-resident-state-daemon.py`（真实 helper 子进程 +
Unix socket + 跨重启）：对同一临时 root 启动/停止/再启动二进制，验证
五组方法（state_read / state_commit / event_read / message_read /
message_ack）与持久化、幂等跨重启、ACK 恢复、事务失败回滚、并发 CAS 只
一成功，以及预置 v1 旧库的升级兼容。

## 6. 需要 CC 确认/注意的开放点（不改动冻结的请求/回复形状）

此前开放的两项语义已由主代理定稿进正文，Swift 接线以正文为准，不再二选一：

- §2.2 规则 2：revision = 成功提交计数（每新 requestID 且 CAS 成功 +1，
  同 requestID 完全重放保持旧 revision），不是 value 内容版本。
- §2.3 / §2.4：`event_read / message_read` 只传 scope / after / limit
  （message 另加 consumer）；`nextCursor` 恒为非负整数水位，续读一律把
  `after` 设为上一次的 `nextCursor`；不接受 base64 令牌或 cursor 字段。

仍待 CC 确认：

1. **事件/消息 `kind` 是否要白名单**：v1 实现允许任意 ≤200 字节
   `kind` 字符串（不做枚举）。若 CC 需要与既有 wish 消息一致的强校验，
   请冻结枚举，本后台加 schema/校验变更。
2. **item `id` 是否接受非 UUID**：v1 接受任意 ≤200 字节无控制字符串；
   UUID 形态会规范化为小写连字符。若 CC 计划只用 UUID，可收窄。
3. **event/message payload 上限 256 KiB**：与 state value 同限；既有
   wish 消息仍是 64 KiB。如需区分请告知。
4. **无删除接口**：v1 事件/消息/请求表只增不改；需要清理策略时新增
   显式删除方法并重新同步合同。
5. **写频率**：禁止 30 Hz 逐帧写；居民关键事实由 Swift 侧 checkpoint
   汇聚后提交。

## 7. 待办

- [ ] CC：Swift `ResidentStorageClient`（或等价桥）接线五个方法 + after
      水位重连策略与进程缺失报错，不改合同形状。
- [ ] CC：确认 §6 开放点（kind 白名单、id 格式、payload 上限）。
- [ ] Rust（后续）：事件/消息保留与归档策略、可能的范围删除方法；
      先报告合同变更再实现。
- [ ] 两端联调：与既有 `subscribe / subscribe_messages` 的共存回归；
      快照流与 resident 流互不串扰的宿主级验证（离线后做）。
