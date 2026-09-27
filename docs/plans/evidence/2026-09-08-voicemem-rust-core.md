# VoiceMem Rust port — DSH worker core evidence (task_b86c97e7287f438187ac253ee87c8e75)

Date: 2026-09-08. Role: worker (DSH native executor). Approved plan read in full
(`docs/plans/2026-09-08-voicemem-rust-port.md`); latest user amendment (DSH owns all
Rust/Swift implementation, no CC, native executors) honored. This file is the worker's own
evidence path; independent verification evidence lives in
`docs/plans/evidence/2026-09-08-voicemem-rust-port.md`.

## Result: BLOCKED (repo write denied), with the frozen contract published and the
vector/provider approach verified in an off-tree scratch build.

The additive IPC contract is now frozen and committed to the allowed path:
`docs/plans/2026-09-08-voicemem-rust-contract.md` (346 lines, written by this worker,
`wc -l` exit 0). It defines seven additive methods (`memory_configure / memory_status /
memory_read / memory_query / memory_turn / memory_pending / memory_compact`), the scoped
versioned snapshot model with `facts` + grounded `notes` sections, volatile per-scope pending
turns with VoiceMem SessionBuffer commit-after-durability watermark semantics, atomic
snapshot/vector consistency by `vectorGeneration`, per-scope sqlite-vec cosine partitions
(filter before top-k), explicit provider unavailable status, the full error-code table, and
VoiceMem provenance/deviations. Existing IPC contracts were not modified (no edits possible
or attempted outside allowed writes; see below).

## Blocker (exact, external configuration)

The DSH file sandbox for this run only allows file writes to three literal paths plus the
sandbox tool-home. The task-context `dshFilePolicy` lists `services/gmgn-taskd` as an allowed
path, but the executed sandbox profile renders it as a `literal` directory allowance rather
than a `subpath`, so **no file or directory under `services/gmgn-taskd/**` can be created,
edited, or deleted** — the Rust core (Task 2) cannot be authored in the repository. Reproduced
with the exact intended edits (`bash`, exit codes are the command outcomes):

```sh
printf '\nsqlite-vec = "=0.1.9"\n' >> services/gmgn-taskd/Cargo.toml   # exit 1: Operation not permitted
printf '// memory module\n' > services/gmgn-taskd/src/memory.rs         # exit 1: Operation not permitted
mkdir -p services/gmgn-taskd/src/subprobe                               # exit 1: Operation not permitted
cp docs/plans/2026-09-08-voicemem-rust-port.md services/gmgn-taskd/x.md # exit 1: Operation not permitted
```

The active profile (`~/.ouroboros/runtime/dsh-process-policies/d692d3a1-…/runner.mjs`) contains
`(allow file-write* (literal "/Users/ghostcorn/dev/gmgnradio/services/gmgn-taskd"))` — sibling
profiles in the same runtime use `(subpath …)`, confirming a policy-translation defect rather
than an intended narrower task. Escalation is unavailable: retrying the identical write with
`sandbox_permissions=danger-full-access` returned `sandbox escalation to "danger-full-access"
requires approval, but no approval channel is available`, and `workspace-write` was rejected as
not strictly wider than the current mode. The denial is therefore final for this run.

Baseline read-only inspection (no changes made): `services/gmgn-taskd/src/` contains
`daemon.rs files.rs main.rs messages.rs model.rs provider.rs resident.rs store.rs`;
`Cargo.toml` pins `rusqlite 0.32 bundled` and contains no sqlite-vec; `resident.rs`/`store.rs`
implement v1+v2 resident storage on one SQLite writer. Dirty worktree in `apps/macos/**` and
other docs is preserved untouched. `services/` is untracked in git (pre-existing, not from this
worker). No runtime/control paths (`.ouroboros/`, `.orbs/`, `.git/orbs/`) were touched.

## Verified off-tree (writable sandbox tool-home, CPU only)

1. **VoiceMem pinned reference** downloaded and inspected at the exact commit
   `a450911fc8cbb44c46d810aace2f3288bad287e4` (confirmed `HEAD` of `xzf-thu/VoiceMem`, Apache-2.0).
   Ported-semantics source paths recorded: `web/session_context.py` (SessionBuffer
   commit-after-durability); `voicemem/leftbrain/extract_facts_openai.py` (additive facts, junk
   filtering, attribute/correction); `voicemem/leftbrain/memory_repository.py` +
   `memory_repository_v2.py` (bounded consolidation, update/correction);
   `voicemem/orchestrator.py` Ingest/_finish_ingest and `voicemem/rightbrain/brain.py`
   `RightBrain.write` + `experience_repository.py` (grounded relationship/experience notes);
   `voicemem/leftbrain/merged_extraction.py` (no transient-mood→personality promotion).

