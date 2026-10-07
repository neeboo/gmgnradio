# 端到端验收 — 2026-10-03（屏幕 / 收件箱 / 居民播放能力 + 真实链路）

接手 `docs/plans/2026-10-03-handoff.md` 之后的一次**实际跑过**的端到端验收。本文只写
**事实与证据**：跑了什么、真实输入与 id、原始回执、退出码、哪些是真实通过、哪些是模拟、
哪些没验。

- 仓库：`/Users/ghostcorn/dev/gmgnradio`
- 分支：`codex/agent-living-world-e2e`，提交 `0341b5887b90170f8d76fbc8ffb7eb0a67accbb8`
- 机器：macOS 26.5.2 (25F84)，arm64；Xcode 26.6；Swift 6.3.3；Python 3.14.4
- 权威二进制（本次运行哈希）：
  - `gmgn-taskd` sha256 `6426d069e949c903cebc14ef7df6a390b9e0d0061f96153aceb2f8d813f22c44`
  - `gmgn-mcpd` sha256 `af3cc5cf2fba0d4454dba60f915d6d9d67b79b0b34eafa50145b540a77e3d719`

> 纪律：全程**不**启动/重启已安装宿主 app、**不**触发 Keychain 或系统授权、**不**用
> AppleScript/辅助功能注入、**不**读或清用户数据、**不**打印任何凭据。所有临时 root 都在
> `tmp/e2e-acceptance/` 或系统临时目录，跑完即弃。

---

## 0. 一句话结论

- **分层集成验收：44 条顶层检查，0 失败，`E2E_EXIT=0`**（`tmp/e2e-acceptance/ledger.json`）。
  它运行真实 `gmgn-taskd`（UDS）、`gmgn-mcpd`（stdio）和 `WKWebView` 官方嵌入播放；
  生成后端是回环 HTTP 测试夹具，返回合成 GLB，并未调用真实模型生成服务。
  44 条由 31 条进程断言、12 个 Swift harness 退出码检查和 1 条播放器检查组成。
  世界导入/摆放由测试驱动器显式提交；尚未证明宿主自动消费生成结果并完成交互的完整用户流程。
- **Rust 两侧**：`gmgn-taskd` 132 tests / `gmgn-mcpd` 13+6+4 tests，全绿。
- **门禁**：`make test-harnesses` = **`GATE_FINAL2_EXIT=0`**（69 条 `swift` recipe +
  对账 `--self-test`，0 个 `FAIL`/`Error`；日志 `/tmp/gmgn-gate-final2.log`）。
- **三条线落定**：见 §6。
- **仍没验的**：当前树 `make build`（沙箱拒绝 SwiftPM 缓存写；产品由一次 09:43 的成功构建
  证明；见 §7.2）、真机 GPU 画面（需要宿主窗口与 Metal）、Twitch 自动播、B 站黑屏、
  MCP 二进制打进 app `Contents/Helpers/`、系统级 UI 点击注入。见 §5。

---

## Unity 设置分区证据矩阵（2026-10-07，核对至 v175）

本节是已有现场记录的证据索引，不是新增运行验收。当前真实分区取自
`apps/gpui-ui/src/settings.rs` 的侧栏枚举（`for (label,items)`）及
`apps/macos/UnityHost/UnityMediaHost.swift` 的 `availableSections`，二者当前共 13 项；
它们是六个侧栏组下的子分区，不是 13 个独立窗口。源码接线、构建与夹具均不计作实际 UI 通过。
后续现场通过只补相应单元，不能将一项消费扩大为整页或全部服务通过。

| 分区 | 已验证的实际范围与证据 | 尚未验证的消费边界／安全下一入口 |
|---|---|---|
| 歌词 | 迁移记录 `2026-10-04-unity-space-migration.md` 的 v25 实际 GPUI 选择莫奈→Player `monet_poster`；后续十一主题截图显示。 | 全主题精确字体、布局、动画及长翻译对齐未全部确认；只补缺少证据的主题与歌词边界，不重做已通过选择。 |
| 视觉效果 | 已有点阵实际 Metal 运行及若干画面记录，见迁移记录 v51–v57。 | 八模式与粒度设置的逐项实际消费及原版视觉对齐未全部证明；可逆选择现有模式并恢复，不用构建或 Update FPS 代替画面。 |
| 视频 | 本文 v171 导入既有本地 MP4；v174 实际方向正确、停止→再次播放正确。 | 歌曲绑定／解绑、切歌自动跟随仍缺窗口闭环；用同一合法素材。网络 YouTube 403/Bilibili 412 单列未通过，不加入 cookie。 |
| 语音播放 | 迁移记录 v149 显示四声音及试听按钮生命周期；本文 v171 自动朗读 off 被真实回复消费、随后恢复 on；v169 进程限定音频通过，v171 blendshape 驱动与停止归零。 | 近景口型可见质量、音乐压低与恢复仍待观察；目录/按钮通过不等于各声音听感、全部服务或设置持久化全通过。 |
| 按住说话 | 迁移记录 v148 真实 PD200X 录音→百炼→草稿、不自动发送；v149 实际麦克风列表与保存 PD200X。 | 实际录音取消、迟到转写抑制及重启回显待验；沿用已有设备/配置，不改凭据，不自动发送测试草稿。 |
| 自主行动 | 自主循环已有真实运行与事件消费；开合跳 v170 自然 EXIT 后权威 `activeActivity=null`，但这不证明设置控件消费。 | 设置预算 0／暂停／恢复、人格保存后下一回合消费仍缺专项 UI 证据；保留原值并恢复，不新起付费生成。 |
| 音乐账号与歌单同步 | 迁移记录 v146 实际音乐库 50 歌单、259/259 歌曲；本文 v167–168 点唱机换歌及顶部/列表同步。 | 账号设置页连接/断开/同步自身尚无完整 UI 证据；先只读真实账号及库状态，不为验收断开账号。历史节目列表与指定既有 slot 也待实际消费。 |
| 角色管理 | 本文 v129 候选 VRM 实际导入与选择；后续文件面板超过 2 秒后取消仍连接，2B/Kipfel 实际切换；v174–175 2B 与原持剑状态恢复。 | 删除/链接下载及失败恢复没有完整 UI 证据；只操作可丢弃独立候选，不能删除原角色。切换已通过，不重复。 |
| 动作管理 | 本文 v170 原开合跳进入 LOOP、自然 EXIT 与持久 idle；已安装 PMX/VRM 待机和持剑行走在 v172–174 有真实画面。 | 动作导入/移除/远端目录安装的设置页消费未全验；运行某个动作不等于这些管理入口通过。不重做已通过开合跳。 |
| Agent 连接 | 多轮真实居民会话、工具成功回执见本文 v167–175，证明当前已选后端可用。 | 账号登录/退出、后端切换及策划模型/DJ 人格下一请求消费仍缺 UI 证据；先只读现状，不能为填满矩阵退出账号或新建远端节目。 |
| 快捷键 | 生产 coordinator、GPUI capture、输入焦点门禁已接源码，不能据此计实际通过。 | 真实录制/取消/恢复、前后台及媒体键、中文组合期间不误触待验；v172 中文粘贴不替代输入法候选组合。 |
| 生成服务 | 已有真实生成设备恢复及物件工具消费；这不证明服务设置保存/检测入口。 | 现有 endpoint/configured 状态、检测/错误显示与取消待 UI 证据；不清凭据、不变更生产地址、不造新任务。 |
| 我的空间 | 空间/播放器实际切换；v175 WORLD 隐藏时返还成功且正式 revision=2007 原 transform 精确恢复，证明模式相关资产门禁已修。 | 默认策略切换后启动消费、合法人物坐标/重置与持久回执、Marble 列表及配置界面待专项 UI 证据；Marble 生成/下载/注册夹具不计真实服务验收，不新发付费生成。 |

范围外的共用入口也单列：图片选择/粘贴/移除与真实缩略图、同轮模型识图尚待窗口验收；
这是聊天附件入口，不虚构成第 14 个设置分区。通知已在本文 v173–174 完成真实到达→红色 1→详情已读→
正式 unread=0→Player 重启保持，不继续列作设置矩阵待办。持剑行走、返还/再次持有与 Player 重启、
本地视频方向/停止恢复及隐藏空间返还亦以 v172–175 后续证据为准，不重列历史失败。

## 1. 可复跑入口

```bash
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd /Users/ghostcorn/dev/gmgnradio

# 0) 先编出权威与 MCP 两个真进程（本仓 cargo workspace）
cargo build --locked

# 1) 端到端验收（真 taskd + 真 HTTP 生成后端 + 真 mcpd + Swift 业务层 + 真 WKWebView 播放）
make e2e-acceptance            # == python3 tools/e2e-acceptance.py --ledger tmp/e2e-acceptance/ledger.json
# 只跑进程层（离线、不需网络）：
python3 tools/e2e-acceptance.py --only authority,placement,wish,mcp
# 只跑 Swift 业务层 + 播放器：
python3 tools/e2e-acceptance.py --only swift,player

# 2) 门禁与构建（走仓库 build lock，串行）
make test-harnesses
make build

# 3) Rust 两侧
cargo test --locked --manifest-path services/gmgn-taskd/Cargo.toml
cargo test --locked -p gmgn-mcpd

# 4) 真 taskd 子进程的离线契约测试（没挂进 make，单独跑）
TASKD_BIN="$PWD/target/debug/gmgn-taskd" python3 services/gmgn-taskd/tests/process.py -v
TASKD_BIN="$PWD/target/debug/gmgn-taskd" python3 services/gmgn-taskd/tests/local_memory_process.py
```

账本：`tmp/e2e-acceptance/ledger.json`（每次 request/params、原始回执、job/object/message id、
断言前后状态、负对照结果）。它是机器可读的证据，不是摘要。

---

## 2. 真实链路端到端（`tools/e2e-acceptance.py`）

**这一层不 import 生产源码、不手抄替身。** 它启动真二进制、说真协议、看真存储：

| 组件 | 真实性 |
|---|---|
| `gmgn-taskd` | 真子进程，私有临时 root + Unix socket（`--root`/`--socket`），世界状态只落它的 `world_records/world_facts` |
| 生成后端 | 测试夹具 `ThreadingHTTPServer`（回环随机端口），实现任务协议并返回合成 GLB；验证协议接线，不验证真实模型质量、生成耗时或线上可用性 |
| `gmgn-mcpd` | 真子进程，stdio JSON-RPC（`initialize` → `tools/list` → `tools/call`），UDS 连同一个 taskd |
| 播放器 | 真 `WKWebView`（离屏 `NSWindow`）加载**生产源码生成**的承载页 + 官方 `<iframe>`；真网络 |

