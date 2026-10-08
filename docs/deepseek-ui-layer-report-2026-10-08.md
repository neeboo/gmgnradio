# DeepSeek 工作报告：Unity 正式工程的 GPUI UI 层

写给 Codex 接手/复核用。记录时间 2026-10-08 晚。**本文件只报告事实与证据，不代表功能已经验收通过**——真机业务读回一条都还没做（见 §5）。

配套文档（都在同目录，按需读）：

- `docs/deepseek-unity-gpui-handoff.md`——上一手交接给我的任务书（用户需求、正式路径、构建命令、禁止项）。
- `docs/plans/2026-10-08-ui-function-verification.md`——**全部 157 条 UI op 的底账**（每条：控件 → op → 宿主处理者 → 三态）。
- `docs/plans/2026-10-08-ui-interface-parity.md`——op × 字段 × 快照键 × RPC 方法 × schema 类型的跨语言对齐表 + 9 条对不上。
- `docs/plans/2026-10-08-gpui-ui-layer-audit.md`——UI 层系统性问题的审计（P1–P8 / C1–C12）。

---

## 1. 唯一工作目录与版本

```sh
cd /Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio
git branch --show-current          # codex/rust-full-migration
git log -3 --oneline
git status --short
```

- HEAD = **`88bb67a`**（`feat: the UI layer over the space, rebuilt on one foundation`，21 files，+13569/−3110）——UI 层重写那一提交。
- 前一提交 `886bd0b`（WIP：Unity/GPUI 迁移状态）。
- upstream `origin/codex/rust-full-migration`，remote `git@github.com:neeboo/gmgnradio.git`。
- **HEAD 之后有大量未提交改动，属于我这一轮的多条并行线 + 协作者**。只 checkout `88bb67a` 或只拉远端会漏掉全部嵌入层接线。**提交前必须先 `git diff` 逐项审阅，禁止 `git add -A`**（会把 `tools/**/target/` 等构建产物一起吞掉；我踩过，已剔除并加 `.gitignore`）。
- `/Users/ghostcorn/dev/gmgnradio` 是**另一个** checkout（分支 `codex/agent-living-world-e2e`），不能用它构建本交接版本，也不要在那里覆盖。

**安装位置**：正式包是 `~/Applications/gmgn radio.app`（Unity 产品包，identity `ai.gmgn.unity-sample.player`）。曾被我误装成 standalone GPUI 包到 `/Applications/gmgn radio.app`，该目录已被移入废纸篓（`~/.Trash/gmgn-standalone-unused.noindex.EiDeMo/gmgn radio.app`）；**不要再往 `/Applications` 放第二份同名包**。

---

## 2. 我做完的部分（按层，带文件与数字）

### 2.1 `apps/gpui-ui`：UI 组件层（在 `88bb67a` 里）

七个渲染面全部按原版重写，共用一层地基：

| 面 | 文件 | 说明 |
|---|---|---|
| 聊天 | `src/chat.rs`（新，1048 行） | 两张卡片；只有历史区滚动；历史固定高 132；附件 54×46；输入 1–3 行自增长；发送键是实心圆图标 |
| 系统消息 | `src/inbox.rs` | 720×460；列表 300→可缩到 240（`ui_tokens::inbox::LIST_MIN_WIDTH`）；详情 ≥320；单击只选、显式打开才标已读 |
| 设置五页 | `src/settings.rs`（+5410 行） | 原版五段页签（现为纯图标 + tooltip/AX）、快捷键录制、许愿机、音乐账号 |
| 舞台设置 | `src/stage_panels.rs` | 590×458，四分区 |
| 我的物件 | `src/stage_panels/props.rs` | 340 宽；分组/折叠/领取/收回/删除确认 |
| 节目轨道 | `src/stage_panels/program.rs` | 350×430；卡片几何按原版 |
| 产品外壳 | `src/shell.rs`（新）+ `apps/gpui-app/src/main.rs` | 浮动栏 529×48 共 11 控件、目的地圆钮、任务状态、小窗 |

地基：`src/ui_tokens.rs`（浮场景固定深色调色板 + 各面级尺寸，每个数字注明 Swift 出处）、`src/primitives.rs`（chrome/字阶/控件；控件一律只画图标，文字只进 tooltip 与无障碍标签）。

