# 生成资产的删除语义（一页）

用户原话：**「生成的资产可以删除，让 agent 能调用工具」**。这一页是删除的判据清单，
实现落在 `WorldRuntime`（世界层）、`ResidentPropPlacementService`（判据层）、
`ResidentPropToolBridge`（agent 面）、`ResidentPropEditorState/View`（用户面）与
`tools/reconcile-generation-results.py`（对账器）。**不碰 `services/**`**：Rust 权威
的墓碑语义已经在了（`world_records.tombstone` + `object.removed` 事实），本轮只是
把它**用起来**。

## 1. 删什么

| 层 | 删 | 不删 |
| --- | --- | --- |
| 世界记录（权威） | 把这条记录**置墓碑**（`tombstone=1`）并派生一条 `object.removed` 事实 | **行本身**（历史与消费者游标要靠它） |
| 世界文档（Swift） | 这一条离开 `objectStates`（这正是权威派生墓碑与事实的输入） | 它的身份：冻结进 `WorldState.propTombstones[objectID]` |
| 库存条目 | 同一条记录，一并消失（物件不再出现在「我的物件」里） | —— |
| 资产引用 | 这件物件自己引用的 blob 从**活引用**集合里退出 | 还被别的活物件引用的 blob（见 §2） |
| 磁盘字节 | 只有**引用计数为 0** 的内容才进入"可回收" | taskd 私有根里的字节（见 §2 末） |

## 2. 什么时候删文件：引用计数，**派生**而来

`world_blobs` 刻意**没有 refcount 列**（`services/gmgn-taskd/src/world.rs:43-44`：
"a blob is reachable only through the `blobRef`s actually present in records"）。
这一条纪律在 Swift 这一侧逐字照办：

- 引用来源 = **活着的物件**（`WorldState.objectStates` 里带 `generatedProp` 的那些）
  各自的 `assetID`（模型字节 sha256）+ `collision.sha256`（碰撞代理）；
  墓碑与手持中的 `returnState` **不算活引用**；
- 计数**派生**：`WorldPropAssetReferences.referenceCounts(in:)` 每次现算，
  **绝不新增一列/一份缓存**（"同一事实存两份"正是这个项目反复踩的坑）；
- 删除的判据：`unreferenced = released − ⋃(活物件的引用)`。计数 > 0 ⇒ 文件必须留着；
  计数 = 0 ⇒ 才允许回收。回执里带**数字**（`retained: {sha256: [objectID…]}`）。

**字节由谁删**：内容寻址的产物字节住在 taskd 私根（`<root>/<jobID>.glb` 等），
拥有者是 `gmgn-taskd`，不是本进程。所以本轮把**判定**（哪些引用释放、哪些仍然被引用、
哪些计数归零）算出来并公开，**回收动作**留给存储拥有者 —— App 不越权删除
daemon 的字节（`services/**` 是另一条刚收口的线）。这也正是"共享文件不误删"的
结构性保证：App 手里根本没有"按 objectID 删文件"这条路。

## 3. 正在摆放 / 手持 / 挂在身上：**原子收场**，不拒绝

结论：**同一次提交里收场**（一条命令、一个 `layoutRevision`、一条回执），
而不是"先收回再来一次"或"可见拒绝"。

| 删除时的状态 | 收场动作（`WorldPropDeletionSettlement`） |
| --- | --- |
| 未摆放、未手持 | `.inventory` —— 没有要收场的东西 |
| 已摆放 | `.withdrawn(surfaceID:position:)` —— 摆放随删除一并结束（删除的正是那件东西） |
| 手持 / 挂在身上 | `.returnedFromSlot(slot:position:)` —— 先按 `heldProp.returnState` 放回，同一提交里删掉 |

**为什么不是"可见拒绝"**：收场所需的全部信息**已经存在**（`heldProp.returnState`
就是"拿起前那一处"，这正是该字段存在的理由），原子收场不引入任何新信息、也不需要
用户再点一次；拒绝反而会把用户的明确要求（"把手里那个删了"）拆成两步，并让 agent
在一轮里完不成。**为什么不是硬删**：手持状态下直接抹掉记录会留下悬空的 `heldProp`，
渲染与回执都会指向一件不存在的东西 —— 所以必须先放回再删，而且**在同一个提交里**
（中途失败则一个字节都没变）。

