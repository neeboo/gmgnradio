# VoiceMem Rust port — coordinator execution evidence

Date: 2026-09-08. Task: task_118662f78b7a4eb8bee2f31af384cb7c.

Result: BLOCKED, not implemented or verified. Approved plan was read in full. No source files were edited by this coordinator. Existing dirty work was preserved. No duplicate worker session, verifier, worktree, commit, or push was created. No runtime/control or global configuration files were changed.

## Actual worker attempts

The initial `dsh --help` and `acpx claude sessions show gmgn-resident-conversation-store-20260908` both exited 127 (`env: node: No such file or directory`). A command-local PATH fixed launcher execution:

```sh
export PATH=/Users/ghostcorn/.nvm/versions/node/v22.19.0/bin:/opt/homebrew/bin:/Users/ghostcorn/.local/bin:$PATH
```

`/Users/ghostcorn/.local/bin/dsh --help` and `/Users/ghostcorn/.local/bin/dsh --profile headless --help` exited 0. An actual headless coding invocation followed with a concrete prompt assigning approved Tasks 1–2, contract publication first, Rust-only ownership, pinned VoiceMem, sqlite-vec, configured providers, temporary database tests and all frozen prohibitions. It exited 1 before implementation:

```
dsh: MISSING_CREDENTIAL: llm-deepseek: no API key for provider route "deepseek-official"; store DEEPSEEK_API_KEY through the credentials service (the web Models page writes it), or export DEEPSEEK_API_KEY in the launching environment
```

No credential store/keychain was accessed or modified. No fallback implementation worker was substituted.

CC commands and results:

- `acpx claude sessions show gmgn-resident-conversation-store-20260908` — exit 0, no named session found.
- `acpx claude status -s gmgn-resident-conversation-store-20260908` — exit 0, `status: no-session`.
- `acpx --agent 'npx -y @agentclientprotocol/claude-agent-acp@^0.36.1' sessions show gmgn-resident-conversation-store-20260908` — exit 0, no named session found.
- `acpx --agent 'npx -y @agentclientprotocol/claude-agent-acp@^0.36.1' cancel -s gmgn-resident-conversation-store-20260908` — exit 0, `nothing to cancel`.
- Actual prompt submission: `acpx --approve-all --timeout 120 claude -s fb59b1d6-d88f-4750-9a01-4bd3c2947e51 <prompt>` — exit 4, `No acpx session found`. Prompt explicitly superseded stale raw-transcript instructions and requested readiness inspection only while the missing DSH contract blocked integration. No prompt was delivered.
- `/opt/homebrew/bin/acpx --version` — exit 0, 0.10.0.
- `/usr/local/bin/acpx --version` — exit 0, 0.4.0.
- `/usr/local/bin/acpx claude sessions show gmgn-resident-conversation-store-20260908` — exit 0, same no-session result.
- `/usr/local/bin/acpx claude cancel -s gmgn-resident-conversation-store-20260908` — exit 0, `nothing to cancel`.

Read-only inspection confirmed saved record fb59b1d6-d88f-4750-9a01-4bd3c2947e51 exists with expected cwd/name and adapter command. Its queue lock records `queueDepth: 0`; this is stored metadata, not proof of live process state. CLI lookup could not resolve it. No queue/session files were edited and no duplicate writer was created.

## Source inspection and acceptance gaps

`ls docs/plans/2026-09-08-voicemem-rust-contract.md` exited 1: contract absent. `AgentConversationService.swift` still declares `residentConversationStore`, `attachConversationStore`, and `persistTurn`; the latter calls `store.recordTurn(scope:userMessage:reply:)` around line 721, with several callsites. This is not evidence that the requested raw-transcript removal is complete.

No fresh Rust tests, Swift tests, or compile-only build were run: no worker implementation was produced. Earlier transcript-scope tests are not counted. sqlite-vec pinning, upstream provenance, snapshot semantics, provider wiring, atomicity and App integration remain unverified. Independent verifier remains separately scheduled by the caller; no duplicate verification task was created.

No App/test host, GPU, model validation/generation, model weights, real user database, AppleScript or system-permission access was performed. Repair cycles used: 0 of 2; failures are executor prerequisites rather than implementation test failures.

Resume requires DSH credentials available to the authorized headless executor and a supported way for acpx to load the existing CC session without creating a duplicate or rewriting global/session configuration. Then dispatch DSH Tasks 1–2, consume its frozen contract in CC, run fresh scoped tests/build, and pass the resulting evidence to the existing verifier.

Additional awaited result: `acpx claude sessions list` attempted ACP initialization and reported `ACP agent exited before initialize completed (exit=1, signal=null)` with npm `ENOTFOUND registry.npmjs.org` for the Claude adapter package. Its surrounding shell completed with exit 0 because subsequent read-only commands succeeded; that shell exit does not indicate adapter success. This adds an observed network dependency blocker to the session lookup failure. Evidence file readback via `wc -l` succeeded (exit 0).

## Prerequisite continuation — task_21e2107a9a684ba2ba15fd0e0eb98291

Result: BLOCKED before dispatch. No implementation source edits, worker substitution, duplicate session/writer, model probe, keychain access, or global configuration changes. Existing pending implementation and verifier tasks should be reused. Implementation repair cycles remain unused by this continuation.

