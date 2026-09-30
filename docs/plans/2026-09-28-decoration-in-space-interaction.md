# 装修模式改成 3D 空间内直接操作（调研结论 + 实施规格）

**背景**：产品负责人否定了"在面板里配置"的方向，原话：

> "不是让我在面板里配置哦……sims是能够把物件用鼠标'拿起来'，然后点击箭头旋转，然后确定就摆放哦"
>
> "要有3D游戏编辑房间和空间的感觉哦，要符合用户鼠标的操作，直接在空间里面做，不是在面板做"

本文是**调研结论**（含出处）与**可实现的决定**，供逐步实施。原始报告（含 1,000 行细节与 9 项真机验证清单）由调研 agent 产出；此处保留可直接施工的部分。

---

## 1. 同类产品怎么做（有出处）

| 产品 | 关键绑定 |
| --- | --- |
| **The Sims 4**（[EA Help](https://help.ea.com/en/articles/the-sims/the-sims-4/how-to-rotate-sims-4/)、[EA Tips](https://www.ea.com/en-gb/games/the-sims/tips-and-tricks)） | 点目录物件即**黏在光标**；**左键单击放下**；**右键单击 = 转 45°**（不是取消！）；`,` / `.` 转 45°；`H` 手工具；`Alt` 脱离网格；`0`/`9` 升降；`Esc` 取消；已摆物件**悬停发光后单击拿起** |
| **Unreal / Unity**（[Unreal](https://dev.epicgames.com/documentation/en-us/unreal-engine/viewport-controls-in-unreal-engine)、[Unity](https://docs.unity3d.com/Manual/SceneViewNavigation.html)） | **LMB 专管选中与 gizmo，相机走 RMB 与 `Alt`+鼠标**；`F` 聚焦；gizmo **屏幕空间恒定大小**；吸附默认开、`Control` 临时脱离 |
| **Blender**（[手册](https://docs.blender.org/manual/en/latest/scene_layout/object/editing/transform/move.html)） | `G`/`R`/`S` 进入 modal，**左键确认**；`Ctrl` 吸附、`Shift` 精调 |
| **House Flipper**（[控制表](https://www.ludo.guide/guide/house-flipper/getting-started/basic-controls-movement)） | 拿着物件 `Q`/`E` 旋转、`G` 放下 |

**四条要点**：

1. **右键在 Sims 4 建造模式里是"旋转"，不是取消**；取消只有 `Esc`。
2. 物件有明确的**"在手"状态**（EA 快捷键表整节叫 Object Placement Tools）。
3. **相机与物件的手势冲突在官方产品里就存在** —— Sims 靠"切换相机模式"化解，Unity/Unreal 靠"按鼠标键分工"（LMB 操作 / RMB 相机）。
4. 放置类 3D 交互的公认解法是**把自由度约束掉**：让物件沿场景已有表面滑动（射线命中），而不是自由 3D 放置（[Wang et al., GI 2011](https://hal.science/hal-00758512v1/preview/Wang-McGuffin-Berard-Cooperstock_GI2011.pdf)）。

---

## 2. 决定（每条都是定论，不是选项）

> 命名：**「在手 / 携带」= 鼠标拿着**（`ResidentPropEditorState.isCarrying`）；**「手持 / 拿着看 / 放回」= 居民右手拿着**（`isSelectedHeld` / `holdSelected()`，会持久化、要求 2B 角色、最长边 >0.45 m 拒绝）。两件事，UI 上也不许混用词。

| # | 决定 | 理由/落点 |
| --- | --- | --- |
| D1 | **在物件架单击一行 = 立刻在手**；编辑器打开时**单击场景里已摆出的物件也直接拿起**；未打开时点场景物件无效果 | Sims 就是这样；本 app 列表行没有"仅选中"的第二种动作 |
| D2 | 跟随**支撑面射线命中点**（复用 `PropSupportGridPicker.pick`），沿用现有五态着色；**默认吸附**，**按住 `⌃` 脱离网格**（不要用 `⌥` —— 那是 Unity/Unreal 的相机修饰键） | 能力已存在（`ResidentPropGridEditorModel.updateHover`） |
| D3 | **删掉「放在 地面」下拉**，改为射线命中哪层就放哪层；补 **`PageUp`/`PageDown` 在同列上下层之间切换** + 光标旁层名胶囊 | 低角度瞄桌面会先命中架子，需要确定性修正；层名数据源 `listedSupportLayers()` 已有 |
| D4 | 旋转手柄 = **世界锚点 + 屏幕空间恒定 26 pt 圆环**（命中区 32 pt）；**单击 = +45°**，`⇧`+单击 = −45°，键盘 `R`/`⇧R`/`,`/`.`；**右键单击 = −45°**；按住拖动 20 pt = 一格<br>**现状（2026-09-29，`fa1070c` 起）**：左键只放下、右键单击旋转；手柄不再接受左键，也不再表现为可点击（命中区已删：悬停既不变亮、也不换光标）—— 圆环只是"这件东西朝哪边"的**静态**提示。右键单击 = **+45°**（`⇧`+右键 = −45°），右键拖动 20 pt 以上 = 相机轨道。键盘 `R`/`⇧R`/`,`/`.`、26 pt 圆环、34/10 锚点都不变；"命中区 32 pt"与"按住拖动 20 pt = 一格"都已不存在 | 45° 与 Sims 4 官方一致；屏幕恒定尺寸解决被遮挡点不到 |
| D5 | **点即放**（LMB 单击、位移 < 4 pt）；**手柄命中优先于放置**；右键不放下<br>**现状（2026-09-29）**："手柄命中优先于放置"已废除 —— 手柄不再吃左键，所以没有"优先"，左键在任何位置（包含圆环正中）都是同一条"按下记点 → 抬起按 4 pt 判定 → 携带时放下"的路。"右键不放下"与 4 pt 阈值不变 | 三条约束防止"只想转却放下了" |
| D6 | **`Esc` 四级回退**（手上有已摆物件→回原位且保持选中；手上有未摆出物件→退回列表；有选中→取消选择；无选中→关闭编辑器）。右键**不是**取消 | preview 从不改世界，所以"回原位"不需要新状态 |
| D7 | 已摆物件**悬停发光**（给 `CellState` 加一个 case，零 shader 改动）、单击拿起、双击聚焦相机 | 对应 TheGamer 描述的 white glow |
| D8 | **相机全部保留**：LMB 拖 / RMB 拖 / MMB 拖 / `⌥`+LMB / 滚轮 / WASD / 箭头，物件在手时也照常可用 | **必须删掉 `StageWindowController.swift` 里"编辑器打开就 `keyDown` 直接 return"那行**（它让 WASD 彻底失效），并恢复 `Shift` 加速 |
| D9 | 不可放 = **红格 + 光标旁文案胶囊（复用 `hoveredBlockReason`）+ 音效**（同一错误 1.2 s 内不重播）；**超出可摆范围不算错误**（footprint 消失 + "瞄准地面或台面"）；**不做位移动画** | 不弹窗；落点必须是用户点的那一格 |
| D10 | 面板拆成**左侧物件架（200 pt，`⌘B`）+ 底部三键工具条（撤销/收回/完成）**，删掉「放在地面 / 移动 / 微调四箭头 / 左转右转 45° / 取消 / 确认」 | **`拿着看`/`放回` 必须保留**（那是居民手持），挪进物件架行菜单 |

**渲染方案**：手柄**画在 `StageWorldInteractionView.draw(_:)` 里**（Core Graphics），**不是**叠 SwiftUI/SpriteKit overlay —— overlay 那几层 `hitTest` 全返回 nil，新建一层等于第三套坐标系；画在交互视图里则**画与命中判定同坐标系**。
⚠️ 需真机验证：该视图原本没设 `wantsLayer`，而兄弟视图都有 `zPosition`，layer-backed 混排可能把 `draw(_:)` 盖住。
**已按退路改掉**（2026-09-28，第 2 步）：`worldInteractionView.wantsLayer = true; layer?.zPosition = 6`，
但仍**没在真机上确认**过圆环确实压在世界之上、并且不会被 overlay（`zPosition = 10`）吞掉。

**两个必须绕开的坑**（两份独立调研各自发现）：

1. **不能依赖 `publishResidentPropGrid` 的防抖推送**：它有"同一格不重复推"的去重，点第二下同一格会被吃掉，而且它是异步 Task。点击放下必须**自己 await**「重算 hover → `moveResidentPropGridPointer` → `canPlaceAtHover` 守卫 → `confirm()`」。
2. **旋转必须走 `rotateFootprint(bySteps:)`**（与 R 键同路），**绝不能**走 `ResidentPropEditorState.rotate(_:)` —— 后者只改 `placement.yaw`，会造成**两个 yaw 真相来源**（唯一真相是 `ResidentPropGridEditorModel.footprintYaw`）。该旁路应删除。

---

## 3. 分期（每步可独立验收）

| 步 | 做完后用户能做什么 | 状态 |
| --- | --- | --- |
| **1. 点地即放** | 手上有物件时单击就放下，不用点面板「确认」；`⌘Z` 能撤销 | 🚧 进行中 |
| 2. 场景内旋转手柄 | 物件旁青色圆环，点一下转 45°，`⇧`/`,`/`.`同效 | 🚧 进行中（2026-09-28：手柄 + 45° 步长 + `,`/`.` 已做；右键单击、按住拖动连续转、连续旋转留在后续）。**2026-09-29 起**：圆环改为静态提示（不接受左键、不表现为可点击），左键只放下、右键单击旋转，见 D4/D5 |
| 3. 从物件架直接拿起 | 点一行就黏在光标上，鼠标一动 footprint 就动，不用再点任何按钮 | 待做 |
| 4. 相机与放置共存 | 手上有物件时 WASD/箭头/拖拽/滚轮照常转视角 | 待做（**风险最高，单独一期**） |
| 5. 已摆物件再编辑 + 悬停发光 | 鼠标移到台灯上它发光，单击拿起来，跨层换位置 | 待做 |
| 6. 反馈与面板瘦身 | 红格 + 光标旁原因文案 + 音效；面板只剩左侧物件架 + 底部三键 | 待做 |

**顺序理由**：第 1 步清掉"点击不放下"这个技术阻塞（也是负责人抱怨的直接原因）；第 4 步风险最高，单独一期以免与其它 bug 混在一起排查。

---

## 4. 必须真机验证（不编）

1. **4 pt 的"点击 vs 拖动"阈值**是否真能分开"放下"与"转视角"；触控板是否要不同阈值。
2. `draw(_:)` 的手柄会不会被 Metal 视图盖住（已加 `wantsLayer` + `zPosition = 6`，仍需肉眼确认）。
2b. **手柄够不够得着**（2026-09-28 新发现，纯几何推导 + 离线交叉复核）：手柄锚点是"footprint 中心 + 沿本地 +Z 外扩
   `max(0.35, 0.6 × 最大半宽)`"，而吸附锚点跟着光标走 —— 手柄永远落在**光标所在格前方**至少
   `半深 + outward − 一格` 米（0.45 m 咖啡机 = 0.325 m，小杯子 0.20 m，1.4 m 柜子 0.47 m）。
   fov 66°、视口约 900 pt 高时，32 pt 命中区只覆盖 `0.046 × 相机距离` 米，所以只有把镜头拉到
   ~4–7 m 外才点得到（近景点不到）。要么接受"先拉远再点"，要么给手柄加"靠近即冻结吸附"
   （或换外扩方向/尺寸），**必须在真机上试**。
3. `MetalStageView` 与 `StageWorldInteractionView` **两套 `mouseDown` 实际谁生效**。
4. 双击复位相机是否干扰连续摆放。
5. 45° 斜放时跨列 footprint 的 SAT 求交是否有浮点抖动（相邻两格一红一绿）。
6. 放下回弹动效是否会被误读成"放歪了"。
7. `AudioEngine` 里有没有可用的"咔/咚"短音效。
8. `listedSupportLayers()` 在 3000+ 格房间里归并后的**层数**是否适合 `PageUp/PageDown` 逐个遍历。

---

## 5. 已修的前置（本次会话）

- **放置高亮不跟手**：`mouseMoved` 被 `consumesPropPointer` 挡住，而 `isMoving` 的唯一入口是面板「移动」按钮 → 不点它 footprint 根本不跟鼠标。已加派生属性 `isCarrying`（`isOpen && placement != nil && !isSelectedHeld`，**派生而非存储**，所以 confirm/cancel 的清理路径自动生效）并把门禁改为 `isCarrying || isMoving`。
- **文档曾谎报**：设计文档写着"点击在吸附后的格心上落地 ✅"，而代码里 `confirm: true` 被丢弃、点一下什么都不发生。已在第 1 步一并改为如实描述。
