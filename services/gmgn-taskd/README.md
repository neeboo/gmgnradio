# gmgn-taskd

Rust 后台承接许愿任务、世界状态和音乐存储。客户端统一通过鉴权本机 HTTP 访问；不提供 Unix socket 或裸 TCP JSON 业务入口。SQLite 只由后台单写入线程管理。进程重启后恢复已知远端任务，无回执的不确定提交等待用户显式重试；生成凭据按完整 origin 保存在进程内存。

## 构建与离线验证

```sh
cargo build --locked --release --manifest-path services/gmgn-taskd/Cargo.toml
cargo test --locked --manifest-path services/gmgn-taskd/Cargo.toml
cargo clippy --locked --manifest-path services/gmgn-taskd/Cargo.toml --all-targets -- -D warnings
TASKD_BIN="$PWD/target/release/gmgn-taskd" python3 services/gmgn-taskd/tests/process.py -v
TASKD_BIN="$PWD/target/release/gmgn-taskd" python3 services/gmgn-taskd/tests/http_transport_process.py -v
TASKD_BIN="$PWD/target/release/gmgn-taskd" python3 services/gmgn-taskd/tests/music_storage_process.py -v
```

进程回归仅创建自己的临时目录、Rust 子进程和 loopback 假 HTTP 服务；不启动 macOS 宿主，不访问钥匙串或生产生成服务。`TASKD_BIN` 可指向独立构建目录内的可执行文件。

## 启动

```text
gmgn-taskd --root <absolute-private-directory> --endpoint-file <absolute-descriptor-path> --concurrency 2 [--legacy-root <absolute-PropGeneration-directory>]
```

默认 root 为 `~/Library/Application Support/gmgn radio/TaskService`，端点描述文件必须位于该私有根目录。后台仅监听 `127.0.0.1` 随机端口，描述文件为 `{version:2,address,token}`。目录为 0700，描述文件和 SQLite 文件为 0600；独占进程锁保护根目录。默认任务并发为 2，可配置 1—32，不改变远端 GPU 的资源策略。

所有路由需要 `Authorization: Bearer <token>`，拒绝浏览器 Origin，不开放 CORS。`GET /health` 返回 `{version:2,transport:"http"}`；`POST /rpc` 接收 `{id,method,params}`，返回 `{id,result}` 或 `{id,error}`；`POST /events` 以 SSE 返回订阅确认与后续事件。普通请求/回复限制为 12 MiB，SSE 有界发送。语音开始通过 `/events` 建立流，追加音频、提交和取消通过 `/rpc`，使用相同随机 `X-GMGN-Client-ID`；断流取消所属语音会话。客户端拒绝旧协议、代理和 HTTP 重定向，无旧传输回退。

节目与歌单使用同一个 `tasks.sqlite3`：schema v5 新增音乐表，`music_program_save/list` 保存节目和 pending 草案，`music_library_read/commit` 以 revision 检查并发更新，`music_import` 按来源幂等迁入旧数据且不覆盖已有同 ID 记录。Unity 和原生端共用后端；旧音乐 JSON 文件仅作为只读迁移源保留。迁移及读取合同见 [HTTP 与音乐存储](../../docs/plans/2026-10-07-taskd-http-music-storage.md)。

SQLite 由专属存储线程单写。任务变更、事件和具有明确 scope 的 `task.stateChanged` 消息在同一事务提交后通知订阅者。慢订阅者从数据库继续按序读取，不依赖内存广播保存内容。world、ui、agent 独立确认消息，重连时重新投递该消费者未确认的消息。

同一数据库同时承载 world/resident 作用域的持久状态、事件流与消息（`state_read`、`state_commit`、`event_read`、`message_read`、`message_ack`），由显式 `schema_migrations` 版本表升级：v1 旧库幂等保留，v2 新增 resident 表，v3（memory-storage-v1）新增记忆快照/向量表。JSON 合同与错误码见 [resident 存储合同](../../docs/plans/2026-09-08-resident-storage-contract.md)。resident 进程级回归：`TASKD_BIN="$PWD/services/gmgn-taskd/target/debug/gmgn-taskd" python3 tools/test-resident-state-daemon.py -v`。

VoiceMem 选择性移植的长期记忆层留在 Rust daemon 内：`memory_status/read/query` 与本地 `memory_recall` 的协议、快照与幂等账本（`memory_snapshots`/`memory_requests`/`memory_vec_rows`）、sqlite-vec 静态链接都保留，出处与许可证见 `VoiceMem-NOTICE.md`；合同见 [VoiceMem Rust 记忆合同](../../docs/plans/2026-09-08-voicemem-rust-contract.md)。**外部 VoiceMem 服务层已整体拆除**：daemon 不再向任何 compaction/embedding endpoint 发 HTTP，也不再持有 endpoint/token/model 配置，只服务外部 provider 的两个 IPC 方法（配置 provider、语义压缩提交）已整体从 dispatch 删除（调用得到 `unknown_method`），后台压缩编排与断连取消管线一并移除。为后续在 Rust 内自行实现语义抽取，快照与向量代次账本的结构、三张表与 sqlite-vec 注册都原样保留，但不再写入向量。

