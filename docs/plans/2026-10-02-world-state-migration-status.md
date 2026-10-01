# 世界状态迁移状态：`state.json` → Rust world authority

日期：2026-10-02　状态：**S0 + S1 + S3 已落地并验证；S2 明确跳过（见 §5）**

设计依据：`docs/plans/2026-10-02-rust-world-authority-and-mcp.md`（本仓）。
本文只记录**这次实际做了什么、证据在哪、现在还有没有第二份真相、出事怎么退**。

---

## 1. 一句话

`gmgn-taskd`（Rust，`services/gmgn-taskd/src/world.rs`）是**世界状态的唯一权威与唯一写入方**；
Swift 启动时从权威读快照，之后由事件推进本地投影，写路径只发**带 `expectedRevision` + `requestID` 的意图**；
`state.json` 降级成**只读预像**（一次性导入 + 出事回滚），Swift 侧不再有世界状态持久化路径。

## 2. S0：只读勘察 + 导出 + 等价性比对（已完成）

工具：`tools/world-migration/world_state_migration.py`（`export | canonicalize | compare`）
测试：`tools/world-migration/tests/`（17 项，`python3 -m unittest discover -s tools/world-migration/tests` → `OK`）

真机导出（**只读**，不改/不删任何 live 文件）：

```
$ python3 tools/world-migration/world_state_migration.py export
EXPORT backups/world-state-migration/20261001T061021Z
bundleSha256 3354a01798982e3d261a90153a6e16bfbc300cdafbdb324fd6b169842e105790
files 7 worlds 3 unreadable 0
world 84503420-3010-4944-8fde-2f383cd08ebe current=state/marble-living-cabin/1.2.0/state.json sha256=180f6e7c... objects=2 layoutRevision=16 revision=6965564 historical=2
world gmgn-living-pod-v1 current=state/living-pod-v1/1.0.0/state.json sha256=46d12502... objects=0 layoutRevision=None revision=2895 historical=0
world world-labs-example-warm-kitchen current=state/warm-kitchen-canary/1.3.0/state.json sha256=e6a12e20... objects=0 layoutRevision=None revision=2505444 historical=2
```

"当前是哪一个文件"按**应用自己的口径**判定：`<packageID>/<bundled world.json 的 packageVersion>/state.json`。
同世界的旧版本文件与 legacy 根文件照样导出（回滚要用），但**不是迁移输入**。

比对器不是整文件字节比较（JSON 键序不是语义），只做两处**写明**的归一化：对象键序无关；
`metadata["gmgn.generated-prop.v1"]` 这个"字符串里套 JSON"的 blob 按解析后的内容比较（并在报告里点名）。

## 3. S1：Rust 权威（已完成）

`services/gmgn-taskd/src/world.rs` + schema 第 4 步 `world-authority-v1`：

| 表 | 作用 |
| --- | --- |
| `world_records` | 一条记录一行：`(worldID, domain, key)` + 自己的 `revision`/`hash`/`tombstone`/`updated_by`/`updated_at`（§7.1 记录形状） |
| `world_requests` | `(worldID, requestID)` + 请求内容 hash + 记录下来的回执（幂等回放 / `request_id_conflict`） |
| `world_facts` | 追加即事实：全局 `seq`、幂等键 `id`、`subject`、`revision`、`payload`、`producer` |
| `world_cursors` | 每消费者游标（`world/ui/agent/cloud/mcp`），只增不减 |
| `world_blobs` | 内容寻址大文件：`sha256` 主键 + bytes/mime/local/remote，**字节不进记录行** |
| `world_imports` | 一次性导入标记（`world_id` 主键 + 预像 sha256 + 落库 revision/seq） |

操作集（都在这一个事务里）：`replaceState | setWorldFacts | upsertObject | deleteObject | advanceCursor`。
**类型化事实由"记录前后 diff"派生**（`object.registered/placed/resized/withdrawn/enabledChanged/removed`
+ `world.stateCommitted` + `world.imported`），所以 Rust **没有**重写 Swift 的摆放/尺寸规则——
Swift 仍然决定"下一份文档长什么样"，Rust 决定"什么是真的、什么时候变了、谁还能写"。

daemon 方法：`world_snapshot / world_commit / world_import / world_facts_read / world_records /
world_cursors / world_blob_put / world_blob_get / world_subscribe`。
**G1 已补**：`state_commit` 与 `world_commit` 成功后都 `send_modify`（此前全仓只有两处 notify，
状态写入完全没有推送）。