### 2.1 意图 → 真实生成任务 → 权威入库 → 三轴尺寸

三轴意图（逐字送入 `submit.sizeIntent`）：

```json
{"mode":"dimensions","millimeters":{"x":1443,"y":862,"z":302},"source":"user"}
```

实际编号（本次运行）：

- wish / job：`10c9e6d5-ec41-4dea-9d0f-f7fc9c859b71`
  → job id `10C9E6D5-EC41-4DEA-9D0F-F7FC9C859B71`
- 世界：`e2e-world-5db10117`；物件：`wish-prop-10c9e6d5-ec41-4dea-9d0f-f7fc9c859b71`

事实回执（原始）：

- `world_import` → `{"imported":true,"revision":1,"facts":[{"id":"import:e2e-import","kind":"world.imported","seq":1}]}`
- `world_commit(upsertObject)` → `{"changedObjects":["wish-prop-10c9e6d5-…"],"facts":[{"id":"commit:e2e-place-1","kind":"object.registered"…}]}`

断言（都通过）：

- 任务落地 `backendStage=ready`；
- **远端 `POST /v1/jobs` 的 body 里没有 `size_intent` 键、只有 `height_meters=0.862`**
  —— 三轴意图恒定不发远端，归一在 app 侧（`model.rs::SizeIntentSupport::accepts` 的
  fail-closed 方向），逐字段核对通过；
- 回执带 `result.authoritative_size.dimensions == [1.443, 0.862, 0.302]`（逐轴）；
- 世界状态里解析 `metadata["gmgn.generated-prop.v1"].size == {x:1.443,y:0.862,z:0.302}`。

**负对照（必须红，实测红）**：同一个三轴意图，后端回 `[1.443, 0.9, 0.302]` ⇒
任务 `backendStage=interrupted`、`lastError=authoritative_size_conflicts_with_intent`。

**协商通路的正对照**：旧形状 `{axis:"longest",meters:1.1,source:"user"}` 时，远端确实收到
`size_intent` 逐字段相同（`/health` 声明 `axes:["height","longest"]`、`applies:"echo"`）。

### 2.2 摆放 → 手持 → 删除 → 恢复

- 摆放：`world_commit(upsertObject)` 落 `position={x:-2.7,y:0.52,z:-5.0}`，快照逐分量相等；
- 手持：`world_commit(setWorldFacts{heldProp:{objectID,slot:"rightHand"}})`，快照 `heldProp.objectID`
  指向同一件；
- 删除：`world_commit(deleteObject)` → `world_records` 里该行 `tombstone=true`（不是硬删行）、
  事实流出现 `object.removed`、活物件投影不再含它；
- 恢复：同一 `objectID` 重新 `upsertObject` → `tombstone=false`、revision 前进、回到活物件；
- **负对照**：重复删除不凭空再写一条墓碑；陈旧 `expectedRevision` ⇒ `revision_conflict`；
  同一 `requestID` 换内容 ⇒ `request_id_conflict`。

### 2.3 许愿通知 → 已读落盘 → 重载仍已读且不重复

走**居民**消息面（`state_commit` 的 `messages`，落 `resident_messages`）：

- `state_commit`（`domain=resident,key=inbox`，带一条 `kind=wish.placed`）→ `revision=1`；
- `message_read(consumer=ui)` → 恰一条，id 逐字等于投递的 message id；
- `message_ack(consumer=ui)` → ui 再读为空（角标少一）；
- **重启 taskd 后** ui 再读仍为空（已读跨重启存活、不重发、不重复）；
- **负对照**：`agent` 消费者仍能看到这一条（ack 只清一个消费者）；
- 重启后新投递的 `wish.failed` 对 ui 仍**未读**且恰一条。

（Swift 一侧的同一条通路——`ResidentSystemInboxStateStorage` 落库、旧 JSON 只读导入、
断电可见失败与恢复重试——由 §3 的 `test-resident-inbox-state-storage.swift` 用**真 taskd
子进程**跑，37 条断言全绿。）

### 2.4 MCP 只读 + 授权动作

- `tools/list` = 权威常量生成的 **10 条**工具（`gmgn_capability_contract / prop_submit /
  prop_cancel / prop_retry / prop_jobs_read / world_read / world_commit /
  world_facts_read / world_records_read / world_cursors_read`）；
- 只读 `gmgn_world_read` 无授权照常成功；
- **负对照**：无授权文件时 `gmgn_world_commit` 返回 `mcp_grant_not_configured`（不静默放行）；
- 杀掉 MCP 面后 taskd 仍应答（MCP 不是第二个权威）；
- `armed` 且点名 `gmgn_world_commit` 的授权文件 ⇒ 动作真的落到权威
  （回执 `structuredContent.ok=true`，事实 `commit:mcp-armed` 落库）；
- **负对照**：授权文件指向别的 socket ⇒ `mcp_grant_socket_mismatch`。

---

## 3. Swift 业务层（现编现跑生产源码）

`tools/e2e-acceptance.py` 的 `--only swift` 层依次现编现跑下列判据（`TASKD_BIN` 指向真
二进制），**12/12 退出码 0**：

| harness | 覆盖 |
|---|---|
| `test-resident-prop-size-intent.swift` | 三轴尺寸意图 → 世界 size（app 侧归一） |
| `test-resident-prop-world-collision.swift` | 碰撞盒与三轴尺寸同源 |
| `test-resident-prop-placement.swift` | 摆放判定 |
| `test-resident-prop-hold.swift` | 手持 / 挂点 |
| `test-resident-screen-app-wiring.swift` | 三条屏幕工具并进当轮 lease 的接线 |
| `test-resident-screen-capability.swift` | 屏幕功能点注册到物件 + 转发器（4 条注入负对照） |
| `test-resident-screen-idle-and-motion.swift` | 待机不挂 WebView / 运动降载 / 停下恢复（5 条注入负对照） |
| `test-resident-inbox-state-storage.swift` | 收件箱已读跨重启（**真 gmgn-taskd 子进程**，37 断言） |
| `test-resident-system-inbox.swift` | 收件箱已读 / 角标 / 终态锚点 |
| `test-wish-task-messages.swift` | 许愿消息出口 / 幂等 / 人话 |
| `test-resident-tool-schema-keys.swift` | 工具 schema 约束键门禁 |
| `test-stage-resident-chat.swift` | 居民聊天状态与键盘仲裁（本次修复后 197 断言） |

> 这一层是**源码切片 + 现编现跑**（生产源码原文编进临时 harness），不是进程级端到端；
> 进程级那一半在 §2。两层都跑过、都绿。

### 3.1 播放器（官方嵌入 + 播放时间前进）

`run_player_layer` 调用 `tools/probe-screen-embed-playback.swift`：

- 承载页 HTML 与 baseURL **由生产源码 `WorldScreenEmbedOrigin` / `WorldScreenEmbedPage` 生成**；
- iframe src 实测：`https://www.youtube.com/embed/aqz-KE-bpKQ?autoplay=1&enablejsapi=1&origin=http%3A%2F%2F127.0.0.1%3A50540`
  （官方绝对 https 地址 + 站方公开参数，未改主机/路径/id，未抓流、未绕登录/地区）；
- 实测 `PLAYBACK-VERDICT PLAYING currentTime 前进 9.11 秒（0.0 → … → 9.1）`，退出码 0。

**关键量具事实**：同一个探针**不放进窗口**时 `currentTime` 恒 0（`STALLED`）——离屏且不在
窗口里的 `WKWebView` 在 WebKit 眼里是"页面不可见"。生产里覆盖层在舞台窗口里，所以 §3.1
用离屏 `NSWindow`（`SCREEN_PLAYBACK_WINDOW=1`）才是与生产同形的量法。（这就是 handoff
§2.9「量具会骗人」那条。）

---

## 4. 门禁 / 构建 / Rust

见 §7 的实测记录（本节由运行的退出码与尾部填实）。

- `make test-harnesses`
- `make build`
- `cargo test --locked --manifest-path services/gmgn-taskd/Cargo.toml` → `132 passed; 0 failed`
- `cargo test --locked -p gmgn-mcpd` → 13 unit + `mcp_stdio` 6 + `no_direct_authority` 4，全绿
- `python3 services/gmgn-taskd/tests/process.py` / `local_memory_process.py`（真 taskd 子进程）

---

## 5. 未验证 / 明确模拟的范围（不许当成功）

0. **完整用户流程尚未验收**：生成服务使用测试夹具，世界入库/摆放由驱动器发送命令，
   Swift harness 和播放器分别运行。尚未在同一个宿主进程中验证「用户许愿 → 真实生成 →
   自动入世界 → 摆放/手持 → 屏幕画面 → 通知已读 → 重启恢复」；角色动作穿地也未在本轮做画面验收。

1. **真机 GPU 画面**：物件真正渲染、覆盖层真正合成到电视四边形的像素，需要宿主窗口与
   Metal。本环境没有辅助功能权限、也不启动已装宿主，所以这一层**未验**。已提供不需新权限
   的探针（`tools/probe-screen-overlay-compositing.swift`）与真实播放器探针，但"屏幕四角
   在真机显示器上的像素级贴合"仍要宿主里量。
2. **Twitch 自动播**：本仓历史记录本机测不出来（播放器不请求流）。本次只验了 YouTube。
3. **B 站黑屏**：handoff 记录与嵌入来源无关，本次未继续查。
4. **MCP 真机可用**：`gmgn-mcpd` 尚未打进 app `Contents/Helpers/`；本次验的是独立二进制。
5. **系统级 UI 点击注入**：本环境无辅助功能权限，未用 AppleScript/辅助功能；「操作屏幕」
   模式的真实点击由 `test-screen-operation-mode.swift` 的离屏合成覆盖（属源码切片层）。
6. **Swift 层是源码切片**：§3 的判定驱动生产源码，但不是真 app 进程；真 app 进程级的那一半
   在 §2（taskd/MCP）与 §3.1（WKWebView）。

---

## 6. handoff §3 三条状态（已更新）