**长期记忆：保留但不在计划内**（2026-10-01，用户明确决定「长期记忆不要搞」）。`memory_snapshots` / `memory_requests` / `memory_vec_rows` 三张表**留着不动**（删表收益低于风险：老库里可能已有账本行，且结构本身是历史记录），但**长期记忆已由用户决定不做**：

- `memory_compact`（冻结合同 §3.7）**不会接线**；`memory.rs` 里现已 dead 的快照提交与幂等账本（`commit` / `recorded_replay` / `CompactCommit`）**不接**，只在模块头写明理由。
- 界面上**不再**出现任何「长期记忆暂不可用 / 等压缩接上后自动恢复」之类的提示——既然不做，就不该宣传一个不会有的能力。
- 判据：`swift tools/test-no-long-term-memory-capability.swift`（把能力类型或面向用户的文案注入回来 ⇒ **FAIL**）。
- **不影响对话连续性**：驻留 agent 的**会话内连续性来自 DSH 自己的 session**（以及 Claude 那条路的内存历史），**不来自**这套记忆库。所以"不做长期记忆"不需要为了对话再补任何东西。
- **存储范围**：空间状态（世界、物件、资产引用）持久化到本地 Rust 权威；2026-10-07 用户另行授权节目和歌单共用该 SQLite。长期记忆、消息投递迁移、云端同步仍不在计划内。

**原文层（volatile pending turns）也已整体移除**（2026-10-01）：`memory_turn` / `memory_pending` / `memory_ingest` 三个方法连同 `Buffer`/`VolatileTurn`/`clear_covered` 与三个上限常量一起删除，调用它们得到专门的 **`memory_original_text_layer_removed`**（不是含糊的 `unknown_method`——老客户端仍会调用，而"回合原文没能进记忆"必须说得出口；也**不是**接受后丢弃，静默成功正是要消灭的形状）。移除依据：真机 `pendingTurns` 恒为 0、三张记忆表 0 行、`memory_compact` 从未有 dispatch 分支，原文层唯一的生产用途（`freshSession` 恢复段）在 pending=0 时**恒为空转**，保留死代码 + 死合同本身就是负担。**压缩层不受影响**：`memory_snapshots`/`memory_requests` 与 `memory::commit` 原样保留。`memory_recall` 的 `pendingTurns` 保留在返回里但**恒为 0**（只为不改客户端解码契约，值已无来源）。进程级回归：`TASKD_BIN="$PWD/services/gmgn-taskd/target/debug/gmgn-taskd" python3 services/gmgn-taskd/tests/local_memory_process.py -v`（无任何 provider fixture：三个原文方法的**可见失败** + "原文绝不落盘"的逐字节搜索 + scope 隔离 + read 的显式 null + query/recall 的如实「语义检索不可用」应答）。注意：`tools/test-resident-state-daemon.py` 中的 v1 升级断言仍写死版本 2，v3 迁移后需改为 3（tools 归 Swift/tools owner，待其更新）。

## 本地记忆行为（provider 与原文层移除后）

- `memory_recall`：请求形状不变（`freshSession`、`factLimit` 1–12、`noteLimit` 1–8），但语义检索那一侧已随 embedding provider 删除：`facts`/`notes` 恒为空数组、`status` 恒为 `unconfigured`，**不做关键词/时间序兜底**（词法巧合不是语义证据）。`freshSession=true` 时 context 只带**已确认的压缩快照**（有个标记的 `新会话恢复` 段，≤8000 Unicode 字符），并明确声明「语义记忆检索当前不可用」；notes 始终带「禁止照读/不据此认定人格」标记。**不再有"未入库缓冲"那一段**（那是原文层的产物）。
- `memory_turn` / `memory_pending` / `memory_ingest`：**已移除**，恒返回 `memory_original_text_layer_removed`。
- `memory_query`：协议与参数校验保留，但没有查询向量可用，恒返回 `status:"unconfigured"` + 空 `results`。
- 不再有后台自动整理、`memory_status.orchestration` 或 provider 配置状态；`memory_status` 只报 `{memory, pendingTurns}`，其中 `pendingTurns` 恒为 0。

## IPC

