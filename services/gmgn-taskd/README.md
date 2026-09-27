# gmgn-taskd

Rust 后台独立承接许愿任务。客户端连接断开后继续执行；进程重启后恢复已知远端任务，无回执的不确定提交等待用户显式重试。凭据只通过本机 socket 配置，按完整 origin 保存在进程内存。

## 构建与离线验证

```sh
cargo build --locked --release --manifest-path services/gmgn-taskd/Cargo.toml
cargo test --locked --manifest-path services/gmgn-taskd/Cargo.toml
cargo clippy --locked --manifest-path services/gmgn-taskd/Cargo.toml --all-targets -- -D warnings
TASKD_BIN="$PWD/services/gmgn-taskd/target/release/gmgn-taskd" python3 services/gmgn-taskd/tests/process.py -v
```

进程回归仅创建自己的临时目录、Rust 子进程和 loopback 假 HTTP 服务；不启动 macOS 宿主，不访问钥匙串或生产生成服务。`TASKD_BIN` 可指向独立构建目录内的可执行文件。

## 启动

```text
gmgn-taskd --root <absolute-private-directory> --socket <absolute-socket-path> --concurrency 2 [--legacy-root <absolute-PropGeneration-directory>]
```

默认 root 为 `~/Library/Application Support/gmgn radio/TaskService`，socket 必须位于该私有根目录；默认并发为 2，可配置 1—32。任务调度只限制提交、查询、取消和下载请求的并发，不改变远端 GPU 的资源策略。目录为 0700，文件与 socket 为 0600；独占进程锁保护根目录，第二实例不会移除正在使用的 socket。

SQLite 由专属存储线程单写。任务变更、事件和具有明确 scope 的 `task.stateChanged` 消息在同一事务提交后通知订阅者。慢订阅者从数据库继续按序读取，不依赖内存广播保存内容。world、ui、agent 独立确认消息，重连时重新投递该消费者未确认的消息。

同一数据库同时承载 world/resident 作用域的持久状态、事件流与消息（`state_read`、`state_commit`、`event_read`、`message_read`、`message_ack`），由显式 `schema_migrations` 版本表升级：v1 旧库幂等保留，v2 新增 resident 表，v3（memory-storage-v1）新增记忆快照/向量表。JSON 合同与错误码见 [resident 存储合同](../../docs/plans/2026-09-08-resident-storage-contract.md)。resident 进程级回归：`TASKD_BIN="$PWD/services/gmgn-taskd/target/debug/gmgn-taskd" python3 tools/test-resident-state-daemon.py -v`。

VoiceMem 选择性移植的长期记忆层（七个 additive `memory_*` 方法、快照/向量原子提交、sqlite-vec 静态链接、真实配置的 compaction/embedding provider、易失 pending turns）合同见 [VoiceMem Rust 记忆合同](../../docs/plans/2026-09-08-voicemem-rust-contract.md)，出处与许可证见 `VoiceMem-NOTICE.md`。双路编排增补（`memory_recall` 两路同代检索与有界融合、`memory_ingest` 已交付回合原子入易失缓冲与 Rust 后台自动整理、`memory_status.orchestration` 可见状态）见 [VoiceMem Rust 双路记忆编排计划](../../docs/plans/2026-09-08-voicemem-rust-orchestration.md)，实现记录见 [Rust 核心 evidence](../../docs/plans/evidence/2026-09-08-voicemem-rust-core.md)。provider wire 见下方「VoiceMem provider wire」。进程级回归：`TASKD_BIN="$PWD/services/gmgn-taskd/target/debug/gmgn-taskd" python3 services/gmgn-taskd/tests/memory_process.py -v`、`python3 services/gmgn-taskd/tests/memory_races.py -v`（断连取消压缩、并发压缩绑定捕获基线 generation）与 `python3 services/gmgn-taskd/tests/orchestration_process.py -v`（后台批量/断连独立整理、ingest 原子幂等易失、recall 分路配额与单次共享 embedding）。注意：`tools/test-resident-state-daemon.py` 中的 v1 升级断言仍写死版本 2，v3 迁移后需改为 3（tools 归 Swift/tools owner，待其更新）。

## VoiceMem provider wire（Rust daemon 的 HTTP 客户端契约）

`memory_configure` 的 `endpoint` 是 origin（无路径）；daemon 在 origin 上调用两个**标准 OpenAI-compatible** 端点，离线 fixture 与独立验收 fixture 都必须实现它们（`memory_*` IPC 形状不变）：

