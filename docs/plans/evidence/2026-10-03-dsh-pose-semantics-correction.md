# DSH 返工：站姿 / 坐姿测试语义更正（坐姿允许脚离地）

本轮只改 `tools/e2e-real-app.py` 的**测试语义**、必要的**只读诊断**，以及一个只在显式测试
产物里存在的**动作激活入口**（`activate_motion`）；不做任何 PMX 位置补偿、不改引擎、不碰
HLS 声音判据、不写生产用户 selection。App 已退出，真实构建与全部 commit / push 由主代理负责。

## 1. 用户更正与错误前提

用户指出：测试根默认动作就是**坐在凳子上的坐姿**（只读确认
`<root>/Library/Application Support/gmgn radio/MotionPackages/.selection.json`
`activeID = gmgn.motion.bones.chair-sit-loop-pmx`）。坐姿脚离地是姿态本身，不是浮地缺陷。

上一轮的错误前提（已撤回，不再据此要求 PMX 强制落地）：

* **"`activeActivity` 为空 ⇒ 当前是站姿"**：不成立。活动结束后渲染器回到**持久选中的默认
  动作**，它完全可能是坐姿。
* **"脚面高出静止脚面 ⇒ 浮地缺陷"**：只对站姿成立；套到坐姿上就是把正常坐姿误判成穿帮。
* 上一轮的 `wait_restart_foot_settled` 不判 clip，坐姿能在 `sole == restFootPlane` 的**过渡帧**
  上瞬间命中，随后拿已经稳定成坐姿的帧判"浮地"（0.2674 m），这是自相矛盾的时序 bug。

## 2. 测试前提（写清）

1. **角色只按渲染器真正装载的 clip 判定**（`status.avatarMotion.clip`），绝不按
   `activeActivity` 是否为空猜站姿。
2. **站姿**：测试根动作选中项被**显式**写成 `--stand-motion-id`（默认
   `gmgn.motion.bones.idle-loop-pmx`），运行时再显式激活它；当前 clip 必须等于它，否则
   站姿贴地判据具名 `blocked`（复制顺序里最后的 `chair-sit` 不得冒充站姿）。
3. **坐姿**：当前 clip 是 `--sit-motion-id`（默认 `gmgn.motion.bones.chair-sit-loop-pmx`），
   或在跑世界声明的坐姿活动（`chair.sit` / `bunk.rest`）。**允许脚离地**，改判：
   * **身体穿模**：脚面 / 全身最低接触点都不得低于角色自己的静止脚面（地面参考）；
   * **座面支撑**：骨盆必须高于脚面（躯干由座面托住、腿垂在下面），且骨盆在采样窗口内高度
     稳定（不持续下沉 / 弹跳）；
   * **骨盆对齐**：骨盆水平位置留在坐姿入口（世界根位置 `residentPosition`）附近。
4. 世界契约里**没有可读的凳子/椅子网格**，所以不编造座面高度、不做位置补偿；脚离地只作
   诊断记录。座面支撑是"骨盆稳定 + 高于脚面 + 不穿地"的只读操作化判据，不是几何座面求解。
5. 测试根之外（生产 `~/Library/Application Support/gmgn radio/MotionPackages/.selection.json`）
   **一个字节都不写**；隔离指纹继续监视两条 selection 路径。

## 3. 实际入口（交付）

| 语义 | 入口 | 说明 |
|---|---|---|
| 启动/重启回到显式站姿 | 测试控制面 `activate_motion` → AppDelegate `playCharacterMotion(id:)` | 生产用户菜单同一条动作选中路径；只写**测试根** `.selection.json`，驱动器轮询 `status.avatarMotion.clip` 核对真的装载 |
| 启动前默认站姿 | 驱动器 `select_explicit_stand_motion()` 写测试根 `.selection.json` | 复制完成后统一覆盖成 `--stand-motion-id`，复制顺序不再决定语义；缺包具名 `blocked` |
| 持久坐姿（无活动） | 同上 `activate_motion(sit)`，`pose_sit` 段 | 直接覆盖用户指出的"默认凳上坐姿"场景；允许脚离地，判支撑/对齐/穿模，跑完切回站姿 |
| 坐姿活动 | 世界生产入口 `start_activity`（`chair.sit` / `bunk.rest`） | 既有路径；`check_motion_track(category="sit")` 追加坐姿判据 |
| 只读诊断 | `status.avatarGrounding.pelvisWorldX/Y/Z`、`leftFootWorld*`、`rightFootWorld*`、`centerWorld*`、`left/rightKneeWorld*` | 渲染器 `worldSkeletonDiagnostics`（新增），经最近一帧真实 `lastAppliedModelTransform` 把骨骼原点投到世界；无补偿、无编造 |