2. **sqlite-vec stable release pinned and statically registered**: crate `sqlite-vec 0.1.9`
   (crates.io `max_stable`; 0.1.10-alpha rejected per plan's no-alpha rule) inspected: it
   vendors `sqlite-vec.c`, is built by `cc` with `SQLITE_CORE`, exposes `sqlite3_vec_init`,
   and registers through `sqlite3_auto_extension` before opening a `rusqlite` connection.
   Scratch binary against the daemon's `rusqlite 0.32 bundled` ran (exit 0):
   `vec_version=v0.1.9`, `rows=4`, cosine `top2=[(1, 0.1), (4, 1.0049876)]`, wrong-dimension
   query `mismatch_is_err=true`, `rows_after_delete=3`. Static CPU linking, cosine ranking,
   dimension-mismatch rejection, insert/delete all confirmed. This satisfies the plan's
   "test against existing rusqlite before accepting it".

## Apply-ready implementation blueprint (for the next run with a writable sandbox)

Everything below is designed and ready to land as one change set in `services/gmgn-taskd`,
exactly matching the frozen contract:

- `Cargo.toml`: add `sqlite-vec = "=0.1.9"`; regenerate `Cargo.lock` (`cargo build --locked`
  after `cargo update -p sqlite-vec` on a writable copy, then port the lock diff).
- `src/main.rs`: `mod memory;`.
- New `src/memory.rs` (mirrors `resident.rs` structure): schema v3 `memory-storage-v1`
  (`schema_migrations` step 3 in `store.rs::migrate`), tables for per-scope snapshot row +
  requestID replay + rowid↔entry map, in-memory per-scope pending-turn buffers + durable
  `nextWatermark` counter; vec0 partition helper (per-scope table name from a short SHA-256 of
  `worldID|residentScope`, `distance_metric=cosine`, `float32[dims]`); functions for
  read/status/query/pending/append/compact on `Connection`/`Transaction` only.
- `src/daemon.rs`: register `memory_configure/status/read/query/turn/pending/compact` in
  `Service::request`; store provider credentials in-memory keyed `(kind, origin)`; guard all
  request params with the existing `provider::contains_secret` hygiene.
- Provider transports reuse `provider::client()`/origin rules; compaction output envelope and
  deterministic validation (`facts`/`notes` caps, category whitelist, mandatory notes
  `grounding`, `removed` must reference prior entries) per contract §4.1; embedding per §4.2.
- Commit path: capture scope + pending + prior generation, call providers off the writer
  thread, then one transactional CAS commit (`expectedVectorGeneration`), insert vectors in
  the same transaction, clear pending `≤ processedWatermark` only after commit.
- Unit tests + loopback fixture HTTP servers (pattern of `tests/process.py`) per contract §8,
  plus `cargo test --manifest-path services/gmgn-taskd/Cargo.toml` and temporary-daemon
  regressions; report exact commands/exits.

## Remaining work for acceptance (blocked on sandbox)

Author and run Task 2's Rust core + sqlite-vec tests in `services/gmgn-taskd`, run daemon
regressions, then hand the frozen contract + evidence to the Swift integration task and the
independent verifier. No source implementation, tests, or daemon regressions were fabricated;
nothing above is claimed as completed repo work.

## Required external action

Re-run or re-scope this DSH worker under a sandbox whose file-write profile uses
`(subpath "/Users/ghostcorn/dev/gmgnradio/services/gmgn-taskd")` (and the two evidence/contract
paths already granted), or provide an approval channel so `danger-full-access` escalation can
authorize the same writes. The frozen contract is already published and the sqlite-vec/upstream
approach verified, so the next attempt needs only the writable sandbox to land and test the core.

## Progress update (same worker, later direct-execution run, 2026-09-08)

Previous run was blocked on a literal-vs-subpath write policy; this run executes
directly under a workspace-write sandbox, so the Rust core has now been landed in
`services/gmgn-taskd/**` (no CC/other-agent involvement; Swift/tools untouched).

Landing so far (all files under `services/gmgn-taskd/`, my exclusive scope):

- `Cargo.toml`: added `sqlite-vec = "=0.1.9"` (max stable, inspected: builds
  `sqlite-vec.c` with `SQLITE_CORE`, no runtime deps, exports
  `sqlite3_vec_init`; verified static registration + cosine KNN + wrong-dim
  rejection against this repo's `rusqlite 0.32 bundled` in an off-tree probe).
- `src/memory.rs` (new, ~2.9k lines incl. behavior tests): frozen-contract data
  model (facts/preferences + grounded notes sections, one versioned snapshot
  per scope), schema v3 `memory-storage-v1` tables, per-scope sha256-derived
  vec0 partitions (`distance_metric=cosine`), requestID idempotency table,
  volatile per-scope pending-turn buffers with commit-after-durability, real
  configured compaction/embedding provider HTTP paths with deterministic
  validation, and the seven `memory_*` operations as async handle methods.
- `src/main.rs`: `mod memory;` + process-wide sqlite-vec auto-extension before
  any connection opens; `src/store.rs`: migration step 3 wired; `src/daemon.rs`:
  seven additive request arms + credential hygiene across all configured tokens.
- Behavior tests authored inside the module were run RED first (8 failing:
  FIFO bound expectation, first-commit `removed:[]` validation over-reach,
  replay-before-stale-guard ordering, test expectation fixes), then GREEN:
  `cargo test` now 53 passed / 0 failed (includes pre-existing resident,
  messages, model, store, daemon tests; old contracts untouched).
- Provider mapping decisions (documented, frozen-code-table only, no new
  codes): compaction transport failure -> `memory_compact_failed`; compaction
  output validation -> `compaction_rejected`; embedding transport failure ->
  `embedding_rejected` (query) / `memory_compact_failed` (compact pre-commit);
  embedding output shape/vector validation -> `embedding_rejected` /
  `invalid_vector`; stored model/dimension drift -> `embedding_dimension_mismatch`.
- Compact requestID digest pins only the client-controlled CAS expectation
  (`expected:none`/`expected:N`): replay never double-processes because the
  commit clears pending <= processedWatermark and the commit-time stale guard
  rejects a later writer reusing the same turns.

Remaining: daemon process regression (`tests/memory_process.py`), existing
regressions, NOTICE/provenance files, README/evidence finalization, clippy,
final report. Full commands/exit codes appended at the end.

## Acceptance-fix round 1 (same worker, 2026-09-08, direct execution)

Main-agent real temp-daemon acceptance found four concrete defects. All fixed in
`services/gmgn-taskd/**` only; the frozen contract, tools and Swift files were
not modified. Commands below ran with `CARGO_HOME=/tmp/gmgnradio-cargo-home`
(the same cargo home the earlier round used) and every command under a real
`gtimeout` bound.

### Fix 1 — disconnect cancels an uncommitted compaction (contract §2.4)

`daemon.rs::serve_connection` used to await each request inline, so a client
EOF during `memory_compact` was only noticed after the compaction had already
committed. Requests are now run on spawned tasks with a per-connection
`memory::Cancellation`; the reader is polled while the request is in flight and
EOF cancels + aborts the task. `memory::compact` checks the flag at its commit
barrier **and inside the storage-thread commit closure**, so a provider
response that arrives after the disconnect can never be written; the pending
turns survive and nothing is recorded. The commit-time pending clear moved into
the same `db.call` closure so an abort can never leave a durable commit with
its turns still pending (which would wedge later compactions).

### Fix 2 — compaction binds the captured base generation (internal CAS)

`memory::compact` previously only honored an explicit `expectedVectorGeneration`
and relied on a processed-watermark guard, so two concurrent compactions that
both read generation 0 could both commit (second overwrote the first's output).
Now, after reading the previous snapshot, the compaction binds
`expected = Some(<generation it actually read>)` even when the client omitted
the field, and a client-provided expectation that already differs from the read
base is rejected before any provider call. The losing writer returns
`memory_conflict`, its output never lands and its pending turns stay for a
retry. `memory_query` additionally re-validates the stored model/dimensions on
the storage thread in the same `db.call` as the search (single-writer atomic
generation swap), so a query embedding can never be matched against a
mixed-generation or mixed-model vector partition.

### Fix 3 — intentional configure tokens kept (no redesign)

The `memory_configure` arm already bypasses credential hygiene (its job is to
receive a provider token) while `memory_turn`/`memory_status`/… keep rejecting
configured tokens anywhere in params. Regression coverage retained: same token
across both provider kinds and idempotent reconfigure, token-bearing turns
rejected without persisting or echoing the token.

### Fix 4 — real OpenAI-compatible provider wire

The self-made `/v1/memory/compact` and `/v1/memory/embeddings` paths (no real
service implements them) were replaced by standard endpoints that any
OpenAI-compatible service implements:

- compaction: `POST {endpoint}/v1/chat/completions` with the configured model,
  `COMPACTION_RULES` as the system prompt (long-term facts/preferences vs
  grounded relationship/experience notes; one-off requests are not memories;
  a single mood is not a personality trait; preserve concrete dates/names/
  numbers; notes are internal and never read back; corrections/deletions are
  `removed` + replacement entries; frozen envelope only) and the previous
  snapshot + turns + limits JSON as the user content. The response must echo
  the requested model; `choices[0].message.content` is parsed as the frozen
  envelope JSON (``` fences tolerated). A missing configured compaction model
  fails explicitly with `memory_compact_failed`.
- embedding: `POST {endpoint}/v1/embeddings`; the response `data[index]`
  entries are validated for count, ordered `index`, consistent `model`
  (top-level or per item), a single shared dimension in `1..=8192`, finite
  numbers and non-zero vectors (`NaN/Inf/zero-dim/all-zero` → rejection).
  A compaction that yields no entries carries the previous embedding record
  forward (no call); a first all-empty compaction anchors model/dimensions
  with one empty-text probe whose vector is discarded (never stored).

`memory_*` IPC shapes are unchanged. README documents the wire for the
main agent's independent fixture, which was updated in lockstep.

### Verification (exact commands and outcomes)

- `gtimeout 500 cargo test --locked` (CARGO_HOME=/tmp/gmgnradio-cargo-home)
  → `test result: ok. 61 passed; 0 failed` (was: cargo test hung > 7 min after
  the earlier fixture rewrite; the loopback fixture now stops its accept loop
  with a stop flag + wake-up connect and joins every connection thread, and all
  waits are bounded).
- `gtimeout 400 cargo build --locked` → Finished (exit 0).
- `gtimeout 400 cargo clippy --locked --all-targets -- -D warnings` → Finished
  (exit 0, no warnings).
- `TASKD_BIN=…/target/debug/gmgn-taskd python3 tests/memory_process.py`
  → `Ran 8 tests … OK` (rewritten to the OpenAI-compatible fixture; asserts the
  model, rules prompt and user data are actually sent).
- `TASKD_BIN=… python3 tests/memory_races.py` → `Ran 2 tests … OK` (new-wire
  copy of the two acceptance sequences: disconnect-cancel and concurrent
  base-generation CAS, run over the real daemon socket).
- `TASKD_BIN=… python3 tests/process.py` → `Ran 19 tests … OK` (pre-existing
  resident/job regressions untouched).
- `TASKD_BIN=… python3 tools/test-resident-state-daemon.py` (read-only, not
  modified) → 8/9 pass; the only failure is the pinned schema-version assertion
  `assertEqual(version, 2)` at line 557 → `AssertionError: 3 != 2` (v3
  memory-storage migration is expected; the tools owner must update the pin to
  3 — this was already flagged in the module README).
- Main agent's independent file `/tmp/gmgn-memory-independent-20260908.py`
  (their fixture now serves the new wire) → `Ran 6 tests … OK`, including
  `test_disconnect_cancels_uncommitted_compaction` and
  `test_concurrent_compaction_checks_captured_base_generation`.
- Full independent run reproduces the two original failures against the
  pre-fix binary (revision=1 late commit; second writer overwrote to
  revision 2) and both pass post-fix; no assertions were weakened.

---

## VoiceMem 双路编排 Task 1（2026-09-08 第二轮，唯一 Rust DSH）

来源：`docs/plans/2026-09-08-voicemem-rust-orchestration.md` 完整读取；旧七方法合同
`2026-09-08-voicemem-rust-contract.md` 只读引用；上一轮修复最终结果
`/tmp/gmgn-dsh-rust-repair1-20260908.log` 核对（61 tests OK，工具 schema 固定断言属
tools owner）。本文件为本轮唯一写入路径之一；改动范围：`services/gmgn-taskd/**`。

### 实现内容（真实行为，非接口壳）

- **`memory_ingest`**：只接受已交付回合，user+agent 两条易失 turns 在单缓冲区锁内**原子**
  追加（abort 只能落在下一次 await，不可能留下半对），`(scope, requestID)` 内容摘要幂等
  仅在内存有界保存（每 scope 最近 200 条）；同 requestID 不同内容 → `memory_request_conflict`。
  source=text/voice、observedAt 与**前一真实 agent 回复**（易失 pairs 列表，即使已被上次
  整理清空仍保留）作为抽取上下文。原文绝不落盘；重启后 pending 与接收幂等一并丢失。
- **后台自动整理**（`memory_orchestrator.rs` 纯策略/状态机 + memory.rs 驱动）：pending ≥ 阈值
  （默认 4 条）短延迟 2s，否则空闲 30s；策略内部可注入（`Policy`），测试注入毫秒级、实等有界，
  不新增用户配置框架。同 scope 至多一项进行中（registry claim/generation 防旧 sleep 误启动）；
  失败不清 pending、不无限重试（下次输入或显式 compact 重试），`memory_status.orchestration
  = {state, lastError}`（稳定错误码/null）。后台运行持 Arc 独立于 IPC 连接寿命；
  显式 `memory_compact` 断连取消（Cancellation 提交 barrier/存储闭包内检查）语义原样保留并区分。
- **`memory_recall`**：一次 query embedding 供两路复用；每路**先按 scope/当前代/section 过滤再
  KNN top-k**（vec0 分区新增 `section` 元数据列，同代 barrier 在单次存储线程调用内完成两路检索），
  factLimit 默认 6/1–12、noteLimit 默认 4/1–8，去重后有界融合 ≤8000 Unicode 字符；notes 段恒带
  「禁止照读/不据此认定人格」标记；无命中给证据不足提示；`freshSession=true` 才注入有标记的本地
  快照+pending 有界恢复段（embedding 未配置时 status=unconfigured 但本地恢复仍可用）。
- 合并抽取仍是**一次 chat 调用 + 一次 embedding 批次**；两路独立校验/合并语义后**单事务**提交
  快照+同代向量；内容未变条目复用上一版 id（稳定 entryID），`removed` 内的 id 永不复用，纠正/删除
  以新 id 替换表达。不回归上一轮：内部 CAS 绑捕获代、查询同代、断连提交门禁全部保留（旧测试原样通过）。
- 分区建表升级：旧二进制无 `section` 列的 vec0 分区在下一次提交事务内 DROP+按新形状重建；
  recall 遇到旧分区时退化为无语义命中（而不是报错），随下次整理自愈。

### 文件

`src/memory_orchestrator.rs`（新）、`src/memory.rs`、`src/daemon.rs`、`src/main.rs`、
`tests/orchestration_process.py`（新）、`README.md`。未改 tools/Swift；`tools/` 只读复验。

### 验证（最终二进制，均有界超时；退出码即命令结果）

- `CARGO_HOME=/tmp/gmgnradio-cargo-home cargo test --locked --offline`
  → exit 0，`70 passed; 0 failed`（0.35s；61 旧 + 5 状态机 + 4 编排行为：原子幂等易失+后台批量提交、
  失败保留+可见错误、recall 分路配额+单次 embedding+scope 隔离、fresh 无 embedding 本地恢复）。
- `cargo clippy --locked --offline --all-targets -- -D warnings` → exit 0（无警告）。
- `CARGO_TARGET_DIR=/tmp/gmgn-taskd-target-rust-worker cargo build --locked --offline` → exit 0；
  `tests/orchestration_process.py`（新增 4 项）→ OK；`tests/memory_process.py`（8）→ OK；
  `tests/memory_races.py`（2）→ OK；`tests/process.py`（19）→ OK。
- 主代理独立复验：`/tmp/gmgn-memory-independent-20260908.py`（6）→ OK；
  `/tmp/gmgn-orchestration-independent-20260908.py`（4：原子/幂等/易失、双路独立配额+一次
  embedding+禁止照读、前一已交付回复在 pending 清空后仍参与下一次经验归因、稳定 entryID）→ OK。
- `tools/test-resident-state-daemon.py`（只读、未改）→ 8/9；唯一失败仍是 tools 固定 schema v2 断言
  （v3 迁移，需 tools owner 改 3），与上一轮一致。

### 设计说明（供主代理/其他协作者知悉）

- `freshSession` 语义：恢复段以带标记文本块进入 `context`（facts/notes 两路仍只含本轮相关命中），
  status/revision/vectorGeneration/pendingTurns 形状不变；真正新会话由 Swift 判断。
- 后台整理每次以随机 requestID 走与显式 `memory_compact` 完全相同的提交管线，因此每次自动整理也会在
  `memory_requests` 落一条幂等行（仅用于请求级回放保护；后台不重试旧 requestID，行只随整理次数增长，
  如需有界化可后续加 `record_request` 门）。计划未禁止，记录于此。
- 断连但请求未被接受的 ingest 不会留半对（请求取消于同步追加前）；已接受回合的连接生命周期不影响后台整理。

### 未决/交接

- tools schema 版本断言待 Swift/tools owner 更新（非 Rust 范围）。
- 主代理另有 Swift 侧 Task 2/3（fixture、主代理临时 daemon 全 App compile-only、断连/并发/原文不落盘
  跨 scope 复验）；本 worker 未启动宿主、无真实模型调用/权重下载、无提交推送。