### 2.2 Unity 正式嵌入层（未提交）

正式路径（**不要换成 standalone**）：

```text
Unity Player
  → apps/macos/UnityHost（生产快照、命令、媒体、DSH 桥接）
  → tools/fixtures/gpui-unity-overlay-probe
      host/OverlayHost.m      挂载/透明/尺寸/事件/hit regions
      src/lib.rs              同一 GPUI runtime、快照/命令、独立设置窗
      src/shell_ui.rs         Unity 内嵌外壳（浮动栏/目的地/导航/歌词开关/命中区）
      src/media_ui.rs         音乐库/歌曲/队列/节目 + 系统消息
      src/inventory_ui.rs     我的物件
      src/settings_ui.rs      设置外壳（页面复用新组件）
  → apps/gpui-ui（新组件）
```

这轮做的事：

- `media_ui.rs`：接入 `StageProgramRailPane` + `InboxPane`，替换旧歌单/旧子菜单/旧消息菜单；rail 的 op **在 overlay 内翻译**成 Unity 生产 op（`music.library` / `music.program.history` / `music.playlist` / `music.program.play` / `music.playlist.play` / `video.bound.play` / `inbox.read`）。
- `inventory_ui.rs`：接入 `ResidentPropEditorPane`；14 条命令映射全部落到既有 op（`wish.*` / `world.prop.command{withdraw|hold|returnHeld|adjustGrip|resize|undo}` / `inventory.delete` / `ui.*.place`）；命令经 `Context::observe` 收进同一条队列，不新增 transport。
- `settings_ui.rs`：页面复用 `AgentSettingsPane`/`StagePanelsPane`；failed 回执现在显示具名 `code`。
- `shell_ui.rs` / `lib.rs` / `host/OverlayHost.*`：浮动栏与共享 shell、歌词开关（`ui.lyrics.toggle` + 读 `ui.lyricsVisible`）、`close_panel_without_window`、光标/焦点修复（`isKeyWindow` 映射）。

### 2.3 `services/gmgn-taskd`：三个"整个功能是死的"根因

1. **`music_account.rs` / `music_account_http.rs` 是孤儿文件**：实现存在、Swift 真实调用，但 `main.rs` 的 `mod` 列表里没有它 ⇒ 6 个方法（`music_account_session_state/session/import/connect/disconnect/apple_authorization`）恒回 `unknown_method`。已加 `mod` + `daemon.rs` 3 个 arm + `store.rs` 的 `recover` 与迁移 35/36。**回归证据**：修前真实 dispatch 探针 9 个方法全 `unknown_method`（`1 passed; 9 failed`），删 `mod` 则 `E0433` 编译失败；修后 10 条 dispatch 测试全绿 + 真 release daemon / 真 HTTP `/rpc` E2E 拿到真实结构化结果；`gmgn-taskd` **542 passed / 0 failed / 5 ignored**。
2. **`generation_configuration.rs` 同样孤儿**：`generation_configuration_read/save/import` 恒 `unknown_method`，许愿机"保存 endpoint/密钥""检测连接"必失败。同上已接通。
3. **`agent_tools.rs` 的 union schema**：生产 52 项工具里 `submit_wish_generation` 用 `"type": ["object","null"]`，旧校验只认单字符串 ⇒ **整组注册被拒** ⇒ DSH 会话起不来 ⇒ 聊天只有 `RustDSHSessionClient.ClientError error 3`。已补完 union 接受 + 17 种非法形态仍拒 + `SchemaViolation{code,tool,path,detail}` 结构化拒绝；真实 catalog 回归 **52/52**。

另外：`contract.rs` 的 published-codes 门禁原本"绿但不完整"（这 3 个模块不在 `AUTHORITY_SOURCES`），已注册并把 **26 个**未发布码补进 `ERROR_CODES`（删任一码即红）。

**Windows**：`generation_configuration.rs` 原先无条件用 `std::os::unix::fs::*` ⇒ daemon 变 unix-only。已改为复用 `files.rs` 既有跨平台层（新增 `files::create_new_private`：unix `O_CREAT|O_EXCL`+0600+`O_NOFOLLOW`；Windows `CREATE_NEW` + protected DACL，保住 `AlreadyExists` 语义），测试侧加 `#[cfg(unix)]`（**没有用 `#[ignore]`**）。结果：`cargo check --target aarch64-pc-windows-msvc` **exit 0（含 `--tests`）**，另用零环境变量的 `x86_64-pc-windows-gnu` 复核 exit 0。unix 安全校验一条未删。