| 线 | 状态 | 判据与实测 |
|---|---|---|
| **屏幕运动降载 / 停下恢复 / 待机不挂 WebView** | ✅ 完成 | `test-resident-screen-idle-and-motion.swift`：断言 11/12 全绿 + 5 条注入负对照全红（退出码 0）。待机 `constructedWebViewCount==0`；运动 119 帧降载 119、渲染档位最低 0.400、每帧均 0.021 ms；停下第一帧恢复 1.000 并写变换；亚像素 120 帧只写 17 次、最大对齐偏差 0.452 px。已进 `make test-harnesses`。 |
| **收件箱已读跨重启 + 稳定 eventID** | ✅ 完成 | `test-resident-inbox-state-storage.swift`（真 taskd，37 断言）、`test-resident-system-inbox.swift`、`test-wish-task-messages.swift` 全绿；`ResidentSystemInbox.apply` 以 `lastEventID` 判同一事件（终态漂移也不翻未读、不重锚）；进程层 `state_commit → message_read → message_ack → 重启仍已读` 由 `tools/e2e-acceptance.py` 实测。已进门禁。 |
| **居民当轮 lease 始终有屏幕三工具 + 物件描述含屏幕能力** | ✅ 完成 | `ResidentScreenTools` 三条工具由无条件 `WorldScreenControlRelay` 提供（不再挂 `screenStore`）；`WorldScreenCapabilityRegistry.derive` 与覆盖层同源；`read_owned_props` 回执在真的注册了屏幕时写 `screen` 行、`interaction_status` 不再是 `appearance_only`。`test-resident-screen-capability.swift`（3 断言 + 4 注入）与 `test-resident-screen-app-wiring.swift` 全绿。`living/probe` 真机验收仍需宿主。 |

### 6.1 本次顺手修掉的既有红

- `tools/test-stage-resident-chat.swift`：注入的 `ResidentChatTranscriptLine` 引用
  `ResidentChatTurn.Interruption`，但没把 `struct ResidentChatTurn` 切进来 ⇒ 编出的
  `UI.swift` 找不到该类型（handoff §4.6）。已补切片；并加 `-disable-sandbox`（与
  `test-agent-speech-playback.swift` 同一手法）让宏插件在受限环境里也能编。修后
  **197 断言 / 0 失败**。
- `tools/test-resident-screen-idle-and-motion.swift`：注入负对照「运动中不降载」的
  `expected` 串还是旧措辞「没有降到」，而生产判据已改成「运动中渲染档位最小只到 …」，
  于是注入虽然真的红了、harness 却误报 FAIL。已逐字对齐，5 条注入现在全红。
- `Makefile`：把 `test-resident-inbox-state-storage.swift` 挂进门禁（另两条新门禁
  `screen-capability` / `screen-idle-and-motion` 已由并行线挂上）；新增 `e2e-acceptance` 目标。

---

## 7. 实测记录（命令 / 退出码）

> 本节在运行结束后填实；`tmp/e2e-acceptance/ledger.json` 是机器可读的完整证据。

- `python3 tools/e2e-acceptance.py --ledger tmp/e2e-acceptance/ledger.json`
  → `E2E 断言 44 条，失败 0 条`，`E2E_EXIT=0`
  - 进程层 31 条（taskd+生成后端+世界+MCP）
  - Swift 层 12 条（12/12 退出码 0）
  - 播放器 1 条（YouTube `PLAYING`，currentTime 前进 12.93 s，退出码 0）
- `cargo test --locked --manifest-path services/gmgn-taskd/Cargo.toml`
  → `test result: ok. 132 passed; 0 failed`，`TASKD_TEST_EXIT=0`
- `cargo test --locked -p gmgn-mcpd`
  → 13 + 6 + 4 全绿，`MCPD_TEST_EXIT=0`
- `TASKD_BIN="$PWD/target/debug/gmgn-taskd" python3 services/gmgn-taskd/tests/process.py -v`
  → `Ran 19 tests … OK`，`PROCESS_EXIT=0`（真 taskd 子进程 + 回环 HTTP 后端）
- `TASKD_BIN="$PWD/target/debug/gmgn-taskd" python3 services/gmgn-taskd/tests/local_memory_process.py`
  → `Ran 5 tests … OK`，`MEMORY_EXIT=0`
- `make test-harnesses` → 见 §7.1
- `make build` → 见 §7.2

### 7.1 `make test-harnesses`

门禁走仓库 build lock 串行。本次运行时有多路并行 agent 的门禁/`generate` 在排队，所以下面
既记"命令与退出码"，也记环境层面的阻塞。

- 第 1 次：`GATE_EXIT=2`。前 7 步（`test-first-use-guidance` … `test-livecam-avatar-framing`）
  全过；停在 `test-livecam-panel-sizing.swift`，原始首行是
  `sandbox-exec: sandbox_apply: Operation not permitted`，随后是
  `external macro implementation type 'ObservationMacros.ObservableMacro' could not be found`。
  **这是环境层面**：受限沙箱禁止 Swift 编译器为宏插件再嵌套一层 `sandbox-exec`，凡是内层
  `swiftc` 编含 `@Observable` 的切片就会红；与本次改动无关。
- 修复（与仓库既有手法一致，`test-agent-speech-playback.swift` 早已这么做）：给 3 个门禁
  harness 的内层 `swiftc` 加 `-disable-sandbox` —— `test-livecam-panel-sizing.swift`、
  `test-livecam-no-occlusion.swift`、`test-wish-machine-app-runtime.swift`。只关编译器自己的
  插件沙箱，产物与判据一字不变。三个单独复跑：118 / 全过 / 127 断言，退出码 0。
- 第 2 次（修复后）：`GATE2_EXIT=2`，停在 `test-motion-playback-lifecycle.swift`（同类沙箱红），
  并按同样手法给 `test-motion-playback-lifecycle.swift` / `test-resident-jukebox-outcome.swift` /
  `test-living-resident-loop.swift` 的内层编译加了 `-disable-sandbox`（这三个单独复跑：
  PASS / 98 断言 / 215 断言，退出码 0）。
- 期间还撞上一条**并行线的真冲突**：另一条线（网站链接原生播放，yt-dlp）改了
  `WorldScreenState.swift` 引用它自己的 `Screen/LinkResolver/ScreenLinkContract.swift`，
  而 5 个屏幕 harness 的源码清单未同步 ⇒ 编译红；随后那条线**整体回退**（`LinkResolver/`、
  `NativeMedia/` 目录删除，`WorldScreenState.swift` 回到 HEAD），harness 里的引用也由它清理。
  我**没有**改那条线的生产代码；只等它回退完，再复跑。
- 最终（回退干净后）：**`GATE_FINAL2_EXIT=0`**，日志 `/tmp/gmgn-gate-final2.log`
  （69 条 `swift` recipe + `reconcile-generation-results.py --self-test`，0 个 `FAIL` / `Error`）。
  > 该次用私有锁 `DERIVED_DATA=/tmp/gmgn-gate-final2-derived` 跑：`_test-harnesses` 本身
  > 不用 DerivedData，只借锁串行；因为本机同时有 3+ 路并行 agent 反复抢同一把锁，用私有锁
  > 才能让本轮拿到**可归属**的退出码（不与他人构建并发写同一棵 DerivedData）。

> 说明：本环境没有辅助功能权限，也拿不到 `danger-full-access` 的审批通道（实测
> `requires approval, but no approval channel is available`），所以无法用"关掉沙箱"这条更
> 省事的路；`-disable-sandbox` 是能让门禁在受限环境里忠实跑完的最小改动。

### 7.2 `make build`

- 直接复跑：`BUILD2_EXIT=2`，卡在 xcodebuild 的包解析：
  `cannot open file '/Users/ghostcorn/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/*.dia' for diagnostics emission (Operation not permitted)`。
  这是 DSH 文件沙箱拒绝写 `~/Library/Caches`；`HOME=/tmp/...` 重定向对该路径**无效**
  （xcodebuild 仍用真实 home），`danger-full-access` 又无审批通道。
- 但本会话**存在一次成功的产品构建**：`apps/macos/Build.noindex/Build/Products/Release/gmgn radio.app/Contents/MacOS/gmgn radio`
  的 mtime = `2026-10-03 09:43:03`（Release，晚于最后一个提交 `0341b58`）。即"代码能编出产品"
  为真；只是**当前沙箱下无法由我复跑**。当前树的 `make build` **未验**，见 §5。

### 7.3 本次修掉的既有红（与 `make test-harnesses` 有关）

1. `tools/test-stage-resident-chat.swift`：补 `ResidentChatTurn` 切片 + `-disable-sandbox`；
   修后 197 断言 / 0 失败（此前编译期就红）。
2. `tools/test-resident-screen-idle-and-motion.swift`：注入负对照的 `expected` 串从旧措辞
   「没有降到」改成生产现措辞「运动中渲染档位最小只到」；修后 5 条注入全红。
3. `Makefile`：挂进 `test-resident-inbox-state-storage.swift`；新增 `e2e-acceptance` 目标。
4. 受限沙箱下的宏插件红（`sandbox-exec` 不能嵌套）：给 6 个门禁 harness 的内层编译加
   `-disable-sandbox` —— `test-livecam-panel-sizing.swift`、`test-livecam-no-occlusion.swift`、
   `test-wish-machine-app-runtime.swift`、`test-motion-playback-lifecycle.swift`、
   `test-resident-jukebox-outcome.swift`、`test-living-resident-loop.swift`（另加
   `test-stage-resident-chat.swift`）。只关编译器自己的插件沙箱，判据一字不变。

### 2026-10-06 Unity v90 实际应用检查（未完成全量验收）

- Unity 6000.6 构建、Swift 宿主构建及 v90 打包均退出 0；已关闭 v89，启动 v90。
- 从基础物件菜单分别选择点唱机和许愿机：实际加载真实点唱机 GLB 和托盘 v2 GLB，
  当前 Player.log 两者均有 `BuiltinDeviceVisual verified=true`，画面显示托盘而非售货机。
- 修正新物件/库存预览的手势起点：手势位置独立于取消操作所需的原位置，避免首次拖动跳位。
- 本轮自动拖动未证明正式保存：日志显示 pointer down 落在拖动终点，预览被取消；
  不能将加载模型、构建成功或原有隔离测试当作摆放成功。
- 设置移除与已连接宿主不符的“按住说话与自主行动尚未接入”说明；
  `python3 tools/test-unity-push-to-talk.py` 退出 0，仅覆盖注入设备/网络边界的桥接行为。
- 仍需实际摆放 CAS 保存及重启读回、角色走到设备并执行、实际聊天语音/思考云、消息通知，
  以及原 SceneKit 全功能页面与端到端对照。整体目标未完成。

### 2026-10-06 Unity v93 聊天实测（失败定位）

- v93 Unity、Swift 宿主构建与签名打包通过，关闭 v92 后启动 v93。
- 实际 UI 发送“你好，只回复你好。”，头顶思考云出现；最终失败，不能作为聊天或语音通过。
- 安全日志记录 `ResidentACP error method=session/prompt tags=disposed`。
  上游 ACP 在消息入队前检查注册的 agent 与会话持有的 agent 身份，拒绝已释放的 agent。
  需继续核对注册/释放时序；此证据尚不能确认释放原因，不能归因为模型接口或 TTS。