All Node CLI commands below used command-local `PATH=/Users/ghostcorn/.nvm/versions/node/v22.19.0/bin:/opt/homebrew/bin:/Users/ghostcorn/.local/bin:$PATH`. The initial unadjusted `dsh --help` exited 127; adjusted `dsh --help` and `dsh --profile headless --help` exited 0. Headless help exposes task execution and help only, with no credential-status operation. A boolean-only Node environment check reported `DEEPSEEK_API_KEY: unset` (exit 0); no credential contents were read or printed. Stored credential availability is not established. The earlier failed model invocation was not repeated.

Rust prerequisite resolved without changing defaults:

```sh
RUSTUP_HOME=/Users/ghostcorn/.rustup RUSTUP_TOOLCHAIN=1.91.0-aarch64-apple-darwin /Users/ghostcorn/.cargo/bin/cargo --version
RUSTUP_HOME=/Users/ghostcorn/.rustup RUSTUP_TOOLCHAIN=1.91.0-aarch64-apple-darwin /Users/ghostcorn/.cargo/bin/rustc --version
```

Both exited 0: cargo 1.91.0 and rustc 1.91.0. Cargo warned that both user config and config.toml exist and it uses config; neither was changed. The initial unconfigured `rustup toolchain list` returned no installed toolchains, explaining the previous misleading default-toolchain blocker. No implementation tests were run or claimed.

CC CLI diagnostics (each exit 0):

```sh
acpx claude sessions --help
acpx claude sessions show --help
acpx claude sessions list --local
acpx --agent 'npx -y @agentclientprotocol/claude-agent-acp@^0.36.1' sessions list --local
npm cache ls '@agentclientprotocol/claude-agent-acp'
npm cache ls '@zed-industries/claude-agent-acp'
```

Both local session listings returned `No sessions`; both effective cache searches were empty. Read-only, selected-field inspection of the existing user record confirmed acpx record `fb59b1d6-d88f-4750-9a01-4bd3c2947e51`, ACP session `1c2a713b-9296-4663-98ee-e7e7caa0a5c9`, name `gmgn-resident-conversation-store-20260908`, expected repository cwd, `closed: false`, and adapter command `npx -y @agentclientprotocol/claude-agent-acp@^0.36.1`. Saved PID 7332 is metadata only; live queue/process state remains unverified.

Root cause narrowed: Node `os.homedir()` reports `/var/folders/0n/mlts398n6mb3hnzp_q2qsc500000gn/T` in this executor, while the existing session is under `/Users/ghostcorn/.acpx/sessions`. Installed acpx source resolves session storage from `os.homedir()`. Supported CLI help exposes no alternate session-root flag. Current instructions prohibit repurposing HOME and the sandbox does not permit writes under `/Users/ghostcorn/.acpx`; copying/importing a session would risk creating a duplicate and was not attempted.

The exact matching adapter package is already installed at `/Users/ghostcorn/.npm/_npx/a2c7d0c664921561/node_modules/@agentclientprotocol/claude-agent-acp/package.json` (version 0.36.1); its `dist/index.js` entry exists. This establishes local package presence, not successful ACP initialization or authentication. No npm network retry or adapter model invocation occurred.

Required external actions: configure the authorized executor launcher with a non-keychain DSH credential (DEEPSEEK_API_KEY supplied through its environment, never pasted into task evidence), and run CC in a permitted user/session environment that resolves the existing `/Users/ghostcorn/.acpx` record and user npm cache. Grant that executor normal session/queue write access there through its host configuration. Do not create a replacement session. In that environment, inspect the existing session status/queue and supersede any obsolete raw-transcript prompt before dispatch. Then DSH must implement Tasks 1–2 and publish the contract before CC Task 3; use the command-local Rust settings above. Independent verification remains pending.

## Independent verifier prerequisite gate — task_84ce03f6093d4f6aa58ae559c933c800

Date: 2026-09-08. Verdict: BLOCKED; acceptance is not passed. This existing verifier task performed fresh source inspection, but implementation-dependent verification remains pending. The prerequisite continuation above reports no DSH or CC implementation artifacts and unresolved authorized-executor configuration. No worker was substituted and no repair cycle was consumed (implementation repairs remain 0 of 2).

Fresh command evidence (exit codes are command outcomes, not acceptance results):

- `cat docs/plans/2026-09-08-voicemem-rust-port.md docs/plans/evidence/2026-09-08-voicemem-rust-port.md` — exit 0. Read frozen acceptance and actual failed-worker provenance; no successful implementation handoff exists in this evidence.
- `rg --files ...` — exit 127, rg unavailable; used find/grep instead.
- `find . -name AGENTS.md -not -path './.ouroboros/*' -not -path './.orbs/*' -not -path './.git/*' -not -path './node_modules/*'` — completed; only dependency-checkout instructions found. Combined inspection shell ended exit 1 on the missing-contract test below.
- `cat services/gmgn-taskd/Cargo.toml` and `ls services/gmgn-taskd/src` — completed in that shell: existing rusqlite 0.32/bundled, no sqlite-vec dependency or focused memory module.
- `test -f docs/plans/2026-09-08-voicemem-rust-contract.md` — exit 1: contract absent.
- `grep -nE 'sqlite[-_]vec|voicemem|VoiceMem|memory_(read|commit|query)' services/gmgn-taskd/Cargo.toml services/gmgn-taskd/Cargo.lock services/gmgn-taskd/src/*.rs` — exit 1, no matches. A broader earlier search including `watermark` exited 0, but found existing event/message pagination only; these are not compact-input watermark evidence.
- `grep -nE 'persistTurn|recordTurn|attachConversationStore|residentConversationStore' apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` — exit 0. Persistence helper remains at line 712, recordTurn at 720, and reply callsites at 1112, 1154, 1191, 1223, 1253.
- `sed -n '120,185p' apps/macos/Sources/GMGNRadio/Agent/ResidentConversationStore.swift` — exit 0: recordTurn retains user/reply text as StoredMessage objects and starts asynchronous commit draining. Source-wide attachConversationStore search found its declaration only; actual attachment/runtime execution is not established. Therefore no claim is made that a real database was written, but required removal of persistence invocations is demonstrably incomplete.