### 2.4 UI 侧的假成功与死控件

- `stage.load`：不再假成功（UI 停发；`UnityMediaHost.swift` 两条臂 `return true` → `false`，给具名失败）。
- `stage.props.resize` / `stage.props.close` / `stage.program.load`：**真接**（分别接 reducer 的 `resize`、shell 的 `ui.overlay.panel{expanded:false}`、`music.library`+`music.program.history`）。
- `video.unbind` / `stage.video.unbind`：不再发无人读的 `id`（`UNREAD_FIELDS_OK` 已清空）。
- `stage.video.brightness`：取值域统一到 `(0.15...1)`（滑块下限、发射 clamp、快照回填 clamp、Unity guard 四处同域）。
- `InboxPane` 在媒体面板会被裁的问题：列表可缩到 240，240+320 ≤ 面板内宽 562。

---

## 3. 机械门禁（都在仓库里，每道都做过"改坏 → 红 → 还原 sha256 一致"）

| 门禁 | 位置 | 管什么 | 已知边界 |
|---|---|---|---|
| 图标化 | `apps/gpui-ui/tests/icon_gates.rs` | 控件不得画文字（弹窗/菜单/列表行/数据页签例外并逐条登记）；图标必须能被**应用真正注册的 asset source** 画出来 | 例外登记是白名单，需人工维护 |
| op 覆盖 | `apps/gpui-ui/tests/op_coverage.rs` | UI 能发的 op 必须在宿主源码里有同名处理串；Unity-only op 逐条登记 | **口径偏弱**：按"任意宿主"判定，且曾把测试里的 op 当命令面、用子串匹配导致假阴性（`video.bind` 命中 `case "stage.video.bind"` 的子串）。新门禁已取代它，见下行 |
| 接口对齐 | `apps/gpui-ui/tests/interface_parity.rs`（6 个测试） | op × **字段**（发的每个字段必须被处理者读；宿主必填字段 UI 必须发）× 快照键 × RPC 方法面 × schema 类型 | 只能证"有人读"，不能证"当前运行的宿主读"；运行时拼接的 op 只能近似 |
| 渲染回归 | `apps/gpui-ui/tests/ui_shots.rs`（`harness = false`，主线程无头 Metal） | 真面板画不出东西就红；可写 PNG | 需要主线程 harness |
| 契约码 | `services/gmgn-taskd` 的 `contract::` | 权威会返回的码与发布码**恰好相等** | — |
| 底账工具 | `tools/audit-ui-function-inventory.py` | 只读抽取 UI op/控件/宿主处理点 | 动态拼接 op 近似 |

---

## 4. 功能底账（这就是"所有 UI 功能"的分母）

来自 `docs/plans/2026-10-08-ui-function-verification.md`（可复现）：

- 顶层 UI op **157**；按面：设置 46、舞台设置 22、电视与愿望 21、我的物件 20、播放器与音乐 15、聊天 10、外壳 10、节目轨道 8、系统消息 3、歌词 2。
- **已验 0**（真机业务读回一条都没做）/ **已接未验 139** / **未接 18**。
- **静默 no-op 22 条**曾有四类：白名单 `continue`、适配层 `_ => None`、**假成功**（已修）、只改本地状态。前两类已按"真做或不出现"处理（见 §2.4）。

---

## 5. 未完成与需要决定的事

### 5.1 12 条白名单 op：能力不在 Unity 主机链里（**需要产品决定**）

它们的权威只写在 `apps/macos/Sources/**` + `ProductHost`，Unity 主机链没有分支；本轮硬约束禁止改 `Sources/**`，所以统一处置为"**界面上不提供**"（不是死按钮）：

| op | 用户看到的东西 |
|---|---|
| `stage.world.enter` | 舞台设置→世界选择菜单的"进入世界" |
| `stage.scene.activate` | "激活/切换场景" |
| `stage.avatar.position` | 角色位置 X/Y/Z 三个滑块 |
| `stage.avatar.reset` | 角色位置"重置" |
| `stage.motion.refresh` | 动作列表"刷新" |
| `stage.motion.activate` | 让角色播放某个动作 |
| `stage.activity.run` / `.stop` | 活动的开始/停止 |
| `settings.open.presence` | 设置里「管理角色与动作…」 |
| `space.prop.save` / `.check` | 许愿机凭据保存 / 检测连接 |
| `space.prop.cancel` | 取消许愿机配置（Unity 模式本就不发） |