- 24 项 ACP 组装测试通过但使用 mock provider，与实际应用上述失败分别记录。

### 2026-10-06 Unity v94 实际聊天恢复

- 将测试调整为生产的握手前 revoke、发送前 arm 顺序，先复现失败；
  随后分离只含工具定义的 bootstrap 与可撤销的执行 grant，26 项检查通过。
- v94 宿主/Unity 构建及签名打包通过。关闭 v93 后，实际 UI 发送“你好，只回复你好。”，
  实际模型返回“你好。”，画面可见，日志 `event kind=reply`、`completed failed=False`。
- 这证明本轮实际文本回复恢复，不证明语音、设备交互或全量迁移完成。

### 2026-10-06 v95–v98 语音与聊天布局

- v95 实际介绍回复触发 `UnitySpeech playback=started` 与 `stopped`；播放期间正式设置快照
  `isReplyPlaying=true`、`replyLevel=0.028791526`。证明音频播放链产生了实际播放状态和电平，
  尚未完成听感与口型视觉验收。
- v96 虚拟列表文本宽度调整未解决实际布局问题。v97 改为复用消息元素的普通 ScrollView，
  实测正文开始换行，但角色标签重叠、滚轮到底仍未通过。
- v98 增加消息布局数值诊断，用于核对 viewport、content、滚动上限及标签实际尺寸；
  此版本不能标记为聊天滚动验收通过。
- Kipfel 原始项目包含表情动画和 ABT 坐姿、躺姿、姿势切换动画；`Sit1.anim` 含 Humanoid
  肌肉曲线。尚未核对这些附带第三方动画的外部使用授权，未复制进交付资源。
- v99 延迟诊断确认回复更新后角色标签被收缩为 0 高度。v100 禁止角色标签和内容容器收缩，
  实际滚轮往返可到达首条消息和回复最后一行；角色标签保留 17.5 高度。
  但长回复正文仍超出消息背景范围，单条消息高度计算尚待修复，聊天整体暂不标为通过。

### 2026-10-06 v101–v102 正文高度及 DSH 工具状态

- v101 按实际字体和宽度测量正文高度。真实长回复正文高度 163、消息高度 200.5，
  角色标签 17.5；画面正文完整处于消息背景内，滚轮可查看首条消息和回复末尾。
  该结果仅覆盖当前窗口长回复，尚需多轮与小窗宽度回归。
- 实际要求角色走到点唱机并播放歌单，v101 仅描述不能操作。源码确认宿主已有 DSH 工具通道，
  但 AgentConversationService 接收到 worldTools=nil，生成了只读 prompt。
- v102 增加仅对已注入 DSH 原生连接器和有效世界上下文开放的 nativeToolsAvailable，
  同步动作能力提示和工具会话记忆范围；前台与后台均接入，未创建重复工具通道。
- 21 项 resident routing 检查通过（测试补齐生产 RetryBackoff 编译依赖）；Swift 宿主、Unity
  构建和打包通过。实际 v102 再次发送执行请求，回复报告设备/播放器问题，角色未移动且
  未产生播放结果。此项仍未通过，不能依据能力提示修复宣称操作链完整。
- 增加仅含已注册工具名、布尔结果和规范错误码的 ResidentTool 日志，下一版核对失败边界，
  不记录工具参数、原始返回体或凭据。

### 2026-10-06 v103–v107 音乐工具与导航接线

- v103 实际请求明确返回 radio_unavailable 和 route_blocked。音乐临时包装对象只被弱引用，
  ResidentMusicToolBridge 现持有动作对象到工具租期结束。新增生命周期测试先失败后通过，
  39 项音乐检查通过；v104 真实 read_current_track / list_music_playlists 成功。
- Unity 原先未安装原 SceneKit 使用的生活舱碰撞 GLB，家具碰撞体没有角色脚下的地面。
  v105 复用原场景 framing 和坐标转换，安装 161600 个三角形及独立家具体积。
  使用真实 bundled collider 的导航回归通过；实际操作不再返回 route_blocked。
- v106 实际操作仍失败，系统日志证实 local=1471 / authority=1472：新会话构造后旧会话
  关闭时额外 checkpoint 使新会话版本失效。Unity 投影退休现不再保存，常规 stop 默认保存
  保留；两种停止行为及真实舱体导航回归均通过。v107 宿主和 Unity 构建通过。
- v107 实际完整走路、点唱机动作、播放与语音仍待验收，不以构建或导航回归代替。
- v107 实测 move_to 成功，画面确认角色从出生点移动到点唱机入口；没有再出现 checkpoint
  版本冲突。list/read playlist 和 prepare_music_track 成功，但 resume_music / play_program_track
  仍返回 tool_failed。物件功能点、操作动作与渲染确认继续排查，播放操作链未通过。
- 全仓 git diff --check 仍报 Unity 自动生成的字体、Localization 与 Addressables 文件尾随空格；
  本轮手改 Swift/测试/文档无此问题，尚未进行最终提交检查。

### 2026-10-06 v108–v109 物件摆放实际验收

- 权威空间读回没有 prop.jukebox / wish_machine.device；旧画面中的物件不能替代正式功能点。
- 基本物件目录支持选择后点击地面放置，仍经真实几何校验、CAS 保存和单独读回。
- v108 实际请求超过 12 MiB。v109 将 Swift Float 以精确 round-trip 十进制传输，保留全部
  几何面和 f32 位值；真实桥接序列化回归通过，宿主及 Unity 构建通过。
- v109 实际摆放请求 12209892 字节，传输完成。中央、远处和左侧地面尝试仍被
  blockedByMesh 拒绝，尚未保存点唱机。新增受控判定和支撑高度日志以继续定位；
  最新支撑高度日志尚未装入运行版本。不能据此宣布物件操作或全功能验收完成。

### 2026-10-06 v110–v111 保存传输入口

- 右侧地面实际 canPlace=true，取消发生在保存前：world.device.place 曾走 256 KiB
  普通命令入口，携带完整几何的请求被入口拒绝。改为独立、有界的字节入口，后台解码；
  普通命令限制保持不变，保存仍经几何校验、CAS 和独立读回。
- 新增超过 256 KiB 的真实桥异步提交回归，成功保存一次；原有拒绝、CAS、读回、
  元数据及功能点测试通过。宿主、Unity v111 构建及打包通过。
- v111 点击基本物件/点唱机/地面后，正式权威读回 recordRevision=1481，prop.jukebox
  已启用，位置 (-1.5,0.015194416,2.210000038)，包含 gmgn.builtin-device.v1。
- 保存后画面未保留实体，渲染恢复链仍待修复；许愿托盘尚未正式放置，角色操作、
  播放、语音和通知完整验收仍未完成。本轮没有提交/推送，也没有清理工作树。

### 2026-10-06 v112–v115 摆放投影与局部几何

- 保存回执中的权威记录先进入渲染投影，再恢复物件，旧版本投影不会覆盖新版。
- 环境三角形改为候选占地局部查询；完整已摆物件网格保留。跨越查询的大三角形、
  0.01m 接触边界、面顺序及空查询回归通过。真实请求约 5.44 MB，约 0.44 秒。
- v114 实测 Retina 面板 (650,318) 对应 framebuffer (1300,356)，2048×992。
  已有物件拾取也改为相同的反向坐标映射；该拾取变更通过 Unity 编译回归。
- v114 左侧区域许愿机 canPlace=true，经生产保存及单独快照读回 recordRevision=1482。
  wish_machine.device 已启用，位置 (-2.299999952,-0.029325878,1.149999976)。
- 保存后托盘在镜头下方，尚未通过视觉验收。发现新物件点击使用初始预览高度的平面，
  降到地面会偏离点击位置；v115 改为实际场景碰撞表面定位，待运行验证。
- 角色走到设备、使用、音乐播放、语音、通知与全部页面仍须完整端到端验收。

### 2026-10-06 v116–v119 启动恢复与真实表面拾取

- 已摆设备支持从基本物件目录重新进入摆放，无重复实体；取消恢复原始位置。
  真实控制器回归先失败后通过，尚未替代真实保存验收。
- 持久化 music.listen 恢复必须先安装环境碰撞查询；导航行为回归先失败后通过。
- 启动改为渲染准备完成后仅建立一个活动世界上下文，避免早启动上下文推进状态
  导致第二次激活校验失败。v118 实际重启 prepare → activate 成功，空间、VRM
  及两个生成设备模型均加载。运行帧率约 61–69 FPS，尚未达到稳定 75 FPS 验收。
- v118 实际摆放仍失败：环境只有业务三角网格，没有 Unity Physics Collider，
  Physics.RaycastAll 没命中，预览沿用原位置并被 blockedByPlacedProp 拒绝。
  v119 改为直接拾取同一环境三角网格；地面命中、Z 坐标转换及越界拒绝回归通过，
  v119 构建及打包通过。实际点击右侧和中央地面时模型确实移动到鼠标对应位置，
  拾取修复已运行验证；最终几何校验仍返回 blockedByMesh，取消且不保存。
  候选列 (3,-4)、(-3,-20)，支撑高度分别 -0.00558、-0.05642；继续定位
  占地支撑与环境网格相交问题，不能将预览命中当作摆放保存通过。
- 实际 agent 能走到点唱机并发现空队列；读取同步歌单后已准备歌词，但后续请求
  transport_timed_out，播放未通过。新增活动渲染门禁诊断，不降低动作与到达门禁。
- 全目标仍未完成；音乐实际播放、语音、操作动作、通知及其他页面须继续验收。

### 2026-10-06 v120–v121 编辑与活动共享权威版本

- v119 左侧平台实际 canPlace=true，但提交 revision_conflict；活动检查点在编辑期间
  改变了权威版本。编辑开始现保存检查点并暂停世界推进，结束后读回再恢复运行。
- v120 真实鼠标摆放点唱机保存成功，独立读回 recordRevision=1516、geometryMatches=true，
  位置 (-4.5,0.0198940635,-1.29)。模型留在左侧平台，v121 重启后仍恢复到该位置。
- 后续编辑暴露持久化组件仍持有旧 CAS 版本：expectedRevision=1515 的检查点
  stale_projection。v121 权威读回改为通过同一持久化组件 load 同步状态与提交版本。
  宿主/Unity 构建、打包及导航行为回归通过。实际再次进入编辑并取消后未出现
  WorldCheckpoint 失败，两个设备保持原有布局；更多连续保存回归仍待验证。