导入是**按内容幂等**的：同一份预像再导一次（哪怕换 requestID）只回放，不产生第二份。
`world_import` 先校验 `sha256(stateJson) == stateSha256` 再解析——被改过/截断的预像进不来。

### 证据（本机真跑）

```
$ cargo test --locked --manifest-path services/gmgn-taskd/Cargo.toml
test result: ok. 112 passed; 0 failed

$ gmgn-taskd world-import --root <tmp> --bundle backups/.../worlds.json
  84503420-...  imported True revision 1 seq 1 objects 2 contentSha256 ff965221...
  gmgn-living-pod-v1 imported True revision 1 seq 4 objects 0 contentSha256 46d12502...
  world-labs-example-warm-kitchen imported True revision 1 seq 5 objects 0 contentSha256 e6a12e20...

$ gmgn-taskd world-dump --root <tmp> --out snapshot.json
$ python3 tools/world-migration/world_state_migration.py compare --bundle backups/... --snapshot snapshot.json --expect 3
PASS world=84503420-... objects=2 layoutRevision=16 revision=6965564 fields=184 sha256=f3130407...
PASS world=gmgn-living-pod-v1 objects=0 fields=29 sha256=46d12502...
PASS world=world-labs-example-warm-kitchen objects=0 fields=29 sha256=e6a12e20...
COMPARE PASS worlds=3 failures=0

$ 再导一次（幂等）
  replay: 84503420-... imported False replayed True revision 1 seq 1
  replay: gmgn-living-pod-v1 imported False replayed True revision 1 seq 4
  replay: world-labs-example-warm-kitchen imported False replayed True revision 1 seq 5
  identical after 2nd import: True/True/True
  rows: world_records 5, world_facts 5, world_requests 3, world_imports 3
```

**一个真被抓住的静默失真**：`serde_json` 默认浮点解析会差 1 ulp——`1788523160607.4885`
回读成 `...4883`。权威的存在意义就是"读回来就是你写下去的字节"，所以打开了
`serde_json` 的 `float_roundtrip`（`Cargo.toml`，不新增 crate，`--locked` 仍然干净）。
不开它，living-pod 那个世界就会在导入后**逐字段比对失败**（差额正好 1 ulp）。

## 4. S3：Swift 只读 + 意图写（已完成）

新增：

- `apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift`
  ——同步 UDS 客户端（毫秒级本地往返，替换掉的正是原来那条同步文件写）、
  `WorldAuthorityProjection`（带 `basedOnRevision`）、`world_subscribe` 推送订阅。
- `apps/macos/Sources/GMGNRadio/Presence/AuthorityWorldStatePersistence.swift`
  ——`WorldStatePersisting` 的权威实现：`load()` 取快照（无记录则一次性导入只读预像），
  `save()` 发意图（`replaceState` + `expectedRevision` + `requestID`）。
- `LegacyWorldStatePreImage`：只读预像，**`save` 抛错**（`WorldStatePersistenceRetired.writeRetired`），
  `archive` 与 `candidateURLs` 都是 `private`（封口）。
- `LivingWorldBootstrap.makeContext` 改为：旧档案 → 只读预像 → 权威持久化 → 交给 `WorldAgentContext`，
  然后 `startEventSubscription()`。`statePersistence()` 的**签名与语义保持不变**（它现在的身份是
  "预像读取器"，`LivingCabinVersion12Persistence` 的成员也收成 `private`）。

**唯一写入方的机械判据**（评审门禁 `tools/test-world-authority-single-writer.swift`，
它由另一位 reviewer 独立编写、跑真 daemon；另有我这一侧的聚焦门禁
`tools/test-world-authority-projection.swift`）：

1. 生产源码里**不得**出现 `current.save(` / `previous.save(` / `archive.save(` / `preImage.save(` /
   `oldStore.save(` 这类对世界状态文件的写调用（门禁扫描全部 `apps/macos/Sources/GMGNRadio/**`，
   注入 `archive.save(state)` 即报 1 处违规 → FAIL）；
2. `makeContext` 必须把 `AuthorityWorldStatePersistence`（不是旧档案）交给 `WorldAgentContext`；
3. `LegacyWorldStatePreImage.save` 必须在**运行期**抛错（编译运行断言，不是读代码）。

