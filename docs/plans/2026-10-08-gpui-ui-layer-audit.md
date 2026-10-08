# GPUI UI 层审计（浮在 Unity 空间上的整个 2D UI）

日期：2026-10-08。分支 `codex/rust-full-migration`。
范围：**Unity 场景之上的全部 2D UI**。**不含动态歌词**——歌词需要字形形变与逐模式光效，留在原生 GPU 路径（`apps/gpui-ui/src/lyrics*`）。

方法：读原版 Swift 源码取尺寸/结构/文案，与当前 GPUI 源码逐项对照；数字都来自代码，不是印象。

---

## 0. 这一层是什么

Unity 负责 3D 空间（`apps/unity-player`），2D UI 由 GPUI 提供并叠加到 Unity 窗口上（`gmgn_gpui_probe_mount` / `ui.chat.open` 等，见 `apps/unity-player/Assets/GMGN/GPUIChat2Probe.cs`）。
GPUI 侧分两部分：

| 部分 | 位置 | 内容 |
|---|---|---|
| 外壳 | `apps/gpui-app/src/main.rs` 等 | 底栏、目的地、任务状态、各面板的定位与命中区、小窗 |
| 面板 | `apps/gpui-ui/src/{chat,settings,inbox,stage_panels,state,i18n,projective_card}.rs` | 聊天、设置五页、系统消息、舞台设置、我的物件、节目轨道 |

原版（迁移目标）在 Swift：`apps/macos/Sources/GMGNRadio/**`。布局硬约束见 `docs/plans/2026-10-04-gpui-ui-parity.md:42-57`。

---

## 1. 系统性问题（整个层，不是某一页）

### P1 一套角色一套写法，没有共享地基
每个面板自己写 `div().rounded_lg().bg(theme.tokens.background)`、自己的字号与间距。
证据（改动前的字面量计数）：

| 文件 | 行数 | 颜色字面量 | 字号字面量 | `theme` 引用 |
|---|---|---|---|---|
| `lib.rs`（旧聊天） | 634 | 4 | 0 | 5 |
| `settings.rs` | 1987 | 12 | 1 | 41 |
| `inbox.rs` | 419 | 1 | 3 | 7 |
| `stage_panels.rs` | 713 | 14 | 3 | 6 |
| `stage_panels/props.rs` | 486 | 11 | 7 | 2 |
| `stage_panels/program.rs` | 2431 | 2 | 1 | 0 |

同一个"卡片"在聊天里是 16 圆角、在设置里是另一种圆角、在舞台面板里又是另一种；改一处不会同步到别处。

### P2 浮在场景上的面板跟着系统主题变色
外壳与多数面板用 `theme.tokens.background` / `theme.foreground`。原版这些面板一律是**固定深色**（`Color(white:0.1)`、`Color(white:0.15)`、`Color(white:)` + 透明度），因为它们在 3D 画面上，用户切浅色主题时面板不该翻白。
证据：`settings.rs` 41 处 `theme` 引用；`main.rs:697` 用 `bg(background)`。

### P3 控件不是组件
大量交互是裸 `div()` + `on_click`，没有 hover/press/focus/键盘/AX 语义；kit 组件只在少数地方用了（`Button`、`Input`、`Switch`、`Slider`、`Sidebar`、`ListItem`、`Bubble`、`Spinner`）。
证据：见上表以外的模式——例如聊天里的按住说话是自己拼的 div（合理，kit 的 `Button` 没有按下/松开生命周期），但要**写明理由**；其它面板的同类自拼没有理由。

### P4 该滚的和不该滚的混在一起
旧聊天把**整个面板**设成 `overflow_y_scroll()`，于是输入框和按钮能滚出可视区。原版只有 132 pt 的历史区滚动（`StageOverlayView.swift:283-284`）。

### P5 尺寸/高度有第二处真相
`main.rs:55-60` 的 `composer_frame` 与 `main.rs:647` 的 `compact_composer_height` 把面板尺寸又算了一遍；面板自己也有一份 `max_w(620)/max_h(320)`。两处一旦不同步，表现是"面板位置对、大小错"或反之。

### P6 宿主给面板再包一层 chrome
`main.rs:697` 与 `main.rs:664` 给面板套 `bg + rounded_xl + overflow_hidden`，与面板自带背景/圆角叠加；`overflow_hidden` 还会裁掉阴影与提示。
后果之一见 `docs/plans/2026-10-04-gpui-ui-parity.md:240`：拒绝态错误文案曾**溢出容器**被裁。

### P7 命中区索引与子元素顺序隐式耦合
`main.rs:717-742` 用 `composer_index` / `passive_indices` 在 `on_children_prepainted` 的 bounds 列表里按下标取矩形。任何一次子元素顺序调整都会**静默**错位（点击穿透/区域错位），没有断言钉住。

