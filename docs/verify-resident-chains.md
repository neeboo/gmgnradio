# 四链无人值守验证 harness

**目的**：把"用户点一次 → 我们修一个错 → 再打一版"这个循环打断。这四条链
（启动进空间 / 聊天居民回合 / 设置切动作 / 栏上动作）的每一个卡点都曾经只能靠真人
把鼠标按下去才暴露。这个 harness 把它们搬到**无 UI 输入、可重复、一次跑完**的断言上，
并且**故意注入故障**去证明"卡住"能被有界收敛——或者证明它不能。

## 一条命令

```sh
tools/verify-resident-chains.sh                       # 四条链全跑
tools/verify-resident-chains.sh --only B              # 只跑 B 链
tools/verify-resident-chains.sh --json tmp/verify-chains/ledger.json
tools/verify-resident-chains.sh --list                # 只列四条链
```

底层是 `tools/verify-resident-chains.py`。退出码：全 PASS = 0，有 FAIL = 1，
缺 `gmgn-taskd` 二进制 = 2。输出是逐条 `[PASS]/[FAIL]`，每条带一个稳定 id；
FAIL 会给出**具名原因**与 `文件:行`。末尾另附一份**剩余卡点清单**。

## 四条链各自能自动判定什么

### A 链 · 启动 → 进空间 → 场景/活动/物件（28 条）

* `tools/verify-world-prepare-state-machine.py`：等价状态表向量 + 对生产
  `apps/macos/UnityHost/UnityMediaHost.swift` 的结构性断言。
* 关键向量：渲染回执丢失 → `schedulePrepareWatchdog` 在 180 s 后有界落成
  `phase=failed code=world_prepare_unanswered`；陈旧的 prepare 回执按
  `revision`/`worldID`/`phase` 三个守卫被拒；载入期间权威前进 → 具名
  `world_authority_activation_failed` + 有界启动重试（上限 4 次）。
* **需要真机的部分**写在该脚本的 `REAL_DEVICE_ONLY` 里，并在输出中带出。

### B 链 · 聊天（居民回合）（38 条）

真 `gmgn-taskd` 二进制 + 私有 `--root` + 真 HTTP `/rpc`；会话由一个**真子进程**
（最小 ACP peer）推进到 `running`，然后走与 macOS 宿主 `RustDSHSessionClient`
逐字一样的序列：`agent_dsh_start` → `agent_dsh_read` → `agent_dsh_authorize`
→ `agent_dsh_read` → `agent_dsh_tool_receipt`。

* 工具目录是**真机量级**（53 项），且带 `submit_wish_generation` 那种
  `type: ["object","null"]` 的 union 子 schema（2026-10-08 `error 3` 的回归形状）。
* 回执是**真机体积**：`inspect_world` 的完整快照形状，27,967 字节，
  越过旧的 16 KiB 模型参数上限（真机上把整条 B 链卡死的就是这个体积）。
* 断言：行变 `finished` 且落盘 receipt 非空（28,016 字节）；重放幂等；
  下一轮 start 不被 `agent_dsh_unresolved_tools` 挡住。
* **故障注入**（三种各起一个独立 daemon + root）：词表外 `status`、>1 张图片、
  超限体量。每种都断言：被具名拒绝、stderr 点了字段、这一轮有界落地、
  账本不留未决行、未决行跨重启是否存活、宿主有没有 RPC 能自己清。

### C 链 · 设置里切换动作（18 条）

真 daemon 的 `presence_selection_*` RPC，夹具是**真的落盘资源**
（VRM + 两个 `.vrma`，含 `manifest.json` 与 entry 校验）。

* 正常链：绑定 → 选角色 → `renderer_ack` → 选动作 → 未确认
  （`pendingRenderer=true`）→ `renderer_ack` → 确认 → 再选下一个。
* pending 期间再选 → 具名 `presence_renderer_pending`（不是匿名
  `settings_command_rejected`）；同 requestID 换参数 → `presence_request_conflict`；
  陈旧 revision → `presence_revision_conflict`。
* 词汇核对：宿主谓词转述 daemon 的每个码 daemon 都真的会发；daemon 的动作相关码
  宿主都认得；宿主自有的 `presence_selection_busy` / `presence_selection_stale_cleared`
  没有被 daemon 冒用。

### D 链 · 栏上动作（音量 / 小窗 / 全屏）（27 条）

`tools/verify-bar-action-senders.py`。**不**重复 `apps/gpui-ui/tests/transport_popover_geometry.rs`
与 `apps/gpui-app` 的 `#[cfg(test)]` 已经钉的控制表顺序/几何；这里补的是它们没有的
**发射点不变量**：

* 每个动作的发射点是一张**具名清单**（文件 + 数量 + 存在理由），多一个就红；
* 同一动作的发射点必须落在**具名动词家族**里，长出新语义就红；
* 每条渲染路径内部的发射点数量精确。

> 刻意**不钉绝对行号**：并发写这条链的分支会让行号天天漂（实测 `963 → 967`），
> 钉行号只会把门禁变成噪声。清单断言的是数量与动词家族。

## 负对照（证明门禁真的会红）

```sh
python3 tools/verify-chains-can-fail.py
```

把被检查的生产文件复制到临时目录，在副本上注入典型退化，再让对应 harness 去跑副本
（原仓库一个字节不改）。当前四条注入全部被抓到：

| 注入 | 被抓它的断言 |
| --- | --- |
| 删掉 `schedulePrepareWatchdog` 的调用点 | `A2.11` |
| 削弱 watchdog 的 `phase == prepare` 守卫 | `A2.2.phase` |
| 栏上再点一次全屏（多一个发射点） | `D1.全屏.1` |
| 音量再走一个独立入口 | `D5.3` |

## 覆盖不到的（诚实边界）

* **真人点击**：命中区域（命中区 vs 绘制区）、抢焦点、多显示器全屏行为。harness 不合成
  CGEvent/AX/osascript，也不抢焦点。
* **Unity 真机渲染路径**：渲染器真的在预算内发回执、`prepare→activate` 之后画面真的切过去、
  场景/活动/物件真的出现、`prepareWatchdog` 的 180 s 是否够 —— 需要 Unity 编辑器/真机播放器。
  A 链把可自动的部分（状态机与守卫）与需要真机的部分（`REAL_DEVICE_ONLY`）分开列出。
* **真 LLM 的一轮**：B 链用真 daemon + 真 ACP 子进程位置 + 真 grant 路由 + 真体积回执，
  但**不**调用真模型。"模型产出的工具调用是否合法"不在覆盖范围内；"宿主/daemon 对
  工具调用与回执的处理"在。
* **音频听感、设备状态、钥匙串**：一律不碰。
* **UI 是否把状态画对**：C/D 只钉到值域与发射点；控件真的画成什么样需要截图/真机。

## 它能确认什么、不能确认什么

* 能确认：这四条链在**协议与状态机层面**不会因为已知的几个形状（union schema、
  生产体积回执、pending 未回执、陈旧 revision、重复发射点）而卡住；卡住时原因是否具名。
* 不能确认：真机上"用户看到的画面/听到的声音"是否正确；需要真机渲染的时序是否达标。

## 相关文件

| 文件 | 作用 |
| --- | --- |
| `tools/verify-resident-chains.sh` | 一条命令入口 |
| `tools/verify-resident-chains.py` | B/C 链 + 总账 + 剩余卡点清单 |
| `tools/verify-world-prepare-state-machine.py` | A 链（被上面调用） |
| `tools/verify-bar-action-senders.py` | D 链（被上面调用） |
| `tools/verify-chains-can-fail.py` | 负对照自检 |
