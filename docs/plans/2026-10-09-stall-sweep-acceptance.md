# 一次点完：四条链的现场验收脚本

对象：`/Applications/gmgn radio.app`（build 229 / `0.1.0`，taskd helper 随包重建）。
目的：**一次**看完四条链，每一步同时给出「界面表现」「日志判据」「DB 判据」，失败时
直接指出是哪一层的哪一行。

前置（只做一次，全部只读）

```sh
APP="/Applications/gmgn radio.app"
ROOT="$HOME/Library/Application Support/gmgn radio/TaskService"
DB="$ROOT/tasks.sqlite3"
# 版本 / helper 同源
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"
shasum -a 256 "$APP/Contents/Helpers/gmgn-taskd"
python3 tools/verify-helper-manifest.py --app "$APP"
# 只允许一条 LaunchServices 注册
mdfind "kMDItemCFBundleIdentifier == 'ai.gmgn.radio'" 2>/dev/null
```
只读看库（**绝不写**用户数据；如需副本先 `cp` 到 tmp）：
```sh
sqlite3 -readonly "$DB" 'select state,count(*) from agent_tool_calls group by state;'
sqlite3 -readonly "$DB" 'select event,state,run,session from agent_loop_events order by rowid desc limit 5;'
sqlite3 -readonly "$DB" 'select revision,json_extract(state,"$.pendingRenderer"),json_extract(state,"$.rendererStatus") from presence_selection;'
```
日志（两条流，分开看）：
```sh
# 宿主 + Unity 宿主侧（NSLog）
log stream --style compact --predicate 'process == "gmgn radio" AND eventMessage CONTAINS "gmgn"'
# Unity 渲染侧
tail -f "$HOME/Library/Logs/GMGN/gmgn radio/Player.log"     # 或 Console 里进程 gmgn radio 的 Unity 段
```

---

## A. 启动 → 进空间（场景/活动/物件/许愿机）

**点**：启动 App（只起一个实例），什么都不点，等世界画面出现。

| 判据 | 期望 |
|---|---|
| 界面 | 直接进空间，不是停在播放器/黑屏；标题栏不出现「空间暂时无法连接」红字 |
| 日志 | `[UnityMediaHost] world selection: world=… phase=prepare revision=…` 之后必须出现 `phase=activate` |
| 日志 | `[WorldPrepare] step=ready world=… items=N`（N 等于该空间物件数） |
| 日志 | 没有 `phase=failed`；若出现，`code=` 后面的名字就是层：`world_prepare_timeout`（渲染侧预算）、`world_prepare_unanswered`（宿主 watchdog 180 s 未收回执）、`world_prepare_busy`（上一次准备还在飞）、`world_authority_unavailable`（taskd 没起来）、`world_authority_activation_failed`（状态在载入期间前进） |
| DB | `sqlite3 -readonly "$DB" 'select count(*) from agent_loop_events where state in ("claimed","cancel_requested")'` → 0（没有悬挂的 claimed 回合） |

**许愿机**：随便生成一次，判据是 `wish` job 从 `generating` 走到 `claimed` 且物件出现在空间里；
失败时 UI 文案必须具名（不是「操作失败」），日志里 `wish_`/`inventory_not_confirmed`。

## B. 聊天（跟居民说话）→ 工具调用 → 回执 → 回复

**点**：聊天框发一条会用到世界的消息（例如「走到沙发那边坐下」），发完不要动。

| 判据 | 期望 |
|---|---|
| 界面 | 有回复文字；不出现红色「rust_dsh_failed / rust_dsh_transport_failed / error 4」 |
| 日志 | `agent_dsh_start` 之后 `state` 依次出现 `running` →（若有工具）`authorize`/`execute` → 终止态 |
| DB | 该轮结束后：`select state,count(*) from agent_tool_calls where run='<run>' group by state;` 里没有 `inflight`；`unknown` 允许存在（那是「我们没学到效果」的诚实记录） |
| DB | `select state from agent_loop_events where run='<run>';` 是该轮的终态（`completed`/`failed`/`cancelled`），不是 `claimed` |
| 关键自愈 | 若渲染/宿主回执被拒，**下一次**发消息必须还能 `agent_dsh_start` 成功；日志会出现 `"code":"agent_dsh_stale_unconfirmed_tools"`（上一轮残留的未确认调用不再永久堵住新回合） |

