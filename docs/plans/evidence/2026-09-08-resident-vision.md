# 居民视觉观察 · 第一增量证据(2026-09-08)

状态:源码核对完成;最小捕获服务 / 工具合同 / 渲染器自身帧回读已编码;
纯离线测试通过(测试运行生产逻辑);主代理审阅五项修复已合入并通过
hostless 回归;离屏视角评估见文末;GPU 验收待接线后执行(本机无 GPU/App)。

---

## 1. 范围与协作边界

本次独占交付(未触碰他人文件):

| 文件 | 动作 |
| --- | --- |
| `apps/macos/Sources/GMGNRadio/Presence/ResidentVisionCapture.swift` | 新增(命名按要求保留) |
| `apps/macos/Sources/GMGNRadio/Agent/ResidentVisionTools.swift` | 新增(命名按要求保留) |
| `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift` | 仅新增"渲染器自身图像捕获"最小部分 + 帧计数器;不重构 |
| `tools/test-resident-vision-capture.swift` | 新增纯离线测试(编译并运行生产逻辑) |
| `tools/test-resident-vision-tools.swift` | 新增纯离线测试(编译并运行生产逻辑) |

未修改:CC 文件(ResidentAgentLoop / ResidentMemoryStore / ResidentLoopTools /
AgentConversationService / GMGNRadioApp 及其测试)、`WorldAgentContext`、
`SpatialStageStore`、`WorldAgentToolContract`、`WorldAgentToolDispatcher`、
工程文件(pbxproj / project.yml)。未 stash / reset / checkout / commit / push。
帧回读复用渲染器自身 drawable,不截用户桌面、不用系统录屏、无授权/钥匙串操作;
不启动或操作 App;不调用真实模型或付费服务;不新增子代理;不自动持续拍照。

> 主代理注意:本仓用 xcodegen 生成工程。合入这些新文件后需执行
> `make generate`(或 `cd apps/macos && xcodegen generate`)让 GMGNRadio /
> GMGNRadioTests target 收录新文件——那一步属于主代理,不在本次范围内。

## 2. 源码核对(先读后写的事实依据)

- `MarbleSpatialView.swift`:`MarbleSpatialRenderer.draw(in:)` 在每个渲染帧把
  世界(SPZ / LivingPod)、点唱机/许愿机/居民道具、头像(VRM/PMX)全部画进共享
  `drawable`;`commandBuffer.present(drawable)` 前是"本帧内容完整"的确定点。
  已有 `MarbleDebugFrameCapture`(#if DEBUG、环境变量 `GMGN_SPACE_FRAME_OUTPUT`
  一次性 PNG)证明"blit 读回 drawable → BGRA→PNG"管线可用,且明确注释
  "only; never captures the desktop"。
- 全舞台相机 = `spatialStage.camera`(`SpatialCameraState`,固定观察相机,
  用户可拖拽/复位;`StageCameraCoordinator.activateFullStage`);头像绘制使用同一
  `cameraView`,头像与空间在同一帧内可见 ⇒ 全舞台当前帧是"环境画面 + 人物自身
  画面"的真实来源。
- `framebufferOnly` 默认 true;读取 drawable 需先置 false(现有 DEBUG 捕获同款做法,
  本次捕获仅在"有请求待处理"时临时放开,编码后还原)。
- 会话/世界:居民世界由 `WorldAgentContext`(`snapshot.worldID` / `snapshot.revision`)
  驱动,`ResidentWorldToolSession` 以 `scopeID/worldID` 做单轮租约并支持
  `AdditionalTool` 注册;`ResidentImageAttachment` 走会话私有文件 URL;
  `StageAvatarRuntimeStore.snapshot.revision/avatar` 与
  `spatialStage.avatarPlacement.position` 是全舞台可观测的"居民在场"事实。
- 工具风格:provider schema(WorldAgentToolContract / ResidentLoopTools)均
  JSON object、参数白名单、无额外路径参数;失败统一 `{"ok":false,"error":{code,message}}`。
