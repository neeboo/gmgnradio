# VoiceMem Rust Memory Port Implementation Plan

> **后续变更（2026-09-28）：外部 provider 层已整体移除。**
>
> 产品负责人决定：**记忆模块留在 Rust 里自己做，不再依赖外部 compaction / embedding 服务。**
> 因此本计划里"配置外部 provider"的那一半已删除：
>
> - daemon：`memory_configure` 及其 provider 存储、所有对外部 endpoint 的 HTTP 调用、
>   `memory_orchestrator.rs` 的压缩调度与它接入 `memory.rs` 的全部调用点；
> - App：`GMGN_MEMORY_*` 环境变量解析（`ResidentMemoryConfiguration.swift` 整个文件）、
>   provider 状态轮询、"缺配置 / 后台整理失败"的常驻可见提示；
> - 安装器：`--configure-memory-only` 与那套 provider 校验常量。
>
> **保留**：`services/gmgn-taskd/src/memory.rs` 的本地记忆（快照提交、ingest/recall/
> read/query/turn/pending、向量账本结构）以及 App 侧的 recall/ingest 接线。
> 语义压缩与向量检索暂时没有 provider —— 按上述决定留待 Rust 侧自行实现。
>
> **下面正文描述的是变更前的设计，保留作为历史记录。**

## Latest user amendment: DSH-only implementation

2026-09-08 latest scope expansion: implement Rust-side dual-lane orchestration as specified in `docs/plans/2026-09-08-voicemem-rust-orchestration.md`. One DSH owns the whole Rust specialization (core, concurrency/provider repairs, recall/ingest orchestration); the other owns Swift/voice application work only. Swift must not duplicate Rust consolidation scheduling. The former limited dual-section-only scope is superseded by that additive plan.

User removed CC and subsequently asked the current main agent to directly coordinate two parallel DSH workers. This supersedes all Ouroboros routing, sequential execution and CC dispatch instructions below. The directly launched Rust worker owns `services/gmgn-taskd/**` and its core evidence; the Swift worker owns the application integration, corresponding tests/tools and integration evidence. Both consume the frozen IPC contract without redesigning it. The main agent owns integration review and final offline verification. Do not start or resume CC or the superseded Ouroboros tasks. Preserve credentials in the existing configured runtime; never print, persist or copy them. Source implementation remains with the two DSH workers.

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. User selected CC and DSH workers, coordinated and verified by Ouroboros with gpt-6-astra / low.

**Goal:** Replace the unfinished durable raw-chat path with CPU-only Rust memory snapshots and vector retrieval, inspired by VoiceMem.

**Architecture:** The existing gmgn-taskd owns compact structured memory and its SQLite persistence. Facts/preferences and grounded relationship/experience notes are separate sections of one versioned snapshot; temporary conversation context is volatile. Semantic compaction and embedding use explicitly configured providers, outside latency-sensitive reply processing. CPU sqlite-vec performs retrieval; do not add GPU inference, Python service, Qdrant server, or a second database writer.

**Tech Stack:** Rust, existing rusqlite/serde/tokio/reqwest, pinned sqlite-vec, Swift client adapter. This is a selective port, not a claim of full VoiceMem compatibility.

## User-approved scope and amendment

- Supersedes the previous 30-round durable transcript goal and its verifier criteria. Preserve unrelated inbox improvements and all pre-existing dirty worktree changes.
- VoiceMem reference commit: a450911fc8cbb44c46d810aace2f3288bad287e4 at https://github.com/xzf-thu/VoiceMem . Port useful SessionBuffer commit-after-durability and bounded fact/relationship consolidation semantics. Record exact source paths and port deviations; preserve Apache-2.0 license and applicable notices for derived material.
- Upstream vector backend is Python Mem0 + Qdrant local mode. Official Rust Qdrant client requires a server. User permits a simple existing vector library: choose sqlite-vec statically linked into the existing daemon, pinned to an inspected stable release; test against existing rusqlite before accepting it. Do not use alpha releases by default or silently substitute custom hash vectors for semantic embeddings.
- CPU-only applies to host storage/search and any eventual local embedding backend. Provider calls may use remote inference; do not claim complete offline CPU inference unless actually implemented and tested. No real model calls or model-weight downloads for validation this round; use deterministic provider fixtures. Missing configuration must be visible, not fake success.
- No App/test-host launch, GPU/Metal/CUDA, keychain/security access, system authorization, AppleScript/window detection, real user database read/migration, paid generation, commit/push/deploy, or unrelated changes. Dependency download/build for sqlite-vec is authorized within scope. Never automatically start a model runtime.