```
$ swift tools/test-world-authority-single-writer.swift
  ok   R1 源码审计：state.json 写入口抛错，makeContext 只读预像 + 权威持久化
  ok   R1 负对照：注入 `archive.save(state)` ⇒ 审计报 1 处违规
PASS: single writer for world state — legacy write throws, authority owns writes,
      revision-guarded, deterministic, bit-faithful, subscribed

$ swift tools/test-world-authority-projection.swift
PASS: 投影带 basedOnRevision、按 subject 记 revision、被拒事实也推进游标
```

### 读路径 / 写路径 / 陈旧即拒

- **读**：启动 `world_snapshot`（拿到 `recordRevision` + `boundarySeq` + 完整文档）；
- **投影**：`seq <= 游标` 丢弃；`revision` **只在同一个 subject（`domain/key`）内**比较
  （世界记录与每件物件各有自己的数轴）；同一 subject 的 revision 回退单独计为协议错；
  **被拒的事实也推进游标**（"看见"≠"应用"，否则每次重连都重放再拒一次）；
  `basedOnRevision` **只**跟随世界记录，它就是写路径 CAS 的 `expectedRevision`；
- **写**：`world_commit` + `expectedRevision` + `requestID`。幂等键覆盖权威判重用的**整份请求**
  （`world-save:<expectedRevision>:<内容 sha256>`）：同 revision 上同内容重发 = 权威幂等回放；
  revision 前进后的同内容重发 = 一次无害的新提交（此前只用内容当键，撞 `request_id_conflict`）；
- **冲突可见**：`revision_conflict` 先做一次"这是不是我自己的写入落地了"的内容比对
  （相等 ⇒ 采纳新 revision，不报假失败），否则抛 `staleProjection(local:authority:)`——
  **绝不静默覆盖**；
- **权威不可达**（设计 §8.1 只读降级）：有预像 ⇒ 用预像把世界**渲染出来**、`save` 全部拒绝；
  没有预像（首次冷启动）⇒ fail-closed，不凭空空造世界。两条都**不写任何文件**。

### 渲染纪律

渲染仍读 `WorldAgentContext` 内存里的投影，**永不同步 RPC**。推送订阅只做一件事：
权威变化时推进写准入用的 `basedOnRevision`。

## 5. S2 明确跳过（如实记录）

计划里的 S2 是"Swift 读 Rust、但仍由 Swift 写（Rust 只读镜像）"。**没有做**，直接从 S1 走到 S3。
理由：S2 要求一个**双写窗口**（Swift 写 `state.json` + Rust 只读镜像），而双写正是第二份真相的
温床；S1 已经把所有机制（revision/幂等/事件/导入）验证完，S3 的"唯一写入方"比 S2 的"镜像"更安全。
代价如实说：**因此没有"镜像回滚"这条路**——回滚只能整体退回 `state.json` 权威（§6），
而不是"改读回 Swift 写、Rust 继续跟"。这是本次迁移唯一被主动放弃的可选项。

## 6. 回滚（一条命令，只用于出事）

```sh
backups/world-state-migration/20261001T061021Z/rollback.sh --confirm
```

它按导出的 sha256 把预像写回 live 文件（写之前先把现状存进 `rollback-preimage/<stamp>/`），
**不删任何东西**。若要连 Swift 一起退回旧形态，把 `LivingWorldBootstrap.makeContext` 里的
`AuthorityWorldStatePersistence(...)` 换回 `archive` 即可（旧档案类型与 `statePersistence()`
签名都还在，就是为了这一刻）。

## 7. 现在还有没有第二份真相？

- **S0/S1 期间**：有。Swift 仍写 `state.json`（唯一写入方还没切）。
- **S3 之后（当前代码）**：**没有**。世界状态的唯一写入方是 `gmgn-taskd`；
  Swift 侧不存在世界状态持久化路径（门禁 1–3），`state.json` 只在两处被**读**：
  一次性导入、以及权威不可达时的只读降级。两处都不写。
- **未验证的残留**：另一台设备/云端写入会让本地投影前进（事件订阅），
  但"远端事件直接改写渲染中的物件"这条**还没接**——今天单设备，远端事件只用于
  推进写准入 revision。多设备前必须先补这一段（设计 §4.8b）。

## 8. 需要真机确认（无法在无 GUI 环境验证）