- 资源核对:未发现既有 `ResidentVision*` 标识冲突;命名保持交付要求
  `Agent/ResidentVisionTools.swift`、`Presence/ResidentVisionCapture.swift`,
  视角/工具内部 ID 见 §4。

## 3. 已真实实现的视角(诚实登记)

目录 `ResidentVisionCatalog.registeredPerspectives` 当前只有:

- `current_observation`(当前固定观察画面):请求后**新渲染**的全舞台帧的
  drawable 回读——即现用固定观察相机当前真实画面;居民角色在场时可见其自身
  (第三人称房间观察,不是第一人称)。`requiresOffscreenCamera == false`。

未实现 ⇒ 不登记、不进入 schema enum、不可调用:
`global_overview`(全局俯瞰)、`resident_eye`(居民眼睛/头眼)。头眼视角**没有**
用现有第三人称帧冒充;API 层也没有"假装实现"的通道(§6 给出离屏相机可行性与
门槛)。

## 4. 交付接口(稳定契约)

### Presence/ResidentVisionCapture.swift

- 错误码(稳定,`rawValue` 即对外 code):
  `invalid_parameters / perspective_unavailable / capture_unavailable /
  no_picture / stale_world / stale_frame / timeout / cancelled /
  session_mismatch / encoding_failed / image_too_large / file_write_failed`。
- `ResidentVisionCaptureRequest`:`sessionID`(当前居民会话)、`perspective`、
  `worldID`、`expectedWorldRevision`(**请求方期望条件**,非画面帧核对结果)、
  `maximumAge`、`timeout`、`reason`、`includeFileURL`。超时上限 15s、下限 0.5s,
  时限 0.1–10s。
- `ResidentVisionMetadata`(随图返回的 worldID/camera/time 元数据):
  `captureID, perspective, worldID, surface("full_stage_drawable"),
  camera{label,kind,position[yxz],yaw,pitch,fov,coordinateSpace},
  capturedAt, frameIndex, residentAvatarID, residentAvatarFrameRevision,
  residentPosition, expectedWorldRevision, width, height`。
  **诚实边界**:元数据**没有**真实 world revision;`expected_world_revision`
  仅在请求方显式提供时回显,且只是"发起时的期望条件",绝不代表画面帧已被
  核对到该 revision。渲染器当前不提供画面帧的真实世界 revision(render
  revision: unknown),也不得用当前上下文把某个 revision 冒充为帧的 revision。
  `width/height` 是**交付 PNG 的实际尺寸**(编码时为满足传输预算缩小后以
  缩小尺寸为准)。
- PNG 传输预算(`ResidentVisionImagePolicy`):单张 ≤ 512 KiB，为 base64 与元数据留出余量；尺寸护栏
  ≤ 4096(任一边);编码超预算先按 2×2 平均缩小重编码,缩到 128 下限仍超
  预算 → 明确失败 `image_too_large`,绝不静默交付超预算图片。
- `ResidentVisionSingleFlight`(纯逻辑,离线测试直接覆盖):单飞 + 每次请求
  独有 captureID(generation)匹配完成/取消;旧请求迟到的 GPU 完成或旧取消
  任务无法解析/取消新请求。