- 许愿托盘两次新候选位置 noSupport，均取消未保存；此前正式摆放位置仍保留。
  拉远镜头后已实际看到完整托盘在地面，点唱机在左侧平台，角色在点唱机旁。
- v121 已通过真实聊天请求再次执行读取同步歌单并使用点唱机播放，思考云实际显示；
  当前执行结果待观察，不能宣布播放/语音/物件动作完整验收成功。

### v122–v123 实测继续（2026-10-06）

- v122 真实聊天触发 move_to 成功，到达点唱机并进入 music.listen 循环阶段；
  实际渲染门槛以 motion_id_or_readiness_mismatch 拒绝播放。原音乐动作仅有 VMD，
  当前 Kipfel 为 VRM，不能把这次工具失败计为音乐验收成功。
- 新增离线原 VMD→VRMA 转换，使用 PMX 标准骨骼重命名、Unity Humanoid 重定向及
  UniVRM 导出。真实转换完成：11.167 秒、336 帧、300348 字节；原 VMD 保留。
  PMX/VRM 音乐选择回归先失败后通过，动作来源回归通过。
- 修复打包遗漏内置 MMDMotions：v123 包含原 VMD 和派生 VRMA。宿主、Unity 构建及
  签名验证通过，已关闭 v122 并实际启动 v123。
- v123 首次恢复播放请求读取歌曲/状态成功，但恢复工具失败，回复语音日志已启动；
  已发起从同步 City Pop 歌单实际选曲播放的第二次 UI 请求，结果仍待读回。
  角色材质、完整设备操作动作、音频实听及所有页面端到端仍未全面验收。
- 第二次真实 UI 请求已读回：list_music_playlists、read_music_playlist、
  prepare_music_track、start_activity、resume_music、read_current_track 均 ok=1；
  聊天完成并启动回复语音。画面显示播放中按钮、同步歌词，角色位于点唱机旁，
  回复能够读出当前歌曲及下一首。完整动作质量与实际音频仍需独立验收。
- 材质排查新增导入边界诊断并在真实 Kipfel 上运行：全部材质为可用的官方
  URP MToon10，主贴图成功绑定（1024–4096 像素）；真实高度与落地检查通过。
  这仅排除 Editor 导入缺图/无着色器，最终 Player 颜色质量仍待对比，不宣布修复。
- 已经通过真实聊天发出只读许愿状态检查，明确禁止新生成、重复领取和摆放修改；
  工具执行结果待读回，不能将发出请求当作许愿链路完成。
- 只读许愿请求此前未实际提交，已核对输入内容重新发送。真实 request=3 中
  read_wish_generation、read_wish_machine_contract、inspect_world 均 ok=1；未生成、
  领取或改变摆放。完整历史任务/库存差异仍需逐条权威核对。
- 实际通知面板持续 Loading。定位到宿主先 worldSession.snapshot 消费 inbox 完整
  响应，后 inbox.snapshot 再读仅得到紧凑版本脉冲，导致 Unity 丢失终态。
  已改用 worldServices 中同轮快照，宿主 v124 构建中，真实通知回归尚未完成。
- v124 宿主和 Unity 构建、打包签名通过；已关闭 v123 并启动新实例。
  实际打开通知列表，已从持续 Loading 恢复为 Notifications updated，显示已有
  电视摆放/删除历史通知。通知桥离线回归通过，但既有条目为已读，未读→已读
  的真实提交与重启读回仍待专门验收。
- 打开详情实际暴露英文按钮挤压标题的布局错误；通知头部操作已按音乐库既有
  设计改为固定尺寸图标按钮，提示仍本地化。v125 构建中，尚未视觉验收。
- v124 Player 日志确认与 Editor 同样全部绑定真实 MToon 主贴图，着色器 supported；
  颜色外观对齐尚未完成，不能把材质绑定成功当作渲染质量通过。
- v125 打包并启动后，真实通知列表和详情头部图标视觉验收通过，标题不再被英文
  操作按钮挤压。真实聊天 request=1 的 move_to、inspect_world、read_wish_generation
  返回成功，语音播放开始；但角色实际停在房间后方，不能据此判定到达已移动托盘。
- 查明独立 move_to/地点快照仍消费种子路点，而设备活动使用保存后的功能点。
  新增移动后地点/路线回归，先观察失败，再将种子设备路点映射到当前注册功能点。
  碰撞、落地、最终接近仍经原有检查；内部活动寻路保留原始路点以免重复接近。
  离线 55 项检查通过，包含真实移动执行到达、收回后地点消失与拒绝旧位置寻路。
  v126 宿主构建通过，运行窗口端到端回归仍待验收，不宣布全目标完成。
- v126 Unity 构建、打包通过，关闭旧 v125 后启动唯一新实例（PID 14150）。
  真实聊天明确调用 move_to(wish_machine.pickup)，后续 inspect_world 四次成功，
  语音开始播放。只读权威快照 recordRevision=1580 核对角色位置
  (-2.3,-0.033151638,0.19999999)，正是当前托盘位置 (-2.3,-0.029325878,1.15)
  前方局部 pickup 偏移的落地点；点唱机与托盘保存位置未改变。实际画面角色由
  房间后方移动到前方。该项导航验收通过，材质外观、走路质量、操作动作等未完成。

### v127 语音模型接线继续（2026-10-06）

- 真实 Kipfel 导入包含已绑定元音形变。新增真实 VRM 与原音乐 VRMA 组合检查，
  库运行时处理后口型为 80%，停止后为 0；并未发现当前音乐动作覆盖口型。
  Editor 组合检查不能替代真实扬声器实听和说话录像验收。
- 查明 PMX 完全未接收 Unity 回复语音事件，新增对应连接与 VMD 之后的口型更新。
  真实 PMX 回归先以缺少口型绑定失败，随后暴露导入未初始化 renamedName，所有
  形变被构建为匿名名称。补官方 PMXRenameUtilities 初始化，按原始元音名找到
  官方派生后的网格名称，无另造固定索引。
- 真实原 2B 模型与原 iluvslapbass VMD 回归通过：动作绑定成功，待机/动作期间
  口型 80%，停止 0%。v127 Player 构建、打包和实际启动通过，旧 v126 已关闭。
- 实际 GPUI 设置切换到 2B，Player ready revision=6 与原 PMX 待机动作一致。
  真实聊天出现头顶思考云，完成回复 failed=False；语音播放日志开始于
  07:42:59.085，停止于 07:43:26.127。角色背对当前镜头，截图不足以验收实际
  口型或扬声器实听；保留这两项未完成。随后通过同一设置恢复原 Kipfel，
  Player ready revision=7。发现聊天角色标签和角色切换提示仍有中文遗漏，待补。
  材质、走路质量、设备操作动作和完整通知闭环等全目标仍未完成。

### v128 聊天翻译接线（2026-10-06）

- 聊天角色标签改为保存翻译键，现有消息可随语言切换重新绑定；发送失败、
  回复失败前缀、回复占位和重新编辑提示使用已有中英日 String Table 条目。
  保留真实流式回复文本，不用“正在回复”覆盖已经收到的内容。
- Unity 构建退出 0、完整宿主打包退出 0；关闭已核对路径的 v127 PID 16622，
  启动 v128。修改的 PlayerScreen.cs diff-check 通过；仓库整体检查仍报告
  Unity 生成资源的尾随空格，未手改这些资源。运行窗口多语言回归仍待验收。
- v128 实际英文聊天显示 Character 标签和英文等待提示，未再出现写死的中文
  角色标签。真实点唱机请求依次调用 list_music_playlists、inspect_world、
  read_music_playlist、move_to、prepare_music_track、start_activity、resume_music、
  read_current_track，均 ok=1。窗口播放按钮进入暂停图标状态，歌词实际显示；
  回复语音 07:54:14.993 开始，07:54:45.467 停止。
- 只读权威快照 revision=1589：角色位置 (-5.2,0.02139667,-1.29)，位于保存的
  点唱机 (-4.5,0.019894063,-1.29) 侧面操作点；activeActivity=music.listen，running。
  该证据证明设备位置寻路与音乐链路，不能证明走路质量、手部操作动作、口型
  或扬声器实听通过；这些保持待验收，不能将 start_activity 成功替代动作验收。

### v129 真实动作投影核验（2026-10-06）

- 加入只在阶段动作加载完成后输出的 ResidentMotion 记录，保留原渲染确认门禁。
  构建、打包退出 0，关闭 v128 PID 18333 后启动 v129 PID 19169。
- 实际恢复 music.listen loop 时加载 builtin.motion.iluvslapbass-vrm，ready=True；
  真实聊天停止活动后恢复 idle-loop-vrm，随后 move_to(wish_machine.pickup) 时
  加载 walk-loop-vrm，ready=True；到达后恢复 idle-loop-vrm。工具 stop_activity、
  move_to、inspect_world 成功，聊天完成 failed=False。该证据证明真实行走期间
  使用行走动作而非待机；骨骼姿态质量、手部设备操作仍需视觉验收。

### v129 通知窗口与存储核验（2026-10-06）

- 后台窗口坐标点击没有响应，键盘激活窗口后通知按钮正常工作。真实通知列表
  显示原空间事件、Read 状态，打开首条详情成功；未以后台点击失败认定业务失败。
- 使用当前 UnityInboxBridge、ResidentSystemInboxStateStorage、ResidentStateClient
  编译现有 test-unity-inbox-bridge.swift，退出 0。生产去重、新状态重新未读、
  重启恢复、读回失败保留未读、CAS 冲突、旧事件拒绝和关闭后拒绝操作回归通过。
  该测试的传输为隔离测试替身，不能替代真实 taskd 新事件到达验收。
- 当前真实通知均为已读，未造生产通知或重放原任务。新事件→未读徽标→打开
  详情→已读持久化→重启恢复的完整窗口闭环仍待真实事件验证。

### Kipfel 阴影纹理转换排查（2026-10-06）

- 现有 VRM 所有 MToon 材质缺少 shadeMultiplyTexture。原转换脚本在源
  _ShadowColorTex 为空时将 _ShadeTex 留空；本地 lilToon shader 明确先将主
  albedo 与阴影覆盖纹理按 alpha 混合，再乘阴影色。空覆盖纹理应保留主纹理。
- 修正独立转换脚本的空阴影纹理分支为已烘焙主纹理，新增独立导出路径环境项，
  候选 kipfel-shade-candidate.vrm，不覆盖用户当前模型。该脚本位于 tmp 转换
  工程，修复尚需移入可追踪的正式转换工具和回归，不能算产品交付完成。