**建议的下一步不是直接移植**：先查这 12 个能力在 **Unity 运行时里的原生入口**（有些能力本来就是 Unity 播放器自己处理的，例如 `stage.camera.reset` 就不走 op）。有原生入口 → 在 overlay 里接到 Unity 原生命令即可，不必动 `Sources/**`；确实没有 → 再决定移植（需要用户授权改 `Sources/**`）还是接受它在 Unity 包里不提供。

### 5.2 真机读回（139 条）

必须按"点得着 → 发得出 → **读得回**"验（读回＝权威/生产状态真的变了）：聊天真实回复、音乐库真实歌曲、物件每步权威读回、消息未读跨重启、设置独立窗保存重开、歌词显隐、全屏/窗口来回切后位置与命中。UI 渲染出来、命令被 UI 自己收下、编译通过，**都不算过**。

### 5.3 其他已知未完成/不可达

- **构建 222 与装机**：`make release` / `install-built`（版本从 `config/release.env` 的 221 递增）；**必须重建 taskd helper**，否则 §2.3 的功能不生效（已安装包里仍是旧 helper）。
- **Windows 端到端**：本机没有 MSVC/Windows SDK，`--target aarch64-pc-windows-msvc` 编 native C 依赖（ring / bundled sqlite3 / sqlite-vec）需要 shim 或改用 gnu target；Rust 代码已两目标 exit 0，**真机链接未验**。
- **真实 provider 往返**（网易云/QQ 音乐账号）：需凭据，且用户禁止触发钥匙串 ⇒ 只证到"进入实现 + 网络前确定性拒绝 + 模块自带夹具测试"。
- **`cargo test -p gmgn-taskd` 默认并行时 `media::tests` 会抖**（2/4 项失败，集合每次不同，单跑全过）；`--test-threads=1` 稳定 542/0/5。既有问题，未修。
- **`stage.props.close` 的 GPUI/原生同帧性**、`stage.program.replan`（Unity 里只归居民代理，UI 只弹提示）等真机帧序未验。
- **既有设计偏离**（非本轮引入，已记录）：系统消息长标题换行而非截断；kit 内建 `TabBar`/`Slider`/`Spinner` 内部颜色来自 kit 主题（无注入点）；节目卡片外壳保留 `role(Button)`（卡片本体是投影位图）。
- **共享 daemon root 按应用名推导**（`AuthorityWorldStatePersistence.swift`）：`~/Applications` 的 Unity 包与 `/Applications` 的其它包会互相顶替同一个 root，`taskd.endpoint.json` 的 token 会变。这不是本轮引入，但会影响真机验证的可复现性。
- **`unknown_method` 未定位到具体方法**：`WorldAuthorityClient.swift` 只打 code 不打方法名 ⇒ 查不出是哪条 RPC。最小修法：把方法名一起打出来（改 `Sources/**`，需授权）。

---

## 6. 给后来者的关键事实（别再踩）

1. **两条宿主链，别混**：`stage.program.*` / `stage.props.*` / `stage.load` 等只存在于 **standalone**（`GMGNRadioApp.swift`、`ProductHost.swift`）；**UnityHost 里一个字都没有**（`grep -rn "stage.program" apps/macos/UnityHost/` 为空）。所以 Unity 嵌入必须在 overlay 里翻译/投影。
2. **UnityHost 不发布组件形状的快照**：没有 `propEditor`、没有 `stage.*` 面板键；只有 `unityInventory` / `unityWorldAuthority` / `wish` / `music` / `musicLibrary` / `programs` / `inbox` / `screenVideo` / `inventoryMutation` / `unityUICommandResult` / `builtinDevices.templates` 等。
3. **op 门禁不能只看名字、也不能按"任意宿主"判定**。我踩过两种假绿：把 `#[cfg(test)]` 里的 op 当命令面（90 → 真实 73），以及子串匹配（`video.bind` 命中 `case "stage.video.bind", …`）。正确口径是**目标宿主链**逐条对 op + 字段。
4. **不要用二进制字符串差集判断方法是否存在**：release 构建会把 match 臂字符串内联成立即数，源码里有的方法名在 release 二进制里也可能搜不到。
5. **本机截图/键盘注入被 TCC 挡**：`screencapture` → "could not create image from display"；`osascript` 键击 → 不允许发送按键。可用的替代是无头 Metal 渲染（`ui_shots`）。
6. **taskd 不写日志、无崩溃报告**；`log show --predicate 'process == "gmgn-taskd"'` 只有表头。
7. **`lipo -verify_arch` 参数顺序**：本机 llvm-lipo 只接受 `lipo <file> -verify_arch <arch>`（`tools/build-gpui-product-app.sh` 今天被修过）。
8. **`git add -A` 会把 `tools/**/target/` 等构建产物吞进提交**（我犯过，已剔除 + 加 `.gitignore`）。