失败定位（这是本轮主要修的类别）：
- `agent_dsh_unresolved_tools` → 只在**该 run 仍 claimed** 时才该出现（真正的在飞回合）；若出现在已结算的 run 上，说明陈旧状态又变成了门。
- `agent_dsh_session_busy` → 上一个 in-memory 会话还没到终态；`unknown` 现在算终态（ACP 子进程已回收）。
- `agent_dsh_invalid_receipt` → 回执被拒；此时该 `execute` 必须**立刻**从 `pendingTools` 消失，且 `agent_tool_calls.state='unknown'`，不再等 120 s。
- `agent_tool_requires_reconciliation` / `agent_runtime_reconciliation_mismatch` → 跑一次 `agent_runtime_reconcile`（现在允许 run 已终态、call 仍 unknown 的情况）。

## C. 设置里切换一次动作（选定动作）

**点**：设置 → 角色/动作 → 点一次「选定动作」（换一个动作）。

| 判据 | 期望 |
|---|---|
| 界面 | 动作真的切过去；不允许「点了没反应」或行是灰的 |
| DB | `select revision from presence_selection;` 必须 +1（或对同一 requestID 幂等） |
| DB | `json_extract(state,"$.pendingRenderer")` 先 1 → 渲染回执后 0；`rendererStatus` 从 `loading` → `ready` |
| 日志 | 被拒时**必须**有 `gmgn-taskd: {"event":"rejected","code":"presence_…","method":"presence_selection_event","eventName":"select_motion","id":"…"}` |
| 有界自愈 | 若渲染器不回执：180 s 后**下一次**请求（打开面板 `bind_catalog`、读一次 `presence_selection_read`、或再点一次动作）必须让 `pendingRenderer` 变 0、`rendererStatus="failed"`、`rendererRecovered/presence_renderer_ack_timeout` 具名，并且这次点击要成功；宿主侧日志出现 `code=presence_renderer_ack_timeout` |
| 不许放宽 | 预算内第二次选定仍然是 `presence_renderer_pending`（具名拒），不是静默忽略；非法 id 仍 `presence_motion_incompatible`；陈旧 revision 仍 `presence_revision_conflict` |

## D. 栏上动作（次要）：声音 / 小窗 / 全屏

| 动作 | 判据 |
|---|---|
| 声音（音量±/静音/播放暂停） | 每点一次都有可见/可听结果；`music.volume` 值在 0…1 单调变化；拒绝时 `settings_command_rejected` 之外必须有 `code` |
| 小窗（compact） | 点一次就切换；**若切换失败**，`setCompact` 返回 false 时必须有一行具名日志（当前是静默 `return false`） |
| 全屏 | 进出全屏各一次；`fullscreenTransition` 若在 `willEnter/willExit` 之后拿不到 `did*` 通知，会在 20 s 后自行过期并打日志（当前实现**没有**这个过期，见报告「已登记」） |

---

## 失败 → 哪一层（速查）

| 现象 | 最先看的证据 |
|---|---|
| 界面白/停在播放器 | `[UnityMediaHost] world selection` 的 `phase`/`code` |
| 「空间载入失败」但没有原因 | `[WorldPrepare]` 最后一条 `step=` |
| 聊天报「传输失败」 | `agent_dsh_*` 的 daemon 拒码**只在 HTTP error.code 里**；宿主 `RustDSHSessionClient.request` 目前把它折叠成 `ClientError.transport`（禁改区报告第 1 条），所以先看 DB 的 `agent_tool_calls.state` 与 `agent_loop_events.state` |
| 点了动作没反应 | 宿主 `PresenceSelection` 日志（`code=…`）+ DB `presence_selection.state` 的 `pendingRenderer` |
| 音量/窗口没反应 | `[UnityWindowModeBridge]` / `settings_command_rejected` 的 `code` |