### P8 可访问性标识缺失
原版每个控件都有 `accessibilityIdentifier`（如 `stage.resident-transcript`、`stage.resident-input`、`stage.resident-progress`、`stage.resident-stop`、`stage.resident-status-notice`、`settings.*`）。GPUI 侧此前只有零星几个，且 `notice` 行被投影成 `"系统"` 标签，与原版"无标签 + 警告色"不一致（`host_events.rs:33`）。

---

## 2. 聊天面（已重写，作为参考实现）

### 发现的问题（`lib.rs` 旧实现，逐条）
| # | 问题 | 证据 | 原版 |
|---|---|---|---|
| C1 | 说话人标签和正文**同一行**、同样式拼在一起：`.child(line.speaker.clone()).child(div().child(line.text))` | 旧 `lib.rs` render | 10 pt/45% 标签一行，13 pt/90% 正文一行，行距 4（`StageOverlayView.swift:250-263`） |
| C2 | notice 行没有独立颜色 | 同上 | notice 用 `orange.opacity(0.95)`（:258-259） |
| C3 | 整个面板滚动 | `pane.overflow_y_scroll()` | 只有历史区滚动，固定 132 高（:283） |
| C4 | 历史区没有卡片：缺 `white0.1/0.96` 背景、16 圆角、16/12 内距 | 旧 render | :300-302 |
| C5 | 面板自身 padding 8、圆角 `rounded_lg`、外层宿主再包一层 | `p(px(SPACING_8))` + `main.rs:697` | 卡片内距 15、圆角 20（:414-418） |
| C6 | 缺"松手把图片加进这条消息"落点提示 | 旧 render 只有背景变色 | :307-312 |
| C7 | 交付提示与宿主提示混在同一个 `status` 里 | 旧 render | `statusNotice` 与 `deliveryNotice` 两条独立行（:313-326） |
| C8 | 输入占位文案不对 | `"和居民聊聊…"` | `"发消息，或让居民做点什么…"`（`ResidentImageAttachment.swift:683`） |
| C9 | 输入框固定 26/40 高、`rows(2)` | 旧 render | 14 pt、**1…3 行自适应、26…64 pt**（:706-710） |
| C10 | 控件行间距 4、按钮形态不符（发送键不是实心圆、没有 28 pt 加号、没有说话中的胶囊） | `gap(px(SPACING_4))`、`Button::primary()` | 间距 10；加号 28×28；麦克风 30×30；发送 30×30 实心圆（`white0.92`，字形 `white0.14`，禁用 `white0.25`）；说话中变"停止说话"胶囊（:334-412） |
| C11 | 缩略图移除用文字 `×`、无 `xmark.circle.fill` 观感；`<img>` 无底板 | 旧 render | 54×46、圆角 6、`black.opacity(0.2)` 底板、`xmark.circle.fill`（`ResidentImageAttachment.swift:490-499`） |
| C12 | 缺 a11y id（`stage.resident-transcript/-status-notice/-delivery-notice/-image-drop-hint/-progress/-input`） | 旧 render 只有 `stage.resident-push-to-talk` | 逐个标识见原版 |

### 重写后的结构（`apps/gpui-ui/src/chat.rs`）
- 两张卡：**历史卡**（`PANEL_BG`、16 圆角、16/12 内距、132 高滚动 + 右侧复制键）+ **合成器卡**（`CARD_BG`、20 圆角、15 内距）。
- 纯决策抽成自由函数并各自带单测：`speaker_label`、`standalone_reply`、`plain_text`、`history_visible`、`composer_chrome`、`compact_composer_height`。宿主与此面共用同一答案，不再各推一遍。
- 只有历史区滚动；面板根不再滚。
- 所有颜色/尺寸来自 `ui_tokens::scene` / `ui_tokens::chat`；`chat.rs` 内零字面量。
- 保留原有命令语义（`ChatCommand` 序列不变），并有一条**真实 GPUI window 绘制**回归（含提交→接受→回复→进行中通知+按住麦克风的第二帧）。

### 顺带修掉的一处宿主投影不一致
`host_events.rs:33` 把 `notice` 投影成 `"系统"`；`main.rs` 的 `expanded_reply_text` 却按 `speaker.is_empty()` 判 notice。现在统一为**空标签 = notice**（原版口径）。

---

## 3. 新地基（本层之后所有面都按它写）