- 首次用 6000.6 编辑器失败于该 VRChat 2022 SDK 的 obsolete API 编译错误；
  原资产工程版本 2022.3.22f1 批处理会话 47241 退出 1，日志显示 headless
  许可证未激活。未改凭据或授权设置，改用普通编辑器执行独立候选导出。
  播放器保持 6000.6；候选导出及视觉对比尚未确认。
- 2022 普通编辑器同样报告 com.unity.editor.ui 许可证未激活，核对 PID 21106
  后终止该导出进程，没有更改许可证、凭据或系统授权。
- 新增可追踪 tools/repair-kipfel-shadow.mjs，只接受本项目 assembled conversion，
  在独立候选中补 9 个 shadeMultiplyTexture 引用，拒绝覆盖文件。候选保存
  tmp/kipfel-vrm-conversion/kipfel-shadow-repaired.vrm；GLB 非 JSON 块保持原样。
- Unity 6000.6 CharacterSpeechChecks 实际导入候选：每个材质的 _ShadeTex 与
  _MainTex 引用一致，原音乐 VRMA 与语音口型/停止归零检查通过，执行会话
  67923 退出 0，日志 tmp/unity-shadow-candidate-check.log。用户当前模型未变，
  真实播放器外观对比及正式转换工具的阴影覆盖混合支持仍待完成。
# 2026-10-06 实际导入候选与设置连接复验

- 从 v129 的统一 GPUI 设置实际导入独立 `kipfel-shadow-repaired.vrm`，保留原始 Kipfel；新包 `vrm.4a92feef-37df-4d9b-871a-c22dc6228216` 实际切换完成，Player 日志 `CharacterSelection ready revision=12`，idle VRMA ready。
- 实际画面仍呈紫色背面，不能据纹理绑定测试宣布外观对齐。需继续核查转换材质及正面效果。
- 原生角色文件选择器打开时 GPUI 显示连接断开；确认 `PresenceSettingsModel.importModel/importMotion` 使用同步 `runModal`，设置 HTTP 请求有 2 秒读超时。已改成保留面板的异步 `begin` 回调，防止重复打开，待新 Host 构建及实际文件选择期间连接复验。当前 v129 尚未加载该修复。
- 角色切换提示与原生文件选择器文案仍有中文，英语完整性未通过。

### v130 导入连接实际复验

- `build-unity-player-sample.sh integrated-v130` 构建、打包退出 0，关闭已核验的 v129 PID 19169，再启动 v130；原空间和已安装角色保留。
- 通过实际 GPUI 打开角色模型选择窗口，窗口保持打开超过原 2 秒读超时后设置页没有断开提示；取消后无需重开设置，选中 2B，Player `CharacterSelection ready revision=7` 与 PMX idle ready。随后切回独立修复候选，`ready revision=8` 与 VRM idle ready。
- 这证明角色导入窗口的同步阻塞修复已运行生效；动作导入窗口同样改用异步回调，但该窗口的实际复验尚未完成。
- 初始载入期间出现中文“活动动作与当前角色不兼容”，随后实际 VRM idle ready；启动暂态提示及 i18n 仍需核查，不能当作全功能通过。

### v131 启动动作竞态修复

- 实际 `CharacterWorldAdapter` 回归：模型尚未载入时输入必需 VRMA 活动。旧代码测试退出 1，明确错误为 `Pending character load was reported as incompatible`；新代码测试退出 0，未报告格式错误，`motionReady/motionPlaying` 均为 false。模型提交仍清空活动键，下一投影继续加载真实动作；未降低物件效果门禁。
- v131 构建完成。打包首次因 macOS `mktemp` 模板把 X 放在扩展名前导致名称冲突失败；改为末尾 X 模板，保留已有出处文件，不覆盖，重新打包退出 0。关闭 v130 PID 22654，启动 v131；实际启动截图没有原有“活动动作与当前角色不兼容”提示。
- 原世界定义的许愿领取 enter/loop 没有动作 ID，点唱机 enter 也没有动作 ID。现有到位、音乐循环证据不支持手部操作完成；此项仍待完整实现与可见验收。已发现安装的 ARPG standing pickup 候选，需核查实际骨骼轨迹与设备高度，不能直接以名字判定适配。

### 实际交互动作轨迹测量

- 新增 `VrmInteractionReachChecks`：实际载入用户已安装的修复候选 Kipfel、UniVRM 控制骨架以及已安装的 `interact-button-mid-vrm` / `pickup-standing-vrm`，逐时刻采样真实手部与髋部位置，未创建物件或修改世界状态。Editor 会话 36716 退出 0，日志 `tmp/interaction-reach-kipfel.log`。
- 两个实际 clip 均为 3.5 秒。按键右手 t=2.1 秒的位置约 (-0.0244, 0.8628, 0.6311) 米，拾取右手 t=1.05 秒约 (0.1079, 0.2596, 0.5479) 米；这些是归一化角色根局部位置，尚未应用设备锚点、世界朝向和接触约束。
- 现有设备 enter 阶段固定 0.6 秒，会早于主要手部操作结束。托盘 pickup 站位距根 0.95 米，交互点在本地 z=-0.4、y=0.12；需要继续做设备坐标系接触对照和动作阶段回执。不能将本次轨迹测量当作接触成功，不能只增加动作 ID 后宣布完成。
### 通知工具栏接线补齐（2026-10-06）

- 审查发现 InboxPanel 的真实 UnreadChanged 未连接 PlayerScreen；补到普通窗口与
  小窗的邮件入口，保持打开面板不自动标已读、详情点击才请求持久化的行为。
- Unity 6000.6 实际 UIElements 回归先因缺失投影失败，再验证两个入口的
  2→0→105→1 未读变化、零时隐藏、99+ 上限及不重复创建角标，退出 0。
  颜色对齐原 SceneKit 红底白字。该测试不替代真实新任务通知的端到端验收。
- v135 构建和打包退出 0；随后统一角标颜色，另起 v136 新包以保持产物与源码一致。
  v136 构建、打包退出 0，已关闭 v134 并启动 v136（PID 32995）；空间、角色及
  两个生成设备实际恢复。新版 GPUI 英文按住说话说明已确认生效。
- 清理已核对路径的 v127/v129/v130 三个遗留设置进程；未关闭其他产品进程。
  v136 真实角色执行点唱机请求，按钮动作自然切到循环，resume_music 与
  read_current_track 均成功；进程限定音频采样 AUDIBLE_CONFIRMED，RMS 0.1333。
- 实际英文设置底部发现宿主 notice 文案与翻译键不一致，修正翻译目录，六项
  i18n 测试通过。此最后文案改动尚未装入正在运行的 v136 包。

### v167–v168 现场验收（2026-10-06 22:22 起）

- 设备准备的正式无变更读回此前会回退当前活动版本；修复为仅在实际 CAS 提交后同步所有者。主代理独立运行 `tools/test-unity-jukebox-preparation.swift` 退出 0：无变更时 revision 20 保持 20，活动 elapsed 2.9 保留；实际升级仍提交、读回并恰好同步一次，接触和有限动作完成门槛保留。
- v167 构建、完整打包退出 0。在实际默认空间、Kipfel 与原点唱机上播放《Phantom Liberty》，通过居民会话请求切下一曲一次、读回、停止。真实 ENTER 回执手部距离为 0，随后 LOOP 动作 ready；22:22:36 `next_track`、22:22:37 `read_current_track`、22:22:39 `stop_activity` 均为 `ok=1/replayed=0`。实际列表高亮《Never Looking Back》。日志保存在 `tmp/unity-player-runtime-v167.log`。
- 现场发现歌单顶部仍显示旧曲名，补为订阅实时播放快照且拒绝晚到响应覆盖。v168 构建、打包退出 0；实际手动下一曲后，顶部与列表均显示《Never Looking Back》，确认显示同步生效。
- Unity 包复用固定 SHA 的官方 yt-dlp 2026.06.09 缓存。首次 v166 完整签名因 `Contents/Helpers` 下校验文件被视作未签名嵌套代码失败；复用既有产品 `Resources/Helpers` 和相对软链接布局后，v167/v168 严格深度签名与 helper 哈希、版本校验均通过。未引入 cookie 或新下载。
- v168 请求公开官方 YouTube 视频时，helper 实际运行，原生加载终态为 `output_unreadable`；有界诊断明确 `phase=native_asset/domain=AVFoundationErrorDomain/numericCode=-11828`。这不构成视频播放通过。正在验证加载器类型契约修复，尚未在该包生效。
- v167 独立开合跳请求成功接受并走到锚点，但实际日志停留 ENTER，未观察到开合跳 LOOP。后续独立 `stop_activity` 和 `inspect_world` 均成功，但现场姿态仍有疑点。此项继续排查，不能用模型的“running”回复替代动作验收；整体功能对齐仍未完成。

### v169–v171 后续现场验收