`activate_motion` 只在显式测试产物（`GMGN_E2E_DATA_ROOT` + 专用 bundle id）里存在，和既有
`play_direct_media` 同一性质；生产未设环境变量时 `E2EHostControl` 根本不实例化。

## 4. 改动清单

* `tools/e2e-real-app.py`
  * 新增 `STAND_MOTION_ID` / `SIT_MOTION_ID` / `SIT_ACTIVITY_IDS` 与坐姿容差；
  * 新增 `extract_motion_clip` / `motion_role` / `motion_is_explicit_sit`（只按 clip 判角色）；
  * `copy_package_source(preferred_selection=...)` 与 `select_explicit_stand_motion()`；
  * `wait_standing_settled`：先要求 clip == 显式站姿，再看**至少两个不同渲染帧**脚面贴地；
  * `check_standing_feet`（显式站姿双边贴地）/ `check_sit_support`（坐姿支撑·对齐·穿模）/
    `check_frame_no_penetration`；
  * `verify_restart_foot_pose` 改为"先判 clip 角色，再分派站姿 / 坐姿"；`verify_pose_stand`
    与 `verify_pose_sit` 新增启动后显式站姿 / 持久坐姿两段；`check_motion_track` 的 `sit`
    类别追加坐姿判据；
  * 新增 `activate_motion` 驱动器入口与 CLI `--stand-motion-id` / `--sit-motion-id`。
* `apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift`
  * `PMXSoleGrounding.worldPosition(ofBoneNamed:in:transform:)` 与
    `worldSkeletonDiagnostics`（只读）。
* `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift`
  * `avatarGroundingDiagnostics` 合并 `worldSkeletonDiagnostics`（逐帧抓帧同样带上）。
* `apps/macos/Sources/GMGNRadio/App/E2EHostControl.swift` + `GMGNRadioApp.swift`
  * 测试控制面 `activate_motion` → `playCharacterMotion(id:)`。
* `tools/tests/test_e2e_real_app.py`
  * 新增 `PoseSemanticsTests`：clip 角色分类、坐姿允许脚离地、坐姿支撑/对齐/穿模与稳定性
    负对照、显式站姿贴地、`activate_motion` 装载轮询、复制包优先显式站姿。

**没有撤销的既有工作**：上一轮的 `PMXStageAvatarRenderer` 世界坐标只读诊断、重启物件/屏幕
readback、非 HLS 声音对照、`play_direct_media` 都保留（它们与错误前提无关）。本轮撤销的只是
"把无 `activeActivity` 当站姿 + 脚离地当浮地"的那套判据与等待逻辑。

## 5. 本机可跑的验证

```bash
python3 -m py_compile tools/e2e-real-app.py
python3 -m unittest discover -s tools/tests -p 'test_*.py'     # 89 tests
xcrun swiftc -parse apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift
xcrun swiftc -parse apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift
xcrun swiftc -parse apps/macos/Sources/GMGNRadio/App/E2EHostControl.swift
xcrun swiftc -parse apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift
```

## 6. 主代理复验命令（构建后）

```bash
# 1) 宿主构建当前树（含 helper）
GMGN_BUNDLE_SCREEN_LINK_HELPER=1 bash tools/e2e-app-build.sh --print-path

# 2) 复用已有真实生成任务跑完整 App E2E（显式站姿 + 坐姿支撑 + 重启 readback + 声音对照）
python3 tools/e2e-real-app.py \
  --app "$APP" --reuse-root --root /tmp/gmgn-e2e-20261003-1838 \
  --existing-wish-id 1536D3FF-C7DE-4C18-BC04-9529E7E3B2F2 \
  --video-url https://www.twitch.tv/eslcs
```

关键证据：账本 `tmp/e2e-real-app/ledger.json`；重启抓帧
`<root>/evidence/restart-frames/restart-*.png`、持久坐姿抓帧
`<root>/evidence/pose-sit-frames/pose-sit-*.png`。账本里 `pose_stand` 段是显式站姿贴地、
`pose_sit` 段是持久凳上坐姿支撑/对齐/穿模、`activity_motion` 的 `坐下` 段是坐姿活动。
HLS 声音仍按平台边界 `blocked`，整体验收仍以主代理的真实 App 结论为准。