---

## 7. 常用命令

```sh
cd /Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio

# UI 层测试（203 lib + 4 icon_gates + 6 interface_parity + 2 op_coverage）
(cd apps/gpui-ui && timeout 900 cargo test --offline)

# 嵌入层
CARGO_TARGET_DIR=tools/gpui-scenekit-probe/target cargo +1.95.0 check --release --lib \
  --manifest-path tools/fixtures/gpui-unity-overlay-probe/Cargo.toml --offline --locked -j1
CARGO_TARGET_DIR=tools/gpui-scenekit-probe/target cargo +1.95.0 test --release --lib \
  --manifest-path tools/fixtures/gpui-unity-overlay-probe/Cargo.toml --offline --locked -j1   # 33 passed

# daemon（必须 --test-threads=1，否则 media::tests 抖）
cargo +1.95.0 test --locked -p gmgn-taskd -- --test-threads=1        # 542 passed / 5 ignored

# Windows 编译（Rust 侧）
cargo +1.95.0 check --locked --manifest-path services/gmgn-taskd/Cargo.toml \
  --target aarch64-pc-windows-msvc --offline -j1

# 侧信道：audit 脚本（只读）
python3 tools/audit-ui-function-inventory.py
```

构建/安装按 `docs/deepseek-unity-gpui-handoff.md` §7/§9：`make release` → 校验（metadata/codesign/helper manifest）→ `make install-built` → 装到 `~/Applications`。

---

## 8. 我犯过的错与已更正的判断（诚实清单）

1. **搞错了入口**：先构建安装了 standalone `apps/gpui-app` 到 `/Applications`，而正式路径是 Unity 嵌入层。已按交接纠正，那份已入废纸篓。
2. **说过"底栏图标空白是因为没打包"**——错。应用注册的是 `AllAssets`（1830 个全打包），空白是我那个截图 harness 用了较小的默认组件包造成的假象。门禁现在绑定"应用真正注册的 source"。
3. **`shortcuts.capture` 曾被我判成"断线"**——不准确。点"录制"发的是 `shortcuts.record`，产品模式的按键由宿主进程内 `NSEvent` 监视器处理；`capture` 只服务独立进程的 Unity 设置窗。已修的是"快照滞后窗口里会白发一次 capture"。
4. **op 门禁的两处假绿**（测试 op 当命令面、子串匹配）——已由新门禁取代。
5. **`git add -A` 吞了构建产物**——已从提交剔除并加 `.gitignore`。
6. **`prop_capability_capacity` 我一开始读成方法名**——它是权威侧错误码（`world_prop_capability.rs:261`），会冒充外层活动方法的错误码。

---

## 9. 结论

- **UI 层本身**：七个面已按原版重写并共用一层地基，接入 Unity 嵌入层；控件图标化；四道机械门禁（图标化 / 接口对齐 / op 覆盖 / 渲染回归）都在仓库里且各自能失败。
- **后端根因**：聊天 `error 3`（工具注册被拒）、音乐账号 6 方法、许愿机配置 3 方法、26 个未发布错误码、Windows 可编译——都已修，**但要重建 helper 并重新装机才生效**。
- **尚未证明的**：157 条里有 **0 条**经过真机业务读回；这是当前最大的缺口，也是"功能要调通"这句话的真正验收线。未接的 12 条（§5.1）需要产品决定，建议先查 Unity 原生入口再定。
