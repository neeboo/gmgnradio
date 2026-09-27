# VoiceMem Rust 双路记忆编排 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在现有 Rust 记忆核心上实现实际的事实/相处经验双路检索、上下文融合、交付后写入与后台整理，并接上现有 Swift 语音对话。

**Architecture:** 用户最新要求由一个 DSH 专做 Rust，另一 DSH 做 Swift/语音接线、配置和离线验证。Rust 复用 gmgn-taskd、同一 SQLite 和单 writer；Swift 不再实现记忆整理调度。两路逻辑可共享一次语义抽取和一次查询 embedding，减少重复推理；不新增 Python 服务、图数据库或第二个 daemon。

**Tech Stack:** Rust/Tokio、现有 rusqlite + sqlite-vec 0.1.9、OpenAI-compatible 模型接口、Swift 6。

## 最新范围与设计决定

- 本增补覆盖旧计划“仅双段快照、不移植编排”的范围。保留既有七个 memory_* 方法及原状态/任务/消息合同；新增下面两个方法和 memory_status 可选附加字段。
- Rust owner 先完成正在进行的并发/断连/标准 provider 修复，再实现本增补。另一 DSH 不参与 Rust，只使用冻结 IPC 做 Swift 接线。
- 双路含义：事实路负责长期事实/偏好；经验路负责有依据的关系和回应经验。写入阶段可由一次 merged extraction 产出两路结果，随后分别校验/合并；检索阶段各自筛选/排序/限额，最后融合。仅给数组改名或在 Swift 拼两段不算实现编排。
- 延迟敏感路径仅做一次 query embedding、两路本地检索与有界融合。压缩/经验更新在后台，不能成为回复首字前置；故障明确可见，聊天继续。
- 复用已有语音转写和交付/打断信号。本轮不新建声纹、声学情绪识别或音频模型；source=voice 表示真实语音转写来源，不证明识别了声纹/情绪。
- Rust 减少本地调度和内存开销不等于端到端必然大幅更快；模型推理和网络可能占主导。本轮不新增性能选型或 benchmark。
- 继续禁止 App/test-host/GPU/钥匙串/系统授权/AppleScript/窗口探测/真实用户库/真实模型验证或权重下载/提交推送部署。复用当前用户指定工作目录与未提交改动，不另建工作树。

## 冻结 IPC 增补

通用 scope、帧限制、字段命名、凭据卫生与错误封装沿用 `2026-09-08-voicemem-rust-contract.md`。新增请求 deny_unknown_fields。任何记忆文字都是数据，不作为宿主或工具指令。

### memory_recall — Rust 双路检索与融合

```json
{"scope":{"worldID":"w","residentScope":"r"},"query":"真实用户查询","freshSession":false,"factLimit":6,"noteLimit":4}
```

- query 1–500 字符；freshSession 可选默认 false；factLimit 可选默认 6，范围 1–12；noteLimit 可选默认 4，范围 1–8。
- 一次 embedding 共用于两路；每路先过滤 scope、当前 vectorGeneration、section，再取 top-k，不能先取全局/全段 top-k 再丢掉另一段。允许在每 scope 最多 280 条的小集合上使用 sqlite-vec 的距离函数做 section 预过滤精确排序，不要求为此引入另一套索引。
- 两路基于同一代快照，异步 embedding 前后的版本变化必须重读/明确冲突，不能混代。去重并限制最终 context 总长 8000 Unicode 字符。
- freshSession=true 可在 context 中加入当前长期快照和易失 pending 的有界恢复段；false 只加入本轮相关记忆，不能反复整段恢复历史。真正新会话由 Swift 判断。
- facts/notes 数组使用旧 memory_query hit 形状，section 分别为 facts/notes；observedAt 仍可选。notes 在 context 中明确标记“仅用于语气和相处参考，禁止照读或据此认定人格”。无具体证据时给出简短的证据不足提示，不编造事实。当前 query 不自动写入记忆。

```json
{"status":"ok","revision":1,"vectorGeneration":1,"facts":[],"notes":[],"context":"有界纯文本上下文","pendingTurns":2}
```

- status=ok/empty/unconfigured；无快照 revision/vectorGeneration=0。embedding 缺配置时 facts/notes 为空、status=unconfigured，但 freshSession 仍可恢复已确认的本地快照/pending；这不代表语义检索可用。
- 新形状错误 `invalid_memory_recall`；查询/限额/向量/存储/冲突沿用既有错误码（限额错误 `invalid_topk`）。

### memory_ingest — 已交付回合写入及 Rust 后台调度

```json
{"scope":{"worldID":"w","residentScope":"r"},"requestID":"uuid","userText":"真实用户输入","agentReply":"已交付成功的回复","source":"voice","observedAt":"2026-09-08T11:00:00+08:00"}
```