- 压缩：`POST {endpoint}/v1/chat/completions`，Bearer token。
  请求 body：`{"model": <memory_configure 的 compaction model>, "messages": [{"role":"system","content": <COMPACTION_RULES>}, {"role":"user","content": "<previous 快照 + turns + limits 的 JSON 字符串>"}]}`。
  `model` 必须已配置（未配置时压缩以 `memory_compact_failed` 显式失败）；system content 与规则全文见 `src/memory.rs::COMPACTION_RULES`（长期事实/偏好 vs 有依据关系笔记、一次性请求不记、单次情绪不推人格、保留具体日期/名字/数字、notes 禁止照读、校正/删除以 `removed`+替换表达、输出 frozen envelope）。
  响应必须是 chat-completions JSON：顶层 `model` 回显请求模型，`choices[0].message.content` 是 frozen envelope JSON 字符串（容忍 ```json 围栏）：
  `{"facts":[{"category":"fact|preference","text":"…","observedAt":"…","grounding":"…"}],"notes":[{"category":"relationship|experience","text":"…","observedAt":"…","grounding":"…"}],"removed":["<上一版 entryID>"]}`。
- 嵌入：`POST {endpoint}/v1/embeddings`，Bearer token。请求 `{"model": <embedding model（可选提示）>, "input": [text…]}`。
  响应：`{"object":"list","data":[{"object":"embedding","index":i,"embedding":[…]}],"model":"…"}`；daemon 校验 count、`index` 顺序、model（顶层或逐条一致）、维度一致且 `1..=8192`、数值 finite 且向量非全零。压缩产出一条以上时对所有条目文本嵌入；零条且已有上一版时沿用上一版 model/维度（不调用）；零条且无上一版时以单条空文本探针锚定维度（探针向量丢弃，绝不落库）。
- 断连取消：请求在压缩 provider 返回后的迟到响应不得落库 —— `memory_compact` 的取消标志在提交 barrier 与存储线程提交闭包内检查；客户端断开后压缩以失败结束，pending 保留。压缩始终把「读取旧快照时的 generation」绑定为内部 CAS（即使省略 `expectedVectorGeneration`），并发中先提交者胜、后提交者 `memory_conflict`。
- 抽取上下文：chat 请求的 user content JSON 另含可选 `previousReply`（{text, source, observedAt}）—— 指向前一条已交付 agent 回复，即使它自己的 turns 已被上次整理清空仍保留在易失 pairs 列表，供回应经验归因（right-lane feedback）；同一 scope 任一方向只可能有一条。每条分路分区（vec0 虚拟表）带 `section` 元数据列（`facts`/`notes`），recall 两路都先按 scope/当前代/section 过滤再取 top-k，绝不做全局 top-k 后丢弃。


## VoiceMem 双路编排（memory_recall / memory_ingest / 后台整理）

- `memory_recall`：一次 query embedding 供事实/经验两路复用；每路先按 scope、当前 `vectorGeneration`、`section` 过滤再 KNN top-k（`factLimit` 默认 6、1–12；`noteLimit` 默认 4、1–8），两路同一代、有界融合为 ≤8000 Unicode 字符的纯文本 `context`。notes 在 context 中始终带「禁止照读/不据此认定人格」标记；两路都无命中时给出证据不足提示。`freshSession=true` 才在 context 中加入带标记的本地快照+易失 pending 有界恢复段（embedding 未配置时 facts/notes 为空、status=unconfigured，但本地恢复仍可用）。
- `memory_ingest`：只接受已交付回合，原子追加 user+agent 两条易失 turns 并按 scope 保持顺序（200 上限 FIFO）；`(scope, requestID)` 接收幂等只在内存有界保存（每 scope 最近 200 次），重放返回 `replayed:true`，同 requestID 不同内容返回 `memory_request_conflict`。原始对话文本永不落盘，重启后未整理原文与接收幂等一并丢失。source=text/voice、observedAt 与前一真实 agent 回复作为易失抽取上下文。回复中的 `consolidation` 表示 idle/pending/running/unconfigured/failed。
- Rust 后台自动整理（同 daemon、同库、单 writer，与显式 `memory_compact` 同一提交管线）：同 scope 至多一项进行中；pending turns 达到阈值（默认 4 条）短延迟（默认 2s）后启动，未达阈值空闲 30s 后整理。时钟/阈值是内部可注入策略（`memory_orchestrator::Policy`），离线测试注入毫秒级延迟，绝不实等 30 秒，也不新增用户配置框架。失败不清 pending、不无限重试（下次新输入或显式 `memory_compact` 重试），`memory_status.orchestration = {state, lastError}` 以稳定错误码可见。已接受回合的后台整理独立于短 IPC 连接寿命；显式长请求 `memory_compact` 的断连取消语义不变，两者不混用。

## IPC

完整 JSON 合同见 [Rust 后台合同](../../docs/plans/2026-09-07-rust-taskd-contract.md)。每行一个 JSON 对象，收发帧上限均为 12 MiB；请求 `id` 为 1—200 UTF-8 字节字符串，回复带原 `id`，事件和业务消息分别带 `event`、`message`。同一连接可交错请求和订阅，也可为每个订阅使用独立连接。

`snapshot` 每页不超过 2 MiB。若返回 `nextCursor`，继续发送 `snapshot` 的 `{cursor:nextCursor}` 参数；游标是不透明字符串，可跨连接使用。所有页来自首帧 `sequence` 的同一持久历史边界。客户端取齐后投影，再从该 sequence 重放事件。

远端返回只允许同 origin 的固定任务路径。禁重定向、代理环境和自动 HTTP 重试；请求超时 60 秒，状态响应上限 1 MiB，PNG 上限 8 MiB/2048²，模型流式上限 32 MiB。PNG 完整解码，GLB 核验 magic/version/声明长度及远端 bytes/SHA256。返回的 inspection 必须符合 Swift 解码合同。发布路径均由后台生成，并拒绝符号链接素材。

`ready` 仅表示模型已经校验并落盘；场景真实渲染、领取与摆放仍由应用确认。取消先持久化，远端完成后取消过晚会保留 `cancelRequested` 并报告 `interrupted/cancellation_too_late`，不会伪称已取消。模型下载过程中收到取消时不发布模型。

旧 `PropGeneration/tasks.json` 只读导入，素材复制到新私有目录；保留原 UUID、幂等键和有效回执。已有远端 ID 继续查询，无回执记录不会自动重发。源文件损坏时启动失败并保留原文件，成功迁移按源根目录幂等记录。

依赖 API 核对参考：[Tokio watch](https://docs.rs/tokio/latest/tokio/sync/watch/)、[reqwest ClientBuilder](https://docs.rs/reqwest/0.12.28/reqwest/struct.ClientBuilder.html)、[rusqlite Connection](https://docs.rs/rusqlite/0.32.1/rusqlite/struct.Connection.html)、[PNG Decoder](https://docs.rs/png/0.17.16/png/struct.Decoder.html)。