- `ResidentVisionSurface`(协议,`@MainActor, Sendable`;不依赖 Metal,便于
  假帧源离线测试):`captureCurrentObservation(request:requestedAt:) async`。
  生产实现:`MarbleResidentVisionSurface`(同文件 #if arch(arm64) 内),只回读
  本渲染器 full-stage drawable:请求驱动、单飞、只在请求后取帧、空间切走即报
  `stale_world`、无可见画面报 `no_picture`、被取消报 `cancelled`。无画面视图
  立即失败(不登记、不翻转 framebufferOnly、不空等超时);请求开始前保存
  framebufferOnly **原值**,帧/失败/取消/超时/无画面所有出口都恢复原值,
  绝不无条件置 true(DEBUG 帧导出等可能合法保持 false)。
- `ResidentVisionGate.verdict(...)`:生产门控(旧空间/旧帧/无画面/重载)——
  frame.worldID≠请求 → `stale_world`;上下文 worldID 与帧/请求不一致 →
  `stale_world`;`capturedAt < requestedAt` 或年龄 > maximumAge →
  `stale_frame`;请求方**显式**期望 revision 高于当前世界上下文(重载) →
  `stale_frame`(期望仅是请求条件,不是帧的 revision 证明);空帧 →
  `no_picture`。
- `ResidentVisionCaptureService.capture(_:)`:校验 → 时限内取帧(先到胜出,
  对方取消;调用方取消 → 如实 `cancelled`,取消竞争的迟到帧不解析成其它结果)
  → 门控 → 受预算 BGRA→PNG(`ResidentVisionPNG.encodeBounded`,ImageIO 真实
  编码)→ 会话私有文件(`ResidentVisionFilePolicy`:`<root>/<sessionID>/
  <captureID>.png`,目录 0700/文件 0600/原子写;作用域判定只认
  `root/<UUID>/xxx.png`;清理只限本策略名下会话目录)。**工具合同全程无路径
  参数 ⇒ 模型不能写任意路径。**

### Agent/ResidentVisionTools.swift

- 工具名:`capture_space_photo`;`providerTool()`/`additionalToolSchemas()` 输出
  schema(参数:`perspective` enum=已登记视角、`reason`、
  `expected_world_revision`;`additionalProperties:false`)。**schema 不含
  base64/内联图片参数**。
- `ResidentVisionToolArgumentPolicy.validate`:白名单参数、未实现视角拒绝、
  非负整数 revision、布尔校验。
- `ResidentVisionToolbox.handle(name:argumentsJSON:) async -> (data, isError)`:
  兼容的 JSON 通道,成功载荷:
  `{"ok":true,"image":{mime:"image/png",bytes,width,height,file_url},
  "metadata":{...world_id/camera/captured_at/expected_world_revision...},
  "policy":{...}}`;失败 `{"ok":false,"error":{"code","message"}}`。
  **文本 JSON 绝不含 base64 图片字节**(模型不能"假装看到"图片)。
- `ResidentVisionToolbox.handleImage(name:argumentsJSON:) async ->
  ResidentVisionToolImageReply`:图片通道的强类型产物——成功时
  `image: ResidentVisionImage`(真实 PNG + 元数据 + 会话私有 file_url),
  `payloadJSON` 仅元数据/位置;失败时 `image == nil` + 错误 JSON。供
  CC/主代理接 DSH/Codex 原生图片(ResidentCodexToolReply 集成由主代理/CC
  负责,本交付不改动它)。
- key 一律 snake_case;日期为毫秒时间戳。

## 5. 测试(新增纯离线,跑的是生产逻辑)

用现有 tools harness 约定:把**生产源文件**直接交给 swiftc,配假帧源运行:

- `swift tools/test-resident-vision-capture.swift`
  PASS:84 checks,0 failures——覆盖:目录诚实登记(global/eye 拒绝)、PNG 真实
  编解码、门控各分支(stale_world / stale_frame×2 / no_picture / 重载 /
  accept)、服务成功路径(元数据/文件作用域/0600/磁盘内容一致)、失败路径
  (无画面源 / stale_world×2 / stale_frame×2 / no_picture×2 / 挂起→timeout)、
  文件策略(作用域外拒绝、会话目录清理)、**单飞代次匹配**(A 取消→B 开始→
  A 旧 GPU 完成/旧取消任务迟到都不能触碰 B;同一请求多个迟到回调只有一个
  生效)、**编码预算**(超预算自动缩小到预算内且元数据/解码尺寸一致、尺寸
  护栏 4096、缩到下限仍超 → tooLargeForBudget)、**服务预算路径**(缩小交付、
  超限 → `image_too_large`)、**取消竞争与失败恢复**(完成前取消 → `cancelled`
  非 timeout;取消后同一服务 B 立即成功;超时后同一服务 B 立即成功)、
  **元数据诚实**(未提供期望 revision 时不回显/伪造 world revision)。
- `swift tools/test-resident-vision-tools.swift`
  PASS:63 checks,0 failures——schema 无路径参数、无 include_inline_image,
  只枚举 current_observation;参数校验(未实现视角/负数 revision/路径参数
  被拒/base64 参数已移除);工具成功载荷(image 描述无 data_base64 字样、
  metadata 无 world_revision 伪造、显式 expected_world_revision 作为请求
  条件回显);失败载荷(no_picture / stale_world / session_mismatch /
  tool_not_allowed / invalid_arguments);**handleImage 强类型产物**(成功返回
  ResidentVisionImage、payload 仅元数据无 base64、失败 image==nil 且错误码
  与 handle 一致)。
- 生产文件 Swift 6 严格并发:
  `xcrun swiftc -typecheck -swift-version 6 -strict-concurrency=complete
  Presence/ResidentVisionCapture.swift Agent/ResidentVisionTools.swift` → 0 错误。
- `xcrun swiftc -frontend -parse VisualEngine/Metal/MarbleSpatialView.swift` → 0 错误
  (Marble 文件完整类型检查依赖 MetalSplatter/VRMMetalKit 等,留给 GPU 机器)。

没有启动 App、没有 GPU、没有网络;假帧源只替换"渲染器帧来源"这一薄层,门控/
编码/文件/JSON 全部跑生产实现。取消竞争测试只对生产 `ResidentVisionCaptureService`
与生产 `ResidentVisionSingleFlight` 发起真实 Task 取消,不触碰真实渲染器状态。

## 5.1 主代理审阅五项修复(实际合入)

1. **请求身份 / 取消竞争**:`MarbleResidentVisionSurface` 原先 Pending 无身份,
   A 取消后 B 请求进入时,A 的旧 GPU 完成会解析当前 B、旧取消 Task 也可能取消 B。
   新增生产纯逻辑 `ResidentVisionSingleFlight`(ResidentVisionCapture.swift):
   单飞 + 每次请求独有 captureID(generation);帧源所有完成/取消路径带
   captureID 走 `finish(captureID)`,只有仍是当前请求才生效并恢复状态,过期回调
   一律丢弃。离线测试按"A 取消 → B 开始 → A 旧完成/旧取消迟到"逐拍验证
   (见 §5)。
2. **framebufferOnly 保存并恢复原值**:请求开始时记录
   `hostView.framebufferOnly` 原值;帧回读编码后与所有出口(成功帧 / 失败 /
   取消 / timeout / noPicture / staleWorld)都恢复**原值**,不无条件置 true
   (DEBUG 帧导出可合法要求 false)。无 host(未 attach)→ 立即
   `capture_unavailable`,不登记请求、不翻转标志、不等超时。
3. **强类型图片产物**:保留 `handle(name:argumentsJSON:) -> (data,isError)`
   兼容 JSON 通道,但文本 JSON **删除 base64**(`include_inline_image` 参数一并
   从 schema/校验移除,模型不能靠文本里的 base64 假装看图);新增
   `handleImage(name:argumentsJSON:) async -> ResidentVisionToolImageReply`:
   成功返回强类型 `ResidentVisionImage`,payload JSON 仅元数据/文件位置;
   失败 `image == nil` + 错误 JSON。ResidentCodexToolReply 集成归主代理/CC,
   本交付未改它。
4. **世界 revision 诚实**:元数据本就没有真实 worldRevision;现已消除所有
   "返回 world_revision/已证明 revision"的文档表述。`expected_world_revision`
   只在调用方**显式**提供时回显(不再自动用当前会话 revision 填充),注释/schema/
   工具描述都写明它仅是"发起时的期望条件",画面帧的真实世界 revision 渲染器
   当前不提供(unknown);渲染不拿当前 context 伪造帧 revision。
5. **PNG 尺寸/字节上限**:新增 `ResidentVisionImagePolicy`(单张 ≤ 512 KiB、
   尺寸护栏任一边 ≤ 4096、缩小下限 128)与 `ResidentVisionPNG.encodeBounded`
   (先尺寸护栏,超字节预算按 2×2 box-average 缩小重编码,缩到下限仍超 → 明确
   `image_too_large`,绝不静默交付超预算图)。元数据 width/height 记录实际交付
   尺寸。未添加泛化多视角框架。

## 6. 离屏视角(全局/居民眼睛)评估与 GPU 验收

### 为什么第一增量不登记离屏视角

真实捕获离屏视角需要一条"独立相机第二遍离屏渲染"管线:离屏
`MTLTexture(color)+depth`,用自己的 view/projection 再走一遍
世界(SPZ chunks / LivingPod)、道具与头像;任意一个 pass 缺席都会得到
"假帧/缺件帧",属于视觉欺诈,故不登记。

### 最小接入可行性(证据)

- `SplatRenderer.render(viewports:colorTexture:...)` 已接受任意 viewport 与
  (经 `viewport(for:)`/`viewMatrix`)任意视图矩阵——离屏世界 pass 无需新框架。
- VRM/PMX 头像 pass 均接收外部 `cameraView/projection`
  (`drawVRMAvatar`、`MarblePMXRenderMatrices.fullStage(sharedCameraView:)`),
  因此"从居民眼睛/头眼看向自身身体/房间"的渲染可复用同一批绘制调用。
- 障碍/工作量:共享 renderer 目前只有一个 color/depth 目标(full-stage
  drawable);离屏视角需新增 offscreen target、独立 depth 处理、道具与
  wish-machine pass 的复用/裁剪、avatar 自剔除(第一人称应隐头)、顺序与
  现有 occluder 语义一致、`residentPosition`/头部朝向从 avatar 骨架换算相机。
  这是后续增量,不应塞进"第一增量"的捕获服务。
- Live Cam 帧是透明背景头像特写,不是"空间照片",也未登记;全舞台帧是唯一
  "环境+人物自身同帧"的真实现成来源,故作为第一增量。

### GPU 验收清单(需接线 + 真机,由主代理/GPU 收尾执行)

1. 打开全舞台(must show world+avatar),触发 `capture_space_photo`:
   返回 PNG 与屏幕画面一致(构图、内容),人物/环境均可见;方向上无翻转/镜像
   (BGRA row 顺序与现有 DEBUG 导出管线一致,仍建议目测确认)。
2. 观察期间拖拽相机后再捕获:帧内容为拖拽后的现用相机画面;元数据
   camera.position/yaw/pitch 与画面对应。
3. 捕获时切空间 → `stale_world`;仅 Live Cam/无世界 → `no_picture`/timeout
   文案正确;请求后帧立即返回(≤2 帧),不缓存旧帧。
4. 连续快速调用只发生单次捕获(其余 `capture_unavailable` 或排队语义符合预期);
   无自动持续拍照;空闲时 framebufferOnly 恢复为请求前原值,渲染无可见退化。
5. 捕获中立刻取消(如超时/换轮)再马上发起新请求:新请求必须成功拿到**新**
   画面;旧请求迟到的 GPU 完成/取消不得解析或取消新请求(gen 匹配)。
6. 请求期间 framebufferOnly 先翻 false、帧回读编码后与取消/timeout/noPicture
   路径都恢复请求前原值(DEBUG `GMGN_SPACE_FRAME_OUTPUT` 启用时原值应为 false,
   恢复后仍 false,不破坏 DEBUG 帧导出)。
7. Intel(x86_64,无 Marble 渲染器)→ `capture_unavailable`,不崩溃。
8. 会话目录 `<AppSupport>/gmgn radio/ResidentVision/<runID>/` 0600/0700;
   新会话可 `purgeSessionDirectory`;模型全程无路径参数。
9. 全舞台画面交付 PNG 字节 ≤ 512 KiB 且任一边 ≤ 4096;超大/复杂场景自动缩小,
   元数据 width/height 与实际 PNG 一致;极端不可压缩内容不出现超预算静默交付。

## 7. 待接线(主代理/CC):接口与补丁建议

已就绪的接缝:

- `MarbleSpatialView.residentVisionSurfaceHandle: (any ResidentVisionSurface)?`
  ——非 nil 表示全舞台渲染器可提供真实帧(arm64)。
- `ResidentVisionToolbox(surface:fileRoot:currentSession:)` 与
  `ResidentVisionToolContract.additionalToolSchemas()` / `providerTool()`。
- `ResidentVisionToolbox.handleImage(...) async -> ResidentVisionToolImageReply`
  ——强类型图片产物(image + 仅元数据 JSON),供原生图片通道接线。

建议接线点(不动 CC 文件也可先口头对齐):

1. 持有 stage 表面处(如 `StageRenderSurfaceController` 创建 `surfaceView` 之后):
   把 `surfaceView.residentVisionSurfaceHandle` 交给工具箱。
2. 建立 `ResidentVisionToolbox`(建议随居民世界上下文/每轮 scope 创建或持有):
   ```swift
   let visionToolbox = ResidentVisionToolbox(
       surface: stageSurfaceController.surfaceView.residentVisionSurfaceHandle,
       currentSession: { [weak context] in
           guard let context = context else { return nil }
           return ResidentVisionToolbox.Session(
               runID: currentResidentRunID(),          // 本轮居民会话 UUID
               worldID: context.snapshot.worldID,
               worldRevision: context.snapshot.revision) // 仅作门控上下文
       })
   ```
3. 工具注册:把 `ResidentVisionToolContract.toolNames/toolDescription/inputSchema`
   挂到 CC 的工具通道(如 `ResidentWorldToolSession` 的 `additionalTools`,或
   `ResidentLoopTools` 风格条目),`handle(name:argumentsJSON:)` 直接转发
   `visionToolbox.handle`;结果 `data` 原样回传(错误已是
   `{"ok":false,"error":{...}}`,成功含 image 描述+metadata+policy,无 base64)。
4. 原生图片通道:需要把真实 PNG 交给 DSH/Codex 时用
   `visionToolbox.handleImage(name:argumentsJSON:)`:取 `image.pngData`
   或 `image.fileURL` 作为当轮附件/后续 prompt 的 native image,
   `payloadJSON`(仅元数据)作为模型可见文本;文本里没有图片字节,模型不会
   "假装看到"图。`ResidentCodexToolReply` 集成由主代理/CC 负责。
5. 会话边界:居民 run 结束/新 run 开始时按需调用
   `ResidentVisionFilePolicy.purgeSessionDirectory(root:sessionID:)` 清理旧画面
   (仅作用域内)。

> 提示:若希望"居民在想看画面时能看到 Live Cam/全舞台当前相机",工具语义即
> 上述 `capture_space_photo`(全舞台现用相机);DSH/Codex 原生图片由
> `handleImage` 的强类型产物送达(真实 PNG + 会话私有 file_url + 仅元数据
> JSON),无需把 base64 放进模型可见文本。

## 主代理复核：图片传输余量

单张 PNG 上限收紧为 512 KiB。新增检查证明 base64 编码后的最大图片加
64 KiB 元数据仍低于 1 MiB，避免把 PNG 原始大小直接当作完整传输帧大小。

- `swift tools/test-resident-vision-capture.swift`：85 项通过，0 失败。
- `swift tools/test-resident-vision-tools.swift`：63 项通过，0 失败。
- 以上仍为不启动宿主的生产逻辑检查；未验证 GPU 实际画面或模型视觉理解。

### 本机原生图片协议核对

通过本机 `codex app-server generate-json-schema --experimental` 仅生成接口定义，
未启动模型会话。`DynamicToolCallResponse` 的图片项为
`{"type":"inputImage","imageUrl":"data:image/png;base64,..."}`，与文字项
`{"type":"inputText","text":"..."}` 同列于 `contentItems`，结果同时包含
`success`。图片字段是 `imageUrl`，不是 `image_url` 或本地路径字符串。
官方接口说明：[Codex App Server](https://learn.chatgpt.com/docs/app-server)。