- 原生资源加载器将 HTTP MIME 转成 AVFoundation 要求的 UTI；无扩展名 H264 MP4/AAC M4A 的真实 AVAsset 回归通过。随后实际 YouTube 请求已越过原 -11828，但视频分段与音频请求遇到上游 HTTP 403，没有解码帧或音频样本。补齐非 200/206 与提前空响应的错误传播，未更改网站许可、cookie、请求范围或下载策略。
- v170 实际公开 Bilibili 请求终态 `helper_failed`。单次只读元数据诊断确定上游 HTTP 412；两个公开视频样例均未通过播放验收。
- 开合跳根因为已安装的 VRMA 缺少动作白名单。仅补该真实动作 ID，保留未知、未安装与格式门禁。v170 于 23:03:44 真实进入 LOOP，动作 ready；23:03:55 自然 EXIT 后恢复 idle。正式 taskd 读回 `activeActivity=null`，验证退出状态已持久化。
- v169 真实朗读时仅采样对应 Player 进程，`AUDIBLE_CONFIRMED`，RMS 0.03047，未使用全局音频采样。该结果证明软件音频输出，不代表主观音质验收。
- v171 构建、完整打包和严格签名退出 0，实际启动 PID 48662。23:15:33–23:15:53 的真实朗读中，aaTarget、aaRuntime 与实际蒙皮 blendshape 一致；全程最大 rawLevel 0.102793，最大 appliedPercent 20.55867，停止后均归零。未证明驱动断链或 idle 动作覆盖；未据此擅改增益。小窗画面中口型仍不明显，视觉效果对齐尚未确认。
- v171 真实聊天 request=2 的一米移动在 23:19:28 执行 `move_to` 成功，随后 `inspect_world` 成功；截图未覆盖该短路线运动过程，不据此判定步态通过。request=3 于 23:21:02 导航到现有点唱机，未请求设备活动或改变播放。
- request=4 于 23:21:58 执行返回舱内中心的 `move_to`。连续采集 100 张应用窗口画面，核对运动阶段及终点：可见抬脚、路线转向、镜头跟随，随后恢复站姿；无新物件或设备操作。此证据限定当前 Kipfel 空手路线，未覆盖持剑步态、另一角色或近景足部滑动的精细验收。
- v171 从已安装 Unity Core 包文档导入 `light-anchor-animation.mp4`（2 秒、无音频轨），设置显示使用中，切换播放器视图后可见真实视频背景。与源帧 `tmp/unity-local-video-source-v171.png` 对照，实际背景上下翻转；此项未通过方向验收。仅检查本地播放器背景，不扩展为电视网页或音频通过。
- 同一实际视频点击停止后，播放按钮灰显且直接点击不恢复。保留当前停止状态，分别排查 Unity 背景 UV 与 Unity 播放入口的可恢复语义，未改变共享播放器禁用门槛、网络访问或素材权限。当前日志保存为 `tmp/unity-player-runtime-v171.log`。
- 实际 GPUI 将自动朗读从 on 改为 off，v171 request=5 正常收到指定英文短句，未产生新的 UnitySpeech started；随后设置恢复 on 并读回。验证设置被实际回复链消费，未改变 TTS 凭据或声音。
- 本地视频方向修复限定背景 `Image.uv=(0,1,1,-1)`；真实 UI/Metal 外部纹理 GPU 回读与默认 UV 翻转负对照均通过，Editor 退出 0。停止恢复修复限定 Unity 显式 `video.play`：合法选中素材停止后重新选取并开始，暂停时沿用当前 item 与位置，无合法素材返回失败。真实 AVQueuePlayer stop/play、pause/resume、失效素材及原绑定回归退出 0，未改共享 StageVideoPlayback 或自动跟随逻辑。v172 Host 构建退出 0，Player 构建中，尚未宣布实际窗口修复通过。

### v172 现场验收（2026-10-06 23:38 起）

- Host、Player 构建及完整打包退出 0，实际启动 PID 51466。实际设置中停止后点击播放恢复，按钮切回暂停状态；停止恢复入口通过。真实视频背景仍上下倒置，包内 IL 已核对包含 UV 改动，不能将独立 GPU 回归视为真实 Player 通过。
- 方向回归进一步覆盖原 MP4、AVPlayerItemVideoOutput/CVMetalTexture、连续不同纹理指针更新、生产 BindTexture 与实际 GameView/backbuffer；正例方向正常，默认 UV 负例倒置。已排除遗漏打包与导入副本，真实运行差异仍待定位。
- 中文草稿“测试中文输入，不发送。”通过粘贴完整显示，随后清空并关闭聊天，未提交。此项仅验证中文粘贴，不替代输入法组合输入验收。
- request=1 于 23:54:26 读取既有物件、23:54:30 `hold_prop` 成功，实际普通窗口与小窗可见 Kipfel 持现有白色长剑。未生成、领取或改变抓握配置，小窗证据不用于精细手指贴合判断。
- request=2 于 23:58:51 `move_to` 成功。连续应用截图覆盖持剑路线、抬脚、转向与镜头跟随至原点唱机，剑在已观察运动帧中保持手部附着；未启动设备活动或改变音乐。
- 随后正式只读 `world_snapshot` revision=1994、layoutRevision=43：held.objectID、avatar、rightHand 与 revision=1989 完全一致；原 returnState.transform 逐字段未变。角色位置为 (-4.95,0.016619667,-1.54)，activeActivity=null。持剑移动身份与原返还变换保留，尚未覆盖实际返还和再次持有。
- request=3 于 2026-10-07 00:02:43 执行 `return_held_prop`，ok=1/replayed=0。正式读回 revision=1995、layoutRevision=44：held 已空，原剑 isEnabled=true；恢复后的 position、rotation、scale 及完整 transform 均与原 returnState 精确一致。实际返还通过，再次持有仍待验收。
- request=4 于 00:04:12 再次 `hold_prop` 成功，小窗可见附着。正式 revision=1996/layout=45 读回：同一 object/avatar/rightHand、grip 配置及原 returnState.transform 均精确一致。正常退出 v172 后启动 v173，正式再次读回上述字段仍全部相等，持有状态跨 Player 重启保留。

### v173 运行差异定位（2026-10-07）

- 新诊断第一次编译因 Unity 6000.6 将 GetInstanceID 标为错误而失败，改用 GetEntityId 后 Editor 与主代理 Player 构建退出 0；完整打包、严格深度签名退出 0。实际启动 PID 57031。
- 原视频手动播放后实际背景仍倒置。一次性布局诊断显示运行 UV=(0,0,1,1)，sourceRect=(0,0,898,450)，ScaleAndCrop，worldBound=(12,52,696,386)，绑定与实际纹理指针相等。初始化 UV 翻转未保留至显示阶段；正在定位图片绑定对 UV 的重置，不将该包记为方向通过。
- v172 真实再次持剑产生现有物件通知；v173 重启后普通工具栏显示红色 1，打开通知列表仍保持 1，首条持剑通知显示未读；点击其详情后角标消失。尚需正式持久状态及下一次重启读回，不以 UI 变化替代持久化验证。

### v174 实际方向修复复验

- 根因由实际 Unity 6000.6 Image IL 与失败回归共同确认：缺背景快照设置 image=null，Unity 重置 UV；随后纹理绑定未恢复初始化映射。仅在背景绑定后恢复既定 UV。新增启动缺帧→首帧与停止缺帧→重新绑定回归先失败，再通过修复；实际原 MP4 GPU 回归及默认 UV 倒置负对照退出 0。
- 主代理 v174 Player 构建、完整打包与严格深度签名退出 0，实际启动 PID 58716。实际 GPUI 播放同一原素材，窗口文字、工具栏与右下球体方向均与源帧一致；停止后背景消失，再次播放仍保持正确方向。真实窗口方向与停止后恢复通过。
- 实际一次性布局日志确认 UV=(0,1,1,-1)、sourceRect=(0,450,898,-450)，绑定及当前纹理指针相等，验证修复进入真实运行链。日志不替代上述实际画面对照。
- v173 点击通知详情后正式 inbox/entries revision=195、8 条、unreadCount=0；同一持剑通知 isRead=true，readAt=2026-10-07 00:07:45.048587+08。v174 重启后实际普通工具栏仍无红角标，正在核对正式重启后状态。
- v174 重启后正式同 scope 读回 revision=195、8 条、unreadCount=0；同 taskKey/eventID 的 isRead 与 readAt 均逐值不变。通知详情已读及重启持久化闭环通过，范围限定真实既有物件的持剑通知。
- v174 request=1 在播放器视图尝试返还现有剑，两次均 placement_rejected。恢复空间视图后受控 request=2 于 00:16:57 单次 return_held_prop 成功；模式相关门禁仍待定位，不能将空间视图成功泛化为所有模式通过。
- 原始拒绝为 assetNotPrepared，Unity 在隐藏空间时发布空 assets readiness，返还在碰撞校验前被阻止。实际已加载资产与缺失资产的生命周期回归先失败再通过；修复仅让隐藏时仍报告真实已准备资产，保留 slot 可见性、实际组件/metadata 门禁与碰撞规则。修复构建 v175 中，真实 PLAYER 返还尚未复验。
- 正式确认返还后的 held 已空、原 transform 完整恢复，再通过真实 GPUI 选择已有 2B；Player ready revision=6、pmx.2b-miss-0414-standard 与原 PMX idle ready。request=3 于 00:19:23 持同一剑、00:19:24 move_to 均成功。连续采集 100 帧，实际可见 2B 持剑抬脚、行走转向、镜头跟随至舱内中心后恢复站姿；小窗可见剑保持附着。未据此声明精细手指贴合或足部滑动完全对齐。
- 随后正式 revision=2006/layout=47：同一剑对象由 2B/rightHand 持有，原 returnState.transform 全字段保持；位置 (-0.8,-0.04546777,-3.6)，activeActivity=null。此项覆盖 2B 持剑导航与状态保持。

### v175 隐藏空间返还实际复验

- Player 构建、完整打包、严格深度签名退出 0；正常关闭 v174 后启动 v175，PID 61405，已有 2B、空间位置和持剑恢复。切换实际播放器视图，WORLD 隐藏。
- request=1 于 00:23:28 read_owned_props 成功，00:23:29 单次 return_held_prop 为 ok=1/replayed=0。未切回空间以规避原故障，未改碰撞或世界保存门禁。
- 正式 world_snapshot revision=2007/layout=48：held 已空、同剑 object enabled=true；恢复后的 position、rotation、scale 与完整 transform 均与原 returnState 精确一致。PLAYER 模式返还修复的真实执行和持久状态闭环通过。

### v179 输入与点唱机整合交付（2026-10-07）

- 完整 Player、Host 构建、打包与严格签名通过；实际运行 `tmp/GMGN-Unity-Media-v179.app`，PID 11692。未改变系统授权、Keychain 或共享安装。
- 输入区统一圆角布局，附件入口左侧、麦克风与发送右侧，移除提示与“查看新消息”入口。真实窗口图片粘贴、缩略图移除和普通文本粘贴通过；实际长回复持续滚动至末段。
- 附件比较原生 generation，避免字段顺序变化重建按钮。Editor 回归覆盖同 generation 40 次重排期间实际按下/抬起、新 generation 更新与纹理清空，退出 0：`/tmp/gmgn-chat-attachment-generation-check.log`。Swift 剪贴板分支检查通过。
- 中文组合输入光标逻辑与 Editor 回归通过；自动化实体按键仅产生英文，当前中文输入法实体输入仍待用户验证，中文粘贴不替代该验收。
- PMX 点唱机目标限制在实际手臂可达范围，不改变接触阈值、动作资源与主机门禁。真实 2B、VMD、当前点唱机回归退出 0，手腕距目标约 0.00119，抬高设备 2 米负例拒绝：`/tmp/gmgn-pmx-jukebox-contact-check-r5.log`。
- 真实请求仅恢复既有歌曲：10:36:32 start_activity 成功、接触 ready=True，10:36:37 有限动作完成进入循环，10:36:38.190 resume_music 为 ok=1/replayed=0。实际角色听歌、工具栏显示暂停按钮；未独立证明曲目身份、播放进度或扬声器可听输出。
- 麦克风真实录音/取消仍等待系统授权；本次交付不声明完整 SceneKit 功能对齐全部验收完成。