- `ui_tokens::scene`：浮场景面板的**固定深色**调色板与控件几何。浮在场景上的面板**不许**读系统主题。
- `ui_tokens::<面>`：面级尺寸（`chat` 已落地，其余随各自重写加入），每个常量注明 Swift 出处。
- `primitives.rs`：`scene_card/scene_inset/scene_bar`、`card_title/section_title/body/muted/notice/empty_state/divider`、`icon_button/bar_button/primary_circle_button/capsule_button/hold_button/flex_status/h_strip`。
  规则：
  1. chrome 与字体只能来自这里；
  2. 控件优先用 gpui-kit 组件（hover/press/focus/tooltip/AX 由它们负责），kit 没能力的才手写并写明理由；
  3. helper 返回具体类型或 `AnyElement`——GPUI 的元素类型会把整棵子树编进类型，嵌套深了会拖垮编译器（见下）。

---

## 4. 工程约束（踩过的坑，写下来避免重复）

1. **模板宏冲突**：gpui 也导出 `test` 属性宏，测试模块里 `use super::*;` 会遮蔽内建 `#[test]`，表现是 `recursion limit reached while expanding #[test]` 甚至 rustc SIGBUS。测试模块必须同时 `use core::prelude::v1::test;`（仓库既有写法）。
2. **类型深度**：一个 render 里嵌多张卡就足以让 proc-macro 崩。让每个 helper 返回 `AnyElement`（内部 `into_any_element()`）。
3. **`crate` 级 `#![recursion_limit = "256"]`** 已加在 `apps/gpui-ui/src/lib.rs`；它是兜底，不是借口——仍然要把 render 拆小。
4. **滚动是 stateful 的**：`overflow_*_scroll()` 在 `StatefulInteractiveElement` 上，需要元素有 `.id()`。
5. **颜色类型**：`ButtonCustomVariant::color/foreground/hover/active` 收 `Hsla`，token 是 `u32`，调用处 `.into()`。
6. **图标必须是被打包的那批**：`IconName` 枚举里有全部 lucide 名字，但只有 `gpui-kit` 的 `crates/assets/default-icons.txt` 列出的会被打包；用了没打包的名字（如 `ArrowUpRight`）编译通过、**画出来是空白**。收口时按 `default-icons.txt` 校验（`ExternalLink`、`Copy`、`Mic`、`Plus`、`Square`、`ArrowUp`、`CircleX` 这些在列）。

---

## 5. 本轮状态

| 面 | 状态 |
|---|---|
| 地基（tokens / primitives / 约定） | 已落地 |
| 聊天 | 已重写，142 项测试全绿（含真实窗口绘制） |
| 设置五页 | 并行重写中 |
| 系统消息（720×460 / 列表 300） | 并行重写中 |
| 舞台设置 / 我的物件 / 节目轨道 | 并行重写中 |
| 产品外壳（底栏/目的地/任务状态/小窗/命中区索引） | 并行重写中 |
| 动态歌词 | **不在范围内**，保持原生 GPU 路径 |

### 交互规范 R1：控件只用图标，不用文字（本轮用户明确要求）

- **按钮/开关/分段等一切"控件"只画图标**；文字只作为 **tooltip** 与**无障碍标签**存在（`icon_button` / `bar_button` / `primary_circle_button` 三个构造器都强制把 label 用作 tooltip + AX，不渲染成控件内的文字）。
- 文字属于**内容**：标题、分区名、列表行、状态行、输入占位、空态、错误提示——这些照旧是文字。
- `capsule_button` 只为原版"停止说话"那颗药丸保留，**不得**用于新控件。
- **只有三处例外保留文字**，因为文字在那里是安全要求而不是排版选择：(a) 弹窗里的确认/取消/危险动作按钮（永久删除、取消这类不能只给图标），(b) 菜单项，(c) 列表行/导航项等内容文本。其余面板、底栏、页签一律图标化。
- 图标化必须带 tooltip 与无障碍标签，否则不可用。
- 聊天面已经遵守：说话中的主键用 `Square` 图标圆钮（tooltip「停止说话」），发送键用 `ArrowUp`（tooltip「发送消息」）。
- 其它四个面（设置、系统消息、舞台面板、产品外壳）重写落地后，由 Lead 统一做一遍"图标化"收口，并补一条**机械门禁**：扫描 `apps/gpui-ui/src/*.rs` 与 `apps/gpui-app/src/main.rs`，出现"在 Button 上写文字"的构造即失败（白名单只留导航/列表内容）。

验收口径（每个面都要满足）：
1. `cargo test` 全绿且测试数不减少；
2. 面内**零**颜色/字号字面量（特例进 `ui_tokens::<面>` 并注明 Swift 出处）；
3. 该滚的只有一个区域；
4. 新增断言必须**能失败**（附注入或反向断言的实际输出）；
5. 功能与命令语义不变，只重写呈现。