- requestID 必填 UUID；userText/agentReply 各 1–2000 字符，沿用 turn 控制字符规则。source 可选 text/voice，默认 text；observedAt 可选 ≤32 字符。只接受已交付回合；宿主 prompt、工具结果、图片、被打断/未播放回复不得传入。
- 原子追加这一对 volatile turns，不能只追加 user 后失败留下半对。按 scope 保持顺序，200 turn FIFO 上限照旧。保留 source/observedAt 和前一条已交付 agent reply 作为易失抽取上下文；不落盘原始音频/对话。
- (scope, requestID) 的接收幂等记录也只在内存有界保存（每 scope 最近 200 次）；同内容重放不重复入队，不同内容报 memory_request_conflict。崩溃后未整理原文/接收幂等一起丢失，不能承诺原文跨重启恢复。

```json
{"accepted":true,"replayed":false,"pendingTurns":2,"consolidation":"pending"}
```

- consolidation=idle/pending/running/unconfigured/failed；返回代表成功进入易失缓冲，绝不冒充长期保存。
- Rust 自动后台整理：同 scope 最多一项进行中；新回合合并调度，默认达到 4 条 pending turns 时短暂合并 2 秒后启动，未达阈值则空闲 30 秒后整理。把时钟/策略设为内部可注入以便离线测试，不新增用户配置框架。
- 失败不清 pending、不无限重试；下次新输入或显式 memory_compact 可重试。缺 provider 返回 accepted=true + unconfigured，保留 volatile 内容。
- 已接受、已交付回合的后台整理独立于短 IPC 连接寿命，允许客户端正常断开后完成到原 scope。显式长请求 memory_compact 的断连取消要求仍保留。两者不能混用取消语义。
- memory_status 增加 `orchestration: {state, lastError}`，lastError 为稳定错误码或 null，无敏感详情；旧客户端可忽略附加字段。
- 新形状错误 `invalid_memory_ingest`，文本/凭据/scope/重复冲突沿用旧码。

## Task 1：Rust 专项（唯一 Rust DSH）

**Files:** `services/gmgn-taskd/src/memory.rs`、新建 `memory_orchestrator.rs`（按需要拆分）、`daemon.rs`、`main.rs`、Rust/进程 tests、README/NOTICE 与 Rust evidence。禁止改 Swift/tools。

1. 先完成现有两项独立竞态失败、HTTP fixture 挂起和真实标准 provider 接入，保留旧合同回归。
2. 针对 recall 两路独立配额、同代、无证据提示、fresh/resume、预算写失败测试；再实现真实 Rust 方法与 IPC dispatch。
3. 针对 ingest 原子回合/幂等/source/前一回复、背景归因、后台合并/空闲整理/失败/并发写失败测试；再实现单 scope 调度和状态。
4. 更新 merged extraction 规则：长期事实与相处经验分别约束；利用前一已交付回复理解反馈，但不把一次情绪提升为人格；校正/删除正确，notes 有依据。
5. 单事务提交两路快照及同代向量，成功后才清 captured pending；不改变单 writer。
6. `cargo test`、`cargo clippy -- -D warnings`、`tests/process.py`、新增真实临时 daemon 编排回归；每项真实有界超时。禁止重复长时间压力测试代替定位。

## Task 2：Swift/语音接线（另一 DSH，不参与 Rust）

**Files:** `ResidentMemoryClient.swift`、新建薄 `ResidentConversationMemory.swift`、对应离线工具；随后 `AgentConversationService.swift`、`GMGNRadioApp.swift`、必要 `AgentSpeech.swift`、测试/工程文件。不要动 Presence/Inbox 或 Rust。

1. 为新增两方法/status字段增加类型与 fixture；薄适配器只调用 recall/ingest，不再在 Swift 做双路排序或每回合安排 compact。
2. 服务根据原生 session/进程历史判断 fresh；真实 query 从显式 userMessage 或普通聊天输入获得，不能用组装后的 prompt 检索/入库。无输入的后台轮次不写虚构 user turn。
3. 删除/停用这一轮新增的 durable raw transcript 路径，保留无关居民计划/收件箱状态存储。
4. App 通过 scope/current-turn 检查及实际交付确认后调用 ingest；语音完成才计成功，被取消/未播完不计；静音文本以实际显示为交付。现有语音转写走同一入口并标记 voice，图片不进入记忆。
5. 配置两种 provider 的显式 endpoint/token/model，遵循既有环境配置模式，不读钥匙串、不把 token 存 UserDefaults/日志。缺配置状态可见。
6. 覆盖真实服务/应用调用点：取消、世界切换、fresh/native resume、只有成功交付才入队、缺配置聊天仍可用。先 fixture 后主代理统一临时 daemon/全 App compile-only 验证。

## Task 3：主代理整合验收

- DSH 实际源码 readback；Swift fixture + Swift→临时 daemon 新旧接口互通。
- 独立断连/并发/原文不落盘/跨 scope/恢复/后台整理与请求幂等测试，不将 worker 自报替代验证。
- 旧状态/消息/任务回归、项目同步、compile-only；不启动宿主或接触真实数据库。
- 报告离线实现验证与尚未进行的真实语音/模型质量验证，不声称完整 VoiceMem 图记忆或声音感知兼容。