完整 JSON 合同见 [Rust 后台合同](../../docs/plans/2026-09-07-rust-taskd-contract.md)。每行一个 JSON 对象，收发帧上限均为 12 MiB；请求 `id` 为 1—200 UTF-8 字节字符串，回复带原 `id`，事件和业务消息分别带 `event`、`message`。同一连接可交错请求和订阅，也可为每个订阅使用独立连接。

`snapshot` 每页不超过 2 MiB。若返回 `nextCursor`，继续发送 `snapshot` 的 `{cursor:nextCursor}` 参数；游标是不透明字符串，可跨连接使用。所有页来自首帧 `sequence` 的同一持久历史边界。客户端取齐后投影，再从该 sequence 重放事件。

远端返回只允许同 origin 的固定任务路径。禁重定向、代理环境和自动 HTTP 重试；请求超时 60 秒，状态响应上限 1 MiB，PNG 上限 8 MiB/2048²，模型流式上限 32 MiB。PNG 完整解码，GLB 核验 magic/version/声明长度及远端 bytes/SHA256。返回的 inspection 必须符合 Swift 解码合同。发布路径均由后台生成，并拒绝符号链接素材。

`ready` 仅表示模型已经校验并落盘；场景真实渲染、领取与摆放仍由应用确认。取消先持久化，远端完成后取消过晚会保留 `cancelRequested` 并报告 `interrupted/cancellation_too_late`，不会伪称已取消。模型下载过程中收到取消时不发布模型。

旧 `PropGeneration/tasks.json` 只读导入，素材复制到新私有目录；保留原 UUID、幂等键和有效回执。已有远端 ID 继续查询，无回执记录不会自动重发。源文件损坏时启动失败并保留原文件，成功迁移按源根目录幂等记录。

## 生成后端抽象与回退（第一步，仅守护进程）

生成 provider 收敛为一个 trait：`src/provider.rs` 的 `PropProvider`（`capabilities` / `probe` / `submit` / `status` / `cancel` / `fetch_model`）。现有远程实现是唯一实现 `RemoteHTTPProvider`，每个方法都直接复用 trait 化之前的 `request`/`download` 代码；线上字节与错误分类由 `tests/fixtures/remote_http.json`（trait 化之前录制的请求字节 + 回执）逐字段锁定。

`/health` 允许出现**可选**的 `provider` 块（`id`/`kind`/`ready`/`reason`/`stages`/`max_input_px`/`est_seconds`/`uploads_data`/`quota`）。整块缺失或字段缺失 ⇒ 与今天一致的默认能力（不因为缺字段拒绝既有 DGX 服务）；出现时按字段判定 readiness 与输入边长上限。只有显式调用 `provider_probe` 才会读 `/health`，任务路径不因此多一次请求。

新增方法（旧方法语义不变）：

- `providers_status`：无参数，只读且不联网。返回 `{provider:<capabilities>, endpoints:[{endpoint,configured,jobs,activeJobs}]}`，不含任何 token。
- `provider_probe {endpoint, inputPx?}`：对该 origin 发 `GET /health`（只有已 `configure` 的 origin 才带 Bearer），返回 `{endpoint, ready, acceptsInputPx, capabilities}`。不是 `api_ready` 的 health 返回 `provider_not_ready`。
- `failover {id, endpoint, generationProfile?}`：为同一件产物换后端重开任务。旧的先取消；旧任务仍活跃（远端可能还在跑）时返回 `source_task_still_active`，已就绪返回 `artifact_already_ready`。
- `submit` 新增可选字段 `sourceWishID` 与 `generationProfile {resolution,decimation,textureSize,remesh}`；`job` 新增可选字段 `sourceWishID` 与 `workflowProfile`（双方都缺省时与今天序列化完全一致）。

两条不变量：

- 一个 `sourceWishID` 最多一个活跃 job（活跃 = `backendStage` 不属于 `ready`/`cancelled`/`failed`/`interrupted`），第二笔写入返回 `duplicate_active_source_wish`。
- `workflowProfile` 是决定网格轮廓、因而决定碰撞盒的参数指纹 `gmgn-mesh-v1;resolution=<n>;decimation=<n>;texture_size=<n>;remesh=<bool>`。回退重试必须沿用同一指纹，否则返回 `fallback_profile_mismatch_would_change_collision_box`；两端都没有指纹时返回 `missing_workflow_profile`。


依赖 API 核对参考：[Tokio watch](https://docs.rs/tokio/latest/tokio/sync/watch/)、[reqwest ClientBuilder](https://docs.rs/reqwest/0.12.28/reqwest/struct.ClientBuilder.html)、[rusqlite Connection](https://docs.rs/rusqlite/0.32.1/rusqlite/struct.Connection.html)、[PNG Decoder](https://docs.rs/png/0.17.16/png/struct.Decoder.html)。