1. 启动生活空间：世界能从权威快照起来（首次会先做一次性导入）；
2. 一次"摆放/领取"往返：意图 → `world_commit` → revision 前进，重启后仍在；
3. `state.json` 的 **mtime 不再变化**（迁移后 Swift 不再写它）；
4. `make install` 装上带 helper 的 app（`Contents/Helpers/gmgn-taskd`）后，
   杀 daemon 再启：世界应进入**只读降级**（能看、写被拒且有可见报错），而不是崩。

## 9. 明确的后续（不在本次范围）

- **一条日志**（设计 G4）：任务事件 `events`、统一状态 `resident_events`、世界 `world_facts`
  今天仍是三条序列；合并需要同时改 `store.rs`/`resident.rs` 的读取路径。
- **MCP 面**：`world_records`/`world_snapshot`/`world_commit` 已经是 MCP 资源与工具要的形状
  （`id/scope/domain/key/revision/updatedAt/updatedBy/tombstone/hash/value`），但 `gmgn-mcpd` 未建。
- **动作域（P3）/ 世界事实（P5）/ 任务与许愿（P4）**：按设计分阶段，本次只做世界与物件。
- **事件驱动的渲染收敛**：见 §7 最后一条。

---

## 10. 验证结果（本次实际跑出来的）

```sh
$ make build 2>&1 | grep -E "error:|BUILD SUCCEEDED"
** BUILD SUCCEEDED **

$ cargo test --locked --manifest-path services/gmgn-taskd/Cargo.toml | tail -3
test result: ok. 115 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out

$ swift test --package-path apps/macos/Packages/WorldRuntime | tail -3
✔ Test run with 211 tests in 0 suites passed after 161.569 seconds.
```

`make test-harnesses` 本机**被另一条实现线打断**，不是世界状态的红：

```
swift tools/test-living-resident-loop.swift
main/test-living-resident-loop.swift:9: Fatal error: Missing private struct ResidentMemoryTurnSlot
make[1]: *** [_test-harnesses] Trace/BPT trap: 5
make: *** [test-harnesses] Error 2          # PASS=18 FAIL=0，后面的 harness 根本没跑
```

同一份 Makefile 列表里**除它以外**的 38 条逐条跑（`tools/test-world-authority-single-writer.swift`
与 `tools/test-world-authority-projection.swift` 都在内）：

```
harnesses run: 38  OK: 37  FAILED: 1
failed: ['tools/test-wish-machine-coordinator.swift']
        └ error: input file '.../Agent/ResidentWishMachineTools.swift' was modified during the build
          （许愿机那条线正在改它，编译期被打断，不是断言失败）
```

两条非绿都不是本迁移：

| 现象 | 归属 | 证据 |
| --- | --- | --- |
| `test-harnesses` 中止 | memory-and-generation-results 线 | 崩溃发生在 `test-living-resident-loop.swift`（他们 15:19 刚改过），`Fatal error: Missing private struct ResidentMemoryTurnSlot` |
| `test-wish-machine-coordinator` FAILED | 许愿机 MCP/skill 线 | `ResidentWishMachineTools.swift` 在编译期间被改（swiftc 拒绝） |
| `test-living-cabin-state-upgrade` FAIL | 许愿机线 | 把**只有我那处** `LivingCabinVersion12Persistence` 的 edit 回退后，它**照样**以同一句话 FAIL（`FAIL: new machine comes from current manifest while old object state survives`）⇒ 与本迁移无关；这条 harness 不在 Makefile 列表里 |
| WorldRuntime 首轮 1 issue | 机器负载（4 条线同时在编译） | 失败断言是 `evaluateElapsed < .seconds(20)`，实测 20.57 s；机器静下来重跑 **211 tests passed** |

## 11. 一件必须说明的事

本迁移的改动**已经被另一条实现线提交进 git**（commit `fb1a2ce`，
`feat: give the world an authority and the artifacts a content-addressed home`，作者 neeboo）。
我自己**没有**运行任何写 git 的命令（只用过 `status`/`log`/`diff`/`show` 这类只读命令）。
该提交把本迁移的文件一并收进去了：`services/gmgn-taskd/src/{world.rs,cli.rs}`、
`Cargo.toml`、`daemon.rs`、`main.rs`、`store.rs`、
`Presence/{WorldAuthorityClient.swift,AuthorityWorldStatePersistence.swift}`、
`App/LivingWorldBootstrap.swift`、`tools/world-migration/**`、
`tools/test-world-authority-projection.swift`、以及本文档。
`world.rs` 后来还被 review 那条线加了若干测试（总量 115 个 cargo 测试全绿）。