### v176 语音运行链与麦克风用途声明

- v175 首次点击聊天麦克风导致 PID 61405 被 TCC SIGKILL；系统崩溃报告 `GMGN Unity Sample-2026-10-07-003042.ips` 明确缺少 NSMicrophoneUsageDescription。包装脚本改为在主应用签名前复用原 macOS 应用用途文案，并验证非空与读回一致。主代理独立执行真实 XML/binary plist 的五项回归退出 0，覆盖缺失、已有、空值、空源及纯空白源；保持 bundle ID、授权、凭据与 ASR 行为不变。
- v176 Player 构建日志正常结束 return code 0，完整打包与严格深度签名退出 0；实际包主 Info.plist 用途说明读回非空。关闭崩溃后恢复的 v175，实际启动 v176 PID 63461。
- PMX 实际语音诊断只增加有界开始/停止权重读回，不改变增益或动作。真实 2B + idle VMD Editor 回归覆盖前导静默后 .01/.03/.06/.4 电平落到 2/6/12/80% 实际「あ」blendshape，停止清零，退出 0。
- 实际 NoTools 英语段落于 00:36:22–00:36:43 播放，bindingCount=1；raw .036909 对应 target/runtime/applied 7.38190%，整段 maxRaw .132018、maxApplied 26.40353%，停止全部归零。连续 300 张固定小窗截图中唇间距变化细微，不据此声明充分近景自然度通过。
- 原 SceneKit 2B 为规避 PMX deformer 崩溃会清除 morpher 并过滤 VMD 嘴形，并无 raw×2 的旧口型幅度函数。此处证据证明 Unity 音频电平到实际 PMX 嘴形链正常，不能声称该幅度与旧 SceneKit 相同。
- v176 再次点击麦克风未复现用途说明缺失崩溃，进入 connecting；00:38:46 原生回执为 microphone_permission_pending。未批准系统权限、未到 ASR handshake ready、未录音或转写。真实录音/取消验收需要用户确认麦克风授权，整体功能对齐仍未完成。
- 后续只读复核 PID 63461 仍运行，实际窗口显示授权等待错误且草稿为空。重连窗口并 Raise 后，关闭聊天的点击仍未产生新的应用内 pointer/click 回执；当前无法继续依赖窗口输入的验收。尚未证明该输入现象的独立根因，未为此修改交互代码或系统权限。
- 为准备历史节目与音乐避让验收，对同 PID 的受保护 `/snapshot` 做正式只读检查：该设置接口未提供 programID、slotID、播放状态、用户音量或有效音量；视频关联曲目 ID/标题为 null。此投影不能代替音乐运行状态，不据此选择恢复身份或改动播放。

### 2026-10-07 HTTP、统一音乐存储与 GPUI Fast

- 正式 TaskService 数据库先备份，随后升级 schema v5。通过鉴权 HTTP 导入 11 个历史节目（417 个节目曲目条目）、50 个歌单（200 个缓存曲目详情），完整逐条读回一致；旧源文件未变化。重启新版 Rust 服务后 `--check-only` 再验证退出 0，鉴权 `/health` 为 `version=2/transport=http`，数据库 `quick_check=ok`。
- taskd/MCP 客户端统一 HTTP/SSE，删除旧 `--socket` 接口与裸 TCP/NDJSON 传输；MCP grant 必填 `endpointFile`。Rust taskd 178、MCP 29、protocol 4 项通过，真实 HTTP 专项 3、服务进程回归 21 项通过；最终合同 `http_transport` 的 7 项测试通过。
- Swift Prop HTTP/SSE 35、resident 16、MCP mount 40 项通过；世界权威单写入、同根目录、物件重推导及负对照通过。真实 E2E authority/placement/wish 25、MCP 授权 15、size-intent 142 项通过。
- DSH/Claude 自定义宿主网络通道改 HTTP `/rpc`、Bearer、端点 v2，保留每轮 token/授权 epoch/schema、撤权及并发门禁。Claude 真实 Swift/Node HTTP 回归 190 项通过；DSH 通道 89 项、HTTP 错路由/鉴权/Origin/大包/旧 NDJSON 拒绝及真实 Node 插件测试通过。修复预取消请求的 Node error 监听注册顺序后，同一实际进程用例通过。完整 installed DSH + 本地 mock provider 组装 12 项通过，工具结果回到同一 DSH 运行；外部标准 MCP/ACP stdio 保留。
- GPUI Kit 固定 git revision `c1bda59e67f46266991a230ae94f749af496af2a` 并启用 `gpui-fast`，实际解析 Fast 0.1.2；UI 125 与应用 20 项测试通过，settings Release 构建通过。未测 FPS，不据构建宣称性能改善。
- 最终 UnityHost Release、v182 Player/打包及严格深度签名均退出 0。实际启动 `tmp/GMGN-Unity-Media-v182.app`，主进程 PID 39314、包内 taskd PID 39344，正式 HTTP v2 服务正常；包内服务启动后音乐数据再次逐条完整读回。真实窗口显示既有 2B 和空间。CUA 坐标点击报 `windowNotFoundAtPosition`，尚未完成历史列表 UI 与从播放器连接设置的验收；独立设置窗口能渲染但缺少播放器启动参数，不能据此声明设置连接正常。未更改系统权限，未以此声明真实云端语音/听音/麦克风通过。

### v183 歌词共用字体图集修复

- 网易云 `22679504` 歌词接口实际返回 HTTP 200，39 个时间戳；隔离 GPU 回归解析出 36 条非空歌词。初始化成功，但未使用的 Latin fallback 图集仍为 1×1 占位，主字体为 1024×1024；全部图集无条件合并触发严格尺寸检查，清空 glyph buffer，实测 `points=0`。这解释共用渲染故障，不能用后来进入小窗的状态解释之前全屏缺失。
- 修复仅让已分配字形的 fallback 加入图集数组，保留尺寸检查和真实备用字体选择。原复现恢复 185 glyphs；11 样式 × 普通歌词/真实 Latin fallback 共 22 项实际 Metal 诊断通过。生产渲染源只修改一处门禁，未修改电视或输入法。
- v183 Player 构建、完整打包、严格深度签名退出 0，关闭 v182 主进程后启动 v183 PID 47518。正式 HTTP v2 健康检查通过。上述歌词验证为隔离 Unity/Metal 回归；重启后的用户曲目实际屏幕显示仍须单独确认。

### v185 输入法和实体电视显示面

- 组合输入使用公开 `TextElement.selection.cursorColor` 隐藏原生光标，结束或失焦恢复原色；重复 composition 回调仍立即更新预览光标，候选坐标在 composition 回调和正常帧同步更新。实际 Unity Player panel 回归退出 0，验证真实光标颜色、重复回调几何和失焦恢复。v185 实际窗口的普通输入、测试草稿清理通过；自动化按键未触发系统中文组合输入，因此系统候选窗的人工验收仍未完成。
- 当前电视 GLB `sha256:dffb417b8b2e83edf85c44c8ce64d4f04d474e0278764e1da63e02b4320cab54` 为整机单 mesh/材质。按实际模型内显示面标定并绑定真实 mesh transform，保留边框和底座；未标定且无显式屏幕元数据的物件不提供播放入口。真实 GLB PlayMode 回归退出 0，覆盖内缘、底座、变换、未知资产拒绝，以及 idle/loading/failed/stopped 常驻黑屏。v185 实际窗口可见实体电视黑色显示面。
- 控制小窗只含链接输入和播放/停止/状态，成功受理后关闭，无视频预览。电视链路使用 AVPlayer 解码、CVPixelBuffer/CVMetalTexture 与 GPU texture 交给 Unity，不实例化 WKWebView 或截图网页。
- v185 Host、Player/完整打包及严格深度签名退出 0，实际启动 PID 58251；正式鉴权 HTTP `/health` 返回 `version=2/transport=http`。未提交或推送。
- 用户提供的 YouTube `1tjrYgF9pes` 只解析单条视频。优先纯 AVC/AAC 分轨并限制 1 MiB 块、裁剪尾块；短探针出现真实画面和非零音频样本，但持续预取仍返回 HTTP 403，官方旧 helper 独立完整下载也失败。持续探针严格检查每个 loader 的失败，未通过；不能据早期画面或终态 playing 宣称电视完整播放已解决。正在核验更新内置取流 helper 的官方修复。

### v186 原生播放复测（未通过）

- 内置 yt-dlp 更新至已固定 SHA 的 2026.08.19，随包包含已固定 SHA 的 Deno 2.9.7；先清空默认 JS runtime 发现，再只传完整性核验后的内置 Deno 路径。参数、安全负对照和打包测试通过；Host、Player 打包及严格深度签名退出 0。
- 360p 独立探针持续推进 62 秒、1565 个视频帧，音频有非零样本，HTTP 无失败。产品默认高清分轨复测虽无 403、音频推进约 39 秒，但仅输出两帧，持续视频验收失败；诊断门槛已收紧，不能以音频时钟或首帧代替视频持续播放。
- 实际应用 PID 59798 首次解析超时，重试后实体电视出现视频。用户截图确认画面上下颠倒且冻结，故完整应用播放仍未通过。独立内置 helper 的无网络版本查询冷启动耗时约 55 秒，正在修正解析预算、纹理方向和视频供帧。未提交或推送。

### v187 电视方向和连续供帧

- 同一个高清格式 137 对照：分轨 composition（含音频 tap 或关闭 tap）仅两帧、末帧 PTS 0.04 秒；视频流直接播放约 29 秒输出 718 帧。保留分轨源 AVURLAsset 至停止后，新解析的实际视频连续推进 29.16 秒，解码/GPU 拷贝各 730 帧，1920×1080，音频 317 buffers/1,298,432 PCM frames，HTTP 失败列表为空，严格探针退出 0。
- 修复音频 tap 对采样器的持有与 finalize 释放；实际创建、分配失败、两轮分轨 start/stop 源资产持有及释放回归全部退出 0。修正 TV UV 的上下方向，真实 GLB 回归通过；解析预算增至 120 秒以覆盖已实测的内置 helper 冷启动。
- Host、完整包及严格深度签名退出 0，实际启动 v187 PID 65979。实体电视画面文字方向正确，两次实际窗口截图中的演出镜头和字幕持续变化，保留边框、底座，控制窗口无视频预览。独立探针验证音频样本，不等同人工听音验收。
- 小窗口状态文字已可见，但用户截图发现滚动条误套输入框样式、挤出播放按钮；正在改为无滚动容器的紧凑表单。用户新增歌词显隐开关，指定底部工具栏最左边，待实现和实际验收。未提交或推送。