## Task 1: Freeze the minimal additive IPC contract (DSH owns, CC consumes)

Files: `services/gmgn-taskd/src/` relevant existing IPC dispatch/storage files; create `docs/plans/2026-09-08-voicemem-rust-contract.md`.

1. Inspect existing state/store ownership and providers before selecting exact module names. Preserve existing `state_read/state_commit/event_read/message_read/message_ack` contracts and all wish/job behavior.
2. Define only required additive operations for reading memory, committing validated compact snapshots, and querying relevant entries. Scope by worldID/residentScope, with revision, schemaVersion, processed input watermark, explicit embedding model/dimensions. Freeze this document before CC wiring.
3. Keep snapshot and derived vectors transactionally consistent or make the vector index explicitly rebuildable and generation-matched; never return stale vectors as current memories. No durable transcript or indefinite duplicate event log of chat-derived memories.
4. Test invalid inputs, scope isolation, stale revision and same-request replay first.

## Task 2: Port Rust memory core and sqlite-vec (DSH owns)

Files: new focused module under `services/gmgn-taskd/src/`, Cargo.toml/Cargo.lock, Rust tests, upstream provenance/license files within module documentation.

1. Write failing tests for snapshot validation, bounded entries, fact versus relationship separation, exact dates/names/numbers, correction/removal, no inferred personality promoted from transient mood, and compact failure preserving previous snapshot.
2. Implement volatile pending turns and compaction input/output contract. Advance watermark and clear pending turns only after durable commit; prevent cancellation, scope change, or late completion from writing into another scope. Clearly document crash loss of uncompacted volatile text.
3. Implement actual provider-backed compaction path through existing configuration patterns; no tools or action execution for memory summarization. Do not present concatenation/truncation as semantic compact.
4. Add sqlite-vec with minimal static registration. Test insert/query, cosine ranking, filtering BEFORE top-k, zero/NaN/dimension/model mismatch rejection, update/delete and restart durability on temporary databases. Query only this world's resident scope. Use bounded top-k/context budgets.
5. Add usable configured embedding provider path and deterministic fake transport tests. Embedding generation and vector search are separate capabilities. Missing provider surfaces an explicit unavailable status without breaking chat; do not falsely label lexical hashing as semantic vectors.
6. Run `cargo test --manifest-path services/gmgn-taskd/Cargo.toml` and existing temporary-daemon regressions. Never touch real databases. Report exact commands and exit codes.

## Task 3: Swift integration (CC owns)

Files: `apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`, memory client/store adapter, `App/GMGNRadioApp.swift`, corresponding tests and project generation; preserve Presence/ResidentSystemInbox work.

1. Reuse existing CC acpx session `gmgn-resident-conversation-store-20260908`; its active command was cancelled for this user amendment. Inspect stale queue before resuming; old raw-transcript prompts are superseded.
2. Stop invoking raw transcript persistence; adapt only the newly introduced conversation storage pieces after checking diffs. Do not delete unrelated user work or touch existing user database contents.
3. Use DSH's frozen additive contract. Supply only real user text and delivered successful replies to volatile input; never host prompts, hidden tool results, image bytes, credentials, or unplayed interrupted speech.
4. Retrieve bounded relevant memory for context and restore snapshot on genuinely fresh session; avoid re-injecting historical context repeatedly into native resumed sessions. Background compact cannot block a reply.
5. Test real application callsites using fixtures and temporary daemon, including missing configuration, cancellation and world change. Run relevant offline Swift 6 tests; regenerate project and compile-only build if needed, with no test host or App launch.

## Task 4: Independent verification (gpt-6-astra / low)

- Confirm DSH and CC implemented their own assigned code and neither silently replaced the user-selected workers with Codex source edits.
- Verify actual source paths, no active durable raw-chat path, all additive IPC and old-contract regressions, atomic snapshot/vector consistency, and real configured provider wiring with deterministic fixtures.
- Inspect dependency lock/provenance and CPU-only execution path. Do not use host launch, GPU, user databases or real model probes.
- Report exact fresh test/build evidence and remaining manual runtime/model-quality checks in `docs/plans/evidence/2026-09-08-voicemem-rust-port.md`.
- Two bounded repair cycles, preserving worker file ownership. Stop and report a genuine external/configuration blocker; do not weaken acceptance or invent success.