Frozen acceptance disposition:

| Requirement | Independent disposition |
| --- | --- |
| DSH Rust ownership / CC integration provenance | Blocked: recorded attempts did not produce implementation; no successful worker handoff to verify. |
| Frozen additive IPC and preservation of existing contracts | Failed prerequisite: frozen contract absent. Fresh old-contract regressions pending implementation. |
| Snapshot dual categories, bounded entries, correction/removal, exact details and no inferred personality | Unverified: required implementation artifacts absent. |
| Atomic snapshot/vector consistency, revision/replay, scope isolation, commit-after-durability watermark and cancellation/late completion | Unverified: existing pagination watermarks do not satisfy these requirements. |
| Pinned static CPU sqlite-vec, license/notices, VoiceMem source provenance/deviations | Failed prerequisite: sqlite-vec absent from manifest/lock; port notices/source provenance cannot be accepted without the port artifacts. |
| Vector cosine ranking, filter-before-top-k, invalid vectors/model/dimensions, update/delete/restart and context bounds | Unverified: required vector implementation absent. |
| Configured compaction/embedding providers, deterministic fixtures, explicit unavailable status and no tools | Unverified: no port provider artifacts supplied. |
| No durable raw transcript; successful delivered text only; fresh/resumed context; background compaction and world/cancellation callsites | Incomplete: old persistence invocations remain; required CC integration absent. |
| Fresh CPU Rust and temporary-daemon regressions, offline Swift tests and compile-only checks | Not run: gated on actual DSH/CC implementation as instructed. Earlier results are not counted. |
| Execution restrictions and repair limit | Preserved by this verifier: inspection and this evidence append only; no App/test-host launch, keychain, real database, GPU, model call/download, commit/push, runtime-control edit, worker dispatch or repair. |

Remaining manual checks after implementation and deterministic acceptance: real provider semantic quality (factual fidelity, grounded relationships, correction/removal and retrieval relevance), and explicitly authorized runtime interaction. No model-quality or runtime validation was performed or claimed. Resume this verifier after the existing DSH and CC tasks supply their artifacts; do not treat this prerequisite inspection as completed port verification.
Tue Sep  8 09:44:02 CST 2026

---

# Swift Task 3 worker attempt — task_ea78f81382974968953814fe8832bc86

Date: 2026-09-08. Role: worker (DSH native executor, deepseek-harness). Owns Swift-only
integration per approved plan Task 3 + parallel amendment (Rust DSH task owns Rust/contract;
I must not touch Rust or the contract document). This append documents a BLOCKED attempt caused
by the same external sandbox policy-translation defect the parallel Rust worker recorded in
`docs/plans/evidence/2026-09-08-voicemem-rust-core.md`.

## Result: BLOCKED (repo write denied for every allowed Swift path; toolchain also cannot run)