## 4. 可回滚 / 可恢复：**不可恢复**，文案必须说清

墓碑是**软删**（记录还在、历史还在、对账器看得见），但对用户与 agent 而言这是
**永久删除**：

- 没有"恢复"入口，`undo` 不吃删除（删除会作废指向它的那一槽撤销记录）；
- 面板按钮要**确认**后才能按，回执文案是「已删除（永久）…」；
- agent 工具描述逐字写着"永久删除、不可恢复"，并要求本轮人类明确指令。

不给恢复的理由：`layoutUndo` 只有一槽、且是"上一次摆放/收回"的撤销，把删除塞进去
会变成"撤销上次 = 让一件东西复活"，语义与既有的撤销轴冲突；恢复要正确，得同时恢复
库存条目、摆放位置、挂载标定与能力绑定四样，而这些东西今天的唯一权威是那条被删掉的
记录——把它当作"可以随时反悔"会让墓碑与事实日志失去意义。**所以：软删是为了可审计，
不是为了可回滚。**

## 5. 判据分层：删除是**第三层**（`.removal`）

`ResidentPropLayoutIntent` 今天有两层（`.inventoryRegistration` / `.spatialChange`），
本轮按它自己的设计（"唯一一处对命令的穷尽 `switch`，编译器逼新命令回答"）加**第三层**，
两层**一个字不改**：

- 「记录 + 资产 + 幂等」照旧（删一件资产已经坏掉的物件**必须**成功，否则坏资产删不掉）；
- **不跑空间判据**，理由是**单调性**而不是"省事"：空间判据的全部输入是"房间里有哪些
  障碍、够不够站、路通不通"，而删除只会**移走**一个障碍 —— `blockedNodes` 只减不增、
  `placed` 只少不多，每一条空间判据在删除后的候选状态上只会更容易满足，不可能被删除
  破坏。反过来要求承托几何可用，会让"几何已经拿不到"时**删不掉**，那正是最需要删的时刻。
- **多一条运行时类型前提**（与 `.inventoryRegistration` 的"入库登记不得已在空间里"对称）：
  候选状态里这件物件**必须已经不在** `objectStates`，而且**必须**留下一条身份逐位匹配的
  墓碑。将来有人把一条不写墓碑的命令归到这一层，会在这里 fail-closed 拒绝。

## 6. 「删干净」的三层证明

| 层 | 判据 | 谁回答 |
| --- | --- | --- |
| 记录 | 权威行 `tombstone=1` **且**有 `object.removed` 事实；事件日志里有 `propDeleted` | 权威 / `WorldSimulation.events` |
| 引用 | 释放的 blob 引用不再出现在任何活物件里；仍被引用的**带数字**列出 | `WorldPropAssetReferences.reclamation` |
| 文件 | 计数 = 0 才"可回收"；计数 > 0 的文件**必须还在**（对账器按内容哈希核对磁盘） | 对账器 `removal_proofs` |

对账器今天会把"墓碑"当**丢失**（`preimage_object_tombstoned_in_authority` 与
`claimed_but_not_in_inventory`）。本轮改成：**有 `object.removed` 事实的墓碑 = 有意删除**
（不再是 FAIL），**没有事实的墓碑 = 无法解释的丢失**（仍然 FAIL）。区别就在事实那一条。

## 7. 将来怎么同步进 MCP 的 catalog

一句话：`delete_prop` 的 schema 与描述将来原样登记进 `services/gmgn-mcpd` 的
catalog（与 `read_owned_props` / `hold_prop` 同一张表），幂等键仍用调用方的
`layout_revision` + `requestID`，权威侧的墓碑与 `object.removed` 事实**已经是**
MCP 可以读的那一份（`gmgn_world_records_read` 的 `tombstone` 列）；本轮不动那条线。