No Swift source, test, tool or project file was created, edited or deleted. Existing dirty tree
(apps/macos/**, tools/**, docs/plans/**) was inspected and preserved; inbox/storage/WorldRuntime
work untouched. No App/test-host launch, keychain, real user database, model probe/weights,
commit/push, or runtime/control-path change was made. The single repo modification from this
attempt is this evidence append.

## Blocker (exact, external configuration; reproduced)

The executed DSH seatbelt profile for this run renders every task allowedPath as a `literal`
entry rather than `subpath`. Active profile
`/Users/ghostcorn/.ouroboros/runtime/dsh-process-policies/564e3db8-2661-49aa-9316-e48590682268/runner.mjs`
line 5 contains (among others):

```
(allow file-write* (literal "/Users/ghostcorn/dev/gmgnradio/apps/macos/Sources/GMGNRadio/Agent"))
(allow file-write* (literal "/Users/ghostcorn/dev/gmgnradio/apps/macos/Tests"))
(allow file-write* (literal "/Users/ghostcorn/dev/gmgnradio/tools"))
(allow file-write* (literal "/Users/ghostcorn/dev/gmgnradio/docs/plans/evidence/2026-09-08-voicemem-rust-port.md"))
```

`literal` matches only the directory path itself, so no file under Agent/Tests/tools is writable.
Only the exact evidence file path is writable. Reproduced commands (exit codes are outcomes):

```sh
printf '// probe\n' >> apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift   # exit 1 Operation not permitted
cat > apps/macos/Sources/GMGNRadio/Agent/ResidentConversationMemory.swift                  # exit 1 Operation not permitted
printf '// probe\n' >> apps/macos/Tests/GMGNRadioTests/Agent/AgentConversationServiceTests.swift  # exit 1
printf '// probe\n' >> apps/macos/GMGNRadio.xcodeproj/project.pbxproj                     # exit 1
printf '' >> tools/test-resident-state-client.swift                                       # exit 1
printf '' >> docs/plans/evidence/2026-09-08-voicemem-rust-port.md                         # exit 0 (allowed literal)
touch apps/macos/Sources/GMGNRadio/Agent/.probe                                            # exit 1
mkdir -p apps/macos/Sources/GMGNRadio/Agent/.probedir                                     # exit 1
xcrun swiftc --version                                                                    # exit 1: couldn't create cache file /var/folders/.../xcrun_db-... (Operation not permitted)
```

File creation and truncation are also denied (only append to an existing allowed-literal file
works). The Swift 6.3.3 toolchain cannot even create its `xcrun` cache under /var/folders, so
even `swiftc -parse` focused checks are impossible in this sandbox. Escalation is unavailable:
retrying with `sandbox_permissions=danger-full-access` returned "requires approval, but no
approval channel is available"; `workspace-write` was rejected as not strictly wider than the
current mode. The denial is final for this run.

## Freeze appeared mid-work (adaptation target now concrete)

While this attempt was in progress the parallel Rust DSH worker published the frozen additive
contract at `docs/plans/2026-09-08-voicemem-rust-contract.md` (346 lines, verified `wc -l` exit
0, mtime 09:40). It defines exactly the seven additive methods the Swift adapter must bind:
`memory_configure / memory_status / memory_read / memory_query / memory_turn / memory_pending /
memory_compact`, scoped versioned snapshot `facts`+grounded `notes` sections, volatile per-scope
pending turns with commit-after-durability watermark semantics, atomic snapshot/vector
`vectorGeneration`, per-scope sqlite-vec cosine partitions (scope-filter before top-k), explicit
`unconfigured`/error statuses, credential hygiene, and the stable error table. No adaptation was
possible in this sandbox; the pending binding list is fully determined below so the next run with
a writable profile can land it directly. Rust side still shows no repo core (BLOCKED): 
`services/gmgn-taskd/src/` remains `daemon.rs files.rs main.rs messages.rs model.rs provider.rs
resident.rs store.rs`, `Cargo.toml`/`Cargo.lock` contain no sqlite-vec, daemon dispatch has no
`memory_*` methods, and no `memory` module exists.

## Fresh inspection facts (read-only)

Durable raw-transcript path is still active and is exactly the code this task must remove/adapt:

- `apps/macos/Sources/GMGNRadio/Agent/ResidentConversationStore.swift` (untracked, 353 lines):
  `restoreContext` at :97 calls `stateRead(domain:.conversation, key:"transcript")` (:101);
  `recordTurn` at :127; `attemptCommit` `stateCommit(domain:.conversation, …)` at :250 and
  read-back at :204. It stores raw user/agent text durably in the conversation domain.
- `apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`: property
  `residentConversationStore` ~:484; `attachConversationStore` :635; durable `restoredContext`
  :669–696 (reads `store.restoreContext` :674); `freshDSHHistory` :697–711; `persistTurn` :712–720
  (`store.recordTurn` :720); call sites at :1112 :1154 :1191 :1223 :1253; `durableUserText`
  derivation ~:1062; `conversationStorageScope` on `ResidentWorldContext` ~:139.
- App runtime never attaches the durable store: `attachConversationStore` callers are only tests
  (`apps/macos/Tests/GMGNRadioTests/Agent/AgentConversationServiceTests.swift` :792 :838 :859 :899
  :935 :952 :978 :1002 :1046) and `tools/test-resident-conversation-storage.swift` (compiles
  ResidentStateClient.swift + ResidentConversationStore.swift, real temp-daemon conversation-domain
  checks). `ResidentConversationStore` is referenced only by those four files; it is NOT in the
  Xcode project (pbxproj references it 0×), so the app/test targets are currently inconsistent
  until projectgen adds/removes files.
- `apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift`: `ResidentStateTransport` JSON
  frame protocol (:43), `ResidentStateDomain` incl. `.conversation`, five frozen state methods,
  `ResidentStateJSON` tree, strict integer/object helpers, error passthrough — the natural host
  for additive memory methods (no memory methods present yet).
- `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`: `residentMemoryStore` (ResidentMemoryStore,
  resident-domain plan store) at :574 bound to loop at :3509; `ResidentSystemInboxStateStorage` at
  :4038; no conversation-store wiring to change.
- Existing store tests that must be rewritten to volatile-memory/feed semantics (test names):
  `successfulResidentTurnIsPersistedPerWorldScope`, `freshCodexSessionRestoresStoredContextOnlyWhenNoNativeThread`,
  `dshFreshProcessSeedsHistoryFromStoreAndPersistsTurns`, `failedOrCancelledTurnNeverPersists`,
  `plainChatWithoutWorldOrWithoutUserTextNeverPersists`, `toolSessionPersistsUnderToolsScopeWithExplicitUserMessage`,
  `conversationSaveFailureIsVisibleThroughServiceHandler`, plus stub `ConversationDaemonStub`.

## Swift integration blueprint (apply-ready for the next writable run; pending bindings listed)

1. Delete `ResidentConversationStore.swift`; remove `attachConversationStore/restoredContext/
   freshDSHHistory(with durable read)/persistTurn` durable paths from `AgentConversationService.swift`.
   Keep only delivered-turn gating (real user text or explicit tool `userMessage`; success-only,
   scope-captured, non-empty trimmed).
2. New `ResidentMemoryClient.swift` over `ResidentStateTransport` binding the frozen contract:
   `configure(kind:endpoint:token:model:)`, `status(scope:)`, `read(scope:)`, `query(scope:query:
   topK:)`, `appendTurn(scope:role:text:interrupted:)`, `pending(scope:)`, `compact(scope:
   requestID:expectedVectorGeneration:)`; value types mirroring snapshot/pending/status JSON;
   strict parsing; new error passthrough (existing `.daemon(code)` already carries the frozen
   codes incl. `memory_conflict`, `compaction_unavailable`, `embedding_unavailable`,
   `embedding_dimension_mismatch`).
3. New `ResidentConversationMemory` adapter (replaces the durable store): volatile staged
   delivered turns (bounded, scope-keyed) feeding `memory_turn`; `memory_read` only on genuinely
   fresh session (no native thread AND empty process history) with bounded snapshot context
   injection (no re-inject on native resume / non-empty in-process DSH history); bounded
   `memory_query` retrieval with app length budget; `memory_compact` scheduled on a background
   Task that must never block a reply; `memory_status` surfaced explicitly for missing
   providers/binding, chat unaffected. PENDING BINDING: none beyond the frozen contract above —
   wire names are now final; only the sandbox blocks landing.
4. Projectgen: add the two new files to Agent group + GMGNRadio sources build phase in
   `apps/macos/GMGNRadio.xcodeproj/project.pbxproj` (same manual entry pattern as
   `ResidentMemoryStore.swift`; the durable store was never added so deletion needs no removal).
5. Rewrite the seven store tests above around a fixture `ResidentMemoryTransport` (assert zero
   conversation-domain `state_commit`, feed-only-on-success, fresh-once/resumed-never injection,
   unconfigured visible, scope isolation). Replace `tools/test-resident-conversation-storage.swift`
   with an offline `tools/test-resident-memory-client.swift` (fixture transport; real temp-daemon
   regression only after the Rust core lands memory methods).
6. Validate with focused `swiftc -parse`/offline tool tests and compile-only build (no App/test
   host, no full build while Rust task builds). None of these ran here: toolchain and filesystem
   are both blocked.

## Required external action

Re-run this Swift worker under a DSH process policy whose file-write profile uses
`(subpath "/Users/ghostcorn/dev/gmgnradio/apps/macos/Sources/GMGNRadio/Agent")`,
`(subpath ".../apps/macos/Tests")`, `(subpath ".../tools")`, and literal paths for
`GMGNRadio.xcodeproj`, `GMGNRadioApp.swift` and this evidence file (i.e. translate the task
allowedPaths as subpaths like the sibling pancat profiles), or provide an approval channel for
`danger-full-access` escalation. The frozen contract and this blueprint are ready; the next
attempt needs only the writable sandbox to implement and test the Swift integration.

(The single `Tue Sep  8 09:44:02 CST 2026` line above this section is an accidental probe
timestamp appended while testing that only this evidence path is writable; it carries no
content and is left as-is because truncation is not permitted in this sandbox.)

---

# Swift Service 记忆接线完成 — task_<swift-service-memory-wiring>

Date: 2026-09-08. Role: Swift owner (replacement for the stopped PID32283 run). Scope:
`AgentConversationService.swift` 记忆接线 + 对应测试（编排文档 Task 2 的 recall/ingest
约定）。只读参考了 `docs/plans/2026-09-08-voicemem-rust-orchestration.md` Task 2 与
memory_recall/memory_ingest 约定；未读其它研究材料、未做新计划。未触碰 Rust /
ResidentMemoryClient.swift / ResidentStateClient.swift / ResidentConversationMemory.swift
（这些由既有工作与 Rust/契约 DSH 提供，本轮保持只读），未触碰 App / AgentSpeech /
工程文件 / Presence / Inbox，未改任何 DSH 协议方法。

## 实际完成（源码已改）

1. `AgentConversationService.swift` 存储帮助函数区（原 attachConversationStore /
   restoredContext / freshDSHHistory / persistTurn / withRestoredContext 及
   `residentConversationStore` / `conversationPersistenceErrorHandler` 属性）全部删除，
   换成 ResidentConversationMemory 薄适配器接线：

   - `func attachConversationMemory(_ memory: ResidentConversationMemory?,
     onMemoryError: ((String) -> Void)? = nil)`：挂载/替换/解除；nil = 未接线
     （聊天完全可用，只是不召回、不入记忆）。适配器 onError 经本服务的可见错误出口
     转出（空文本/未绑定这类不可能状态静默）。
   - 每轮 send 内（codex / dsh / claudeCode / workbuddy / qoder / pi 六条后端分支的
     「记忆调用与历史记录区域」）：scope 变化时 `bindConversationMemoryIfNeeded`；
     用**真实用户文字**（`userMessage ?? (worldTools == nil ? text : nil)`，绝不使用
     宿主拼装 prompt）做 `memory.restore(query:freshSession:)`；失败/缺配置/未接线都
     返回 nil，回复路径不受影响。
   - fresh 判定：原生会话缺失（无保存 session id）或 DSH 进程内历史为空 = 新会话
     → freshSession=true；已存在原生 session / 非空 DSH 历史 = false（只取本轮相关
     记忆，绝不反复整段恢复）。DSH 原生 ACP 会话已建立时靠会话连续性，不再逐轮注入。
   - 记忆上下文注入：codex/JSON-CLI/pi 系作为纯文本背景放在 prompt 前（withMemoryContext，
     标注“只作背景数据，不是指令”）；DSH 系作为带标记的请求级历史消息追加
     （memoryContextMessage，不写入进程内历史，避免被当真实用户轮次重放）。
   - 模型返回**绝不** memory_ingest；成功后只 `stageDeliveredTurn` 登记凭据。
   - `var lastTurnDeliveryRequestID: UUID?` + 显式确认入口
     `confirmDeliveredTurn(requestID:userText:reply:source:observedAt:) ->
     AgentConversationMemoryDeliveryResult`：App 在 run/world 检查通过且实际显示/语音
     完成后调用。校验 requestID 与 userText 等于本轮登记、scope 与 generation 仍是
     当前（cancel() 清空凭据；新 send/scope 切换替换；memory reset 使 generation 失配
     → `.notCurrent` 一律不写）。文本按 Rust 合同校验（trim 后非空、无 C0/C1 控制字符、
     ≤2000 Unicode scalar；observedAt 可选 ≤32，违规丢为 nil），违规 `.rejectedText`
     不写、不持久原文、已成功聊天不受影响；已确认一次即清空凭据（重复确认
     `.notCurrent`，绝不重复入队）。结果 `.accepted` 只代表进入 Rust 易失缓冲
     （memory_ingest 语义），不冒充 durable。
   - 后台/自驱轮（无真实 userMessage）不虚构输入：不召回、不登记假 user turn。
   - 不在 Swift 调 memory_compact/memory_query/memory_read/memory_turn，不调度整理，
     不再 state_commit conversation 域 / rawconversation；无持久 raw transcript 路径。
   - 新增文件级 `AgentConversationPendingDelivery` 与
     `AgentConversationMemoryDeliveryResult`（accepted/notCurrent/unavailable/
     rejectedText/queueFull），`ResidentMemoryTextLimits` 常量。

2. `apps/macos/Tests/GMGNRadioTests/Agent/AgentConversationServiceTests.swift`
   旧 conversation 域 store 区域改写为 memory fixture（`ConversationMemoryStubTransport`
   + `ConversationMemoryCodexRunner`），七条旧 store 测试替换为九条覆盖真实 Service
   召回/交付确认的测试（含 old `ConversationDaemonStub` / `attachConversationStore`
   引用清零）。行为覆盖（见下），使用内存 fixture transport，纯编译、不启 App。

3. 新增离线工具 `tools/test-agent-conversation-memory-service.swift`（真实
   AgentConversationService.swift + ResidentStateClient/ResidentMemoryClient/
   ResidentConversationMemory + fake backend/transport 编译运行，非 sourcegrep）。
   `tools/test-resident-dsh-world-loop.swift` 与 `tools/test-living-resident-loop.swift`
   的离线编译源清单各补入 ResidentMemoryClient.swift / ResidentConversationMemory.swift
   （AgentConversationService 现依赖它们），无行为改动。

## 真实离线测试命令与退出码（fresh，本轮实跑）

```sh
cd /Users/ghostcorn/dev/gmgnradio
swift tools/test-agent-conversation-memory-service.swift
# PASS: 61 agent-conversation memory service checks, 0 failures   (exit 0)

swift tools/test-resident-conversation-memory.swift
# PASS: 97 resident conversation memory checks, 0 failures        (exit 0, 适配器回归保留)

swift tools/test-resident-dsh-world-loop.swift
# PASS: 21 offline DSH reasoning priority cases / PASS: 118 DSH world-loop checks, 0 failures (exit 0)

/usr/bin/swiftc -typecheck -swift-version 6 -j1 CodexCLI AgentConversationService \
  ResidentCodexTransport ResidentCodexPolicy ResidentCodexAgent ResidentSteeringDelivery \
  ResidentDSHTransport ResidentDSHConfiguration ResidentStateClient ResidentMemoryClient \
  ResidentConversationMemory (…/Agent/*.swift) + Presence/ResidentVisionCapture.swift
# exit 0（无输出）
```

工具 `tools/test-living-resident-loop.swift` 的编译源清单已同步补齐，但本沙箱无法执行：
其编译需要 `/Applications/Xcode…/swift-plugin-server`（@TaskLocal 外部宏），被
`sandbox-exec: sandbox_apply: Operation not permitted` 拦截——环境限制，非代码回归，
主代理可在非沙箱环境跑 compile-only 复核。

## 行为覆盖矩阵（Service 层，全部真实编译+运行断言）

- 每轮 recall query = 真实用户文字（显式 userMessage / 无 worldContext 只读聊天
  text），不是宿主 prompt（工具轮次断言 query==userMessage 且 ≠ 组装 prompt）。
- fresh/resume：无原生线程或空 DSH 历史 → memory_recall freshSession=true；有原生
  session / 非空 DSH 历史 → false；每轮一次。
- 模型返回后无任何 memory_ingest；App 显式确认后才入队且恰一次（重复确认 notCurrent，
  不入第二笔）；source=voice 透传；scope 内嵌对象 worldID 正确。
- 取消 / 迟到成功：不 stage、确认 notCurrent、零 ingest。
- scope 切换（world A→B）与 memory reset：旧 requestID 确认 notCurrent、零 ingest。
- 未接线记忆 → confirm .unavailable、聊天可用；召回失败 → 错误经
  onMemoryError 可见、聊天照常返回；无 worldContext 普通聊天不绑定/不召回/无凭据。
- 后台/自驱轮（无真实输入）不召回、不登记假 user turn。
- 合同文本校验：控制字符（含 reply 内 \n 与 userText 内 U+0001）/超 2000/空文本 →
  .rejectedText、零 ingest、不持久原文；同一 requestID 修正后重试仍可 .accepted 且恰一次。
- DSH 请求级记忆背景不进进程内历史；续聊轮历史与请求级上下文并存。

## App 后续接线需改的旧调用点（本轮未改 App，报告给主代理）

- `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` `performResidentTurn(_:)`
  ~:4603 的 `AgentConversationService.shared.send(prompt…, imageURLs:, worldContext:,
  worldTools:, onCancel:)`：当前未传 `userMessage:` → 工具/后台轮真实用户文字为 nil，
  记忆不会召回/登记。下一阶段应给前台轮传真实人类输入（如 `input.userMessages`），
  后台轮保持 nil；在 ~:4611-4618 的 run/world 检查通过、回复实际显示或语音播完后，
  调用 `AgentConversationService.shared.confirmDeliveredTurn(requestID:
  AgentConversationService.shared.lastTurnDeliveryRequestID, userText:…, reply:…,
  source:.text/.voice)`。
- App 启动/bootstrap 处应一次性
  `AgentConversationService.shared.attachConversationMemory(ResidentConversationMemory(
  transport: <gmgn-taskd memory transport>))`（未接线时服务自动退化为纯聊天，无记忆）。
- `ResidentConversationStore.swift` 与 `tools/test-resident-conversation-storage.swift`
  现只互为引用（conversation 域旧 raw 持久化路径），Service/App/测试均已不再调用；
  建议主代理后续删除该文件与工具（冻结合同已由 Rust memory_ingest 易失缓冲取代）。

未运行：App/test-host、GPU/系统授权/钥匙串、真实 daemon/用户库、模型测试；
未 commit/push；未改动其它 DSH 的新 Bridge/HostTools 模块。真实语音/模型质量验证留待
主代理整合阶段。

---

## 2026-09-08 第三阶段：实际 App 记忆接线 + Service 原生续聊修复（DSH 接手 owner）

前一段落「App 后续接线需改的旧调用点」所建议的 App 接线已在本阶段实际完成（下文
「实际交付」），不是只交 client/建议。范围遵守：不改 Rust、不改他人文件
（AgentSpeech.swift、ResidentDSHHostToolsBridge.swift/原生插件、ResidentAgentLoop 核心、
Presence）、未触碰真实 token/钥匙串/UserDefaults/真实数据库、未启 App/test-host、
未做全 App build（主代理最终 compile-only）。

### 1. Service 明确问题修复：DSH 原生 ACP 续聊不再跳过每轮召回

`apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`

- `dshHistoryForTurn`（现 ~:769）：删除上一 worker 自行缩减的
  `guard !nativeSessionAlreadyOpen` 整段跳过。该函数保留为 **headless DSH** 的
  请求级历史组装（记忆作为一条背景消息追加在请求历史末尾，不进进程内历史）。
- `.dsh` 原生分支（~:1306-1340）：原生 ACP 会话续聊由会话自身保持真实历史，
  `sendViaDSHNative` 的续聊会丢弃 bootstrap history，因此原生分支改为每轮直接
  `recalledContext(query: durableUserText, freshSession: isFreshSession &&
  !nativeSessionAlreadyOpen)`，召回上下文经 `withMemoryContext` 进入**本轮
  submit 的增量 prompt**（blocks 文本），不再挂在会被续聊丢弃的历史里。
  freshSession=true 只限真正新会话（进程内历史为空且原生会话尚未建立）；已有
  原生会话续聊 freshSession=false，只取本轮相关记忆、绝不整段恢复历史。未改写
  DSH 工具协议/传输；其它后端（codex/pi/claudeCode）路径未动。

离线验证（native transport fake 两轮）见工具第 10 场景：两次真实召回、第二次
freshSession=false、新相关上下文进入第二次 submit 的 prompt、首轮的整段恢复段不
重复出现。`tools/test-agent-conversation-memory-service.swift` 检查数 61→79 全过。

### 2. App 实际接线（apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift）

- 属性（~:588-628）：`residentConversationMemory`（薄适配器，transport 复用
  `ResidentTaskDaemonStateTransport(client: PropTaskDaemonClient())`，与居民计划
  residentMemoryStore 同一 taskd 生命周期，不开新服务）、`ResidentMemoryTurnSlot`、
  配置轮询节流/提示去重/进行中防重、`residentTurnSourceByRunID`（最小
  runID→source 绑定）、`residentMemoryTurnSlot`（待交付凭据）。
- `configureResidentConversationMemory()`（~:3555）：启动一次性 attach 到
  `AgentConversationService.shared` 并给可见错误出口，随后立即发起首次配置核对。
  在 `applicationDidFinishLaunching` 调用。
- `refreshResidentMemoryConfigurationIfNeeded()` / `applyResidentMemoryConfigurationIfNeeded()`
  （~:3568/3582）：搭既有 5 秒定期刷新、30 秒节流 + in-flight 防重；每次读
  `memory.configurationStatus(scope:)`（新增只读转发，见
  `ResidentConversationMemory.configurationStatus(scope:)`），daemon 重启后
  `configured=false` 时按显式环境变量重新 `memory_configure`（compaction +
  embedding），不是只启动配一次；缺/错配置有去重可见提示且聊天不受影响；不新增
  高频模型/compact 调度；不读钥匙串、token 只作请求参数转发、不写 UserDefaults。
- `performResidentTurn`（~:4800-4833）：真实用户文字只取 `input.userMessages`
  （`input.promptText` 是宿主 prompt，严禁入库）；`send(…, userMessage: realUserText,
  …)`；后台/自驱轮无真实输入时 realUserText=nil（不虚构回合）。在既有 run/world/
  当前引用守卫（liveCamMessageID==messageID、isCurrent、sessionScope/worldID、
  `livingWorldContext === requestWorld`）**全部通过后**才
  `registerResidentMemoryTurn(runID: messageID, realUserText:reply:)` 登记该次
  `lastTurnDeliveryRequestID`+userText+reply+source。
- `registerResidentMemoryTurn`（~:3650）：requestID 来自
  `AgentConversationService.shared.lastTurnDeliveryRequestID`；source 来自 runID 绑定
  （voice/text，缺省 .text）。
- `sendLiveCamMessage`（~:4147）：语音最终转写入口在它真的启动一个新人类轮次
  （runID 变化且非后台）时绑定 `.voice`；键盘入口走 `sendResidentSubmission` 缺省
  `.text`。不改 ResidentAgentLoop 核心/Presence。
- `presentResidentReply` / `confirmResidentMemoryTurn`（~:3670/3692，接 ensureResidentLoop
  的 onReply）：先同步写 LiveCam/Stage 聊天表面，再按 autoSpeak 决定确认时机。
  autoSpeak 开启只认整段语音自然播完（`announce(_:completion:)` `.finished`；
  AgentSpeech.swift 交付回调由并行语音 owner 提供，本阶段只消费其现有签名，未
  改动该文件）；取消/失败/停止/世界切换/迟到回调不确认。静音文本以「至少一个
  显示表面真实存在并显示」为交付；只调用显示 API 但 controller 全 nil 不记为已
  显示。模型返回/语音启动成功本身都不触发 ingest。onCancel（停止）清
  `residentMemoryTurnSlot`，`service.cancel()` 侧凭据也随之失效，迟到确认返回
  `.notCurrent` 不写。
- 新增 `apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryConfiguration.swift`：
  `ResidentMemoryEnvironmentConfiguration` 只读解析
  `GMGN_MEMORY_COMPACTION_ENDPOINT/TOKEN/MODEL` 与 `GMGN_MEMORY_EMBEDDING_*`
  （trim 后为空视为缺失）；不触发钥匙串、不写 token 日志/UserDefaults，token 只
  作为 memory_configure 请求参数转发。

### 3. 清理与既有测试修正

- 删除 `apps/macos/Sources/GMGNRadio/Agent/ResidentConversationStore.swift` 与
  `tools/test-resident-conversation-storage.swift`（删除前 rg 确认二者只互为引用；
  无其它 Swift/工具/工程引用；冻结已由 Rust memory_ingest 易失缓冲取代）。
- `tools/test-resident-state-daemon.py:557` 版本 assert 2→3（VoiceMem 记忆编排新增
  一条 schema migration），保留其余旧状态/消息断言（revision 1/replayed False、
  event 1 条、resident_states 1 行）不动。该文件需真实临时 Rust daemon，本沙箱未执行。

### 4. 真实离线测试命令与退出码（本轮 fresh 实跑）

```sh
cd /Users/ghostcorn/dev/gmgnradio
swift tools/test-agent-conversation-memory-service.swift   # PASS: 79 …, 0 failures
swift tools/test-resident-conversation-memory.swift        # PASS: 97 …, 0 failures
swift tools/test-resident-conversation-memory-app.swift    # PASS: 15 …, 0 failures (新)
swift tools/test-resident-loop-app.swift                   # PASS: app guidance …
swift tools/test-resident-dsh-world-loop.swift             # PASS: 21 … / PASS: 118 …, 0 failures
xcrun --sdk macosx swiftc -parse apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift   # exit 0
/usr/bin/swiftc -typecheck -swift-version 6 -parse-as-library \
  apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryConfiguration.swift               # exit 0
```

新增 App 门测试 `tools/test-resident-conversation-memory-app.swift`：从真实
GMGNRadioApp.swift 提取（非重写）`registerResidentMemoryTurn`/`presentResidentReply`/
`confirmResidentMemoryTurn` 方法体，用 fake 记忆/语音/显示编译运行，行为覆盖：
userMessage/source（voice 随 runID 绑定透传）、显示/语音完成前无 ingest、成功一次、
stop/failure 迟到完成不写、无显示表面不记为已显示、autoSpeak 只认 .finished、
语音成为唯一交付通道时可交付。Service 层的每轮召回/缺配置/原生续聊/fresh 语义由
79-check service 套件覆盖（新增 DSH 原生 ACP 两轮场景 + 缺配置可聊场景）。

### 5. 外部未验证范围（诚实报告）

- 未做全 App 编译/build：主代理最终 compile-only（新增文件需 xcodegen 同步，属
  主代理收尾职责；project.yml 用目录 glob，新增文件会随同步进入 target）。
- `tools/test-living-resident-loop.swift` 在本沙箱仍因 @TaskLocal 外部宏
  （swift-plugin-server）被环境拦截，与上阶段结论一致，非本轮代码回归；主代理可
  非沙箱复核。
- `tools/test-resident-state-daemon.py` 需真实临时 Rust daemon，未在本沙箱执行
  （Rust 已交付、接口冻结，主代理统一跑）。
- 真实语音朗读/转写、真实模型质量、daemon 真实 provider 配置未验证；accepted/
  pending 只代表 Rust 易失缓冲，不宣称 durable。
- 未 commit/push；未触碰 Rust、AgentSpeech.swift、ResidentDSHHostToolsBridge.swift/
  原生插件、ResidentAgentLoop 核心/Presence。
