# 电视机：屏幕几何、画面通路与控制面（设计一页）

状态：**设计已定 + 最小可用切片已落**（见 §6 落点清单）。基线 `6168747`。
作者线：`Screen/`（新目录，本轮独享）。**未提交 git**。

> **2026-10-01 21:5x 补记（遮挡那一级 + 一个必须先说的事实）**
>
> 1. **覆盖层在真机上还没跑起来**：`WorldScreenStore` 在整个 `Sources/GMGNRadio` 里
>    **没有任何构造点** —— `App/GMGNRadioApp.swift` 的粘贴补丁
>    （`docs/plans/2026-10-02-stage-tv-screen-app-patch.md`）**未落盘**，
>    `installScreenPanel` / `screenOverlayHostView` 也无人调用。所以"电视不对"的截图里
>    **不可能**有网页覆盖层：那一块是生成出来的道具网格本身（它的 `baseColorTexture`
>    就是参考图那张壁纸）。接线的决定权在用户/App 那一条线。
> 2. **前景遮挡已做**，做到**格级**（不是逐像素）：`Screen/WorldScreenOcclusion.swift`
>    用**已有的场景几何**（`spatialStage.sceneOccluderTriangles` + 每件物件的
>    `generatedCollisionVolume` 盒 + `avatarPlacement` 的居民盒）在 CPU 上逐格做射线求交，
>    再用 `CALayer.mask`（可见格并集）把被挡的区域裁掉 —— **不碰 shader**。
>    与 §2.3 里设想的那条路（借 `residentVisionSurface` 读回）不同，理由写在
>    `WorldScreenOcclusion.swift` 顶部：那一条读回的是**颜色**不是深度，且是单飞按需的。

一句话：电视 = **物件上的一个屏幕四边形**（`gmgn.screen.v1`，与功能点同一套
"声明在资产元数据 / 运行时派生"的路），画面用 **native `WKWebView` 覆盖层**
按该四边形做透视对齐，内容只走**官方嵌入页**。

---

## 0. 为什么不另造一层

已知机制直接复用，一处都不新增存储：

| 需要的东西 | 已有的唯一来源 | 用法 |
| --- | --- | --- |
| 物件上的"面"挂点 | `WorldPropFunctionAnchors.swift`（局部声明 × 摆放 = 世界锚点） | 屏幕四边形的**局部定义**走同一套坐标系与同一套 `worldPosition(of:placedAt:yaw:)` |
| 物件派生块存储 | `WorldObjectState.metadata["gmgn.*.v1"]` | 新增 `gmgn.screen.v1` / `gmgn.screen-content.v1`，不新建表 |
| 世界→屏幕投影 | `SpatialStageStore.residentPropScreenPoint(world:)`（归一化、左上原点、`0...1`，`guard clip.w > 0.000001` 拒绝背后） | 覆盖层四角**就走这条**，不写第二份 |
| 相机 | `SpatialStageStore.camera`（`position`/`yaw`/`pitch`）+ `MarbleSpatialView.projectionMatrix`（全舞台 fov 66°、near 0.05、far 250） | 覆盖层每帧对齐的输入 |
| 网页能力 | `Settings/MusicProviderWebLoginController.swift`（已在用 `WKWebView`） | 同一种 `WKWebView`，同一个 `@MainActor` 用法 |
| agent 工具 | `ResidentWorldToolSession.AdditionalTool`（`ResidentWishMachineTools` 是模板） | 新增一个自足工具族 `ResidentScreenTools` |

**红线一律不碰**：`consumesScenePointer` 签名、`Float(1 - point.y / bounds.height)`、
面板宽 340、14 条 `场景输入链[N]`、图像判据 A/B、shader、构建提速三项、
`size_intent` 语义、`world_*` 权威、三轴语义、挂点语义、`.inventoryRegistration`/
`.spatialChange` 分层。

---

## 1. 屏幕几何：从已有资产拿到屏幕四边形

### 1.1 形状（`gmgn.screen.v1`，存在物件 `metadata` 里）

局部（**本体坐标系**，原点 = 道具落地点，+Y 向上，与功能点同口径）：

```json
{
  "objectID": "tv-living-01",
  "source": "calibrated",            // calibrated | inferred | default
  "center": [0, 1.05, 0.06],         // 局部坐标，屏幕中心
  "yaw": 0,                          // 屏幕平面绕 Y（弧度，局部）
  "pitch": 0,                        // 屏幕平面俯仰（弧度，局部；挂墙向下倾 = 负）
  "halfWidth": 0.62,                 // 米
  "halfHeight": 0.35,                // 米
  "note": "编辑器标定"
}
```

由 `center + yaw + pitch + halfWidth/halfHeight` **派生**四个角，不存四角：
存四角就能存出一个非平行四边形的"屏幕"，那样宽高比与平面性都变成要校验的自由度。
派生规则（`WorldScreenQuad.corners`）：

```
right  = (cos yaw, 0, -sin yaw)                       // 与 worldPosition 的 yaw 口径一致
fwd    = (sin yaw, 0,  cos yaw)                       // 局部 +Z
up     = normalize((0,1,0)·cos pitch − fwd·sin pitch)
正常   = normalize(fwd·cos pitch + (0,1,0)·sin pitch)
corner = center ± right·halfWidth ± up·halfHeight     // BL, BR, TR, TL
```

世界角点 = 道具摆放 transform ∘ 局部角点，**就是**
`WorldPropAnchorRegistry.worldPosition(of:placedAt:yaw:)`（只绕 Y）。所以电视被搬动/
旋转时屏幕跟着走，且不新增第二条"物件怎么变换到世界"的规则。

### 1.2 来源优先级（**高到低，命中即停，命中哪一级必须写进 `note`**）

1. **① 用户/编辑器标定** — `metadata["gmgn.screen.v1"]` 合法即用，
   `source = calibrated`，`note` = 用户可读的一句（编辑器写的是"编辑器标定：
   宽 1.24 m × 高 0.70 m"）。
2. **② 由网格/包围盒推断** — 没有标定块、但有这件道具的**尺寸**（生成道具的
   `gmgn.generated-prop.v1.size`，或承托网格派生出来的 footprint）时：
   - 取三对面里**面积最大**的一面（XZ / XY / YZ），要求
     **面积 ≥ 0.04 m²**（约 20 cm × 20 cm，低于这个尺寸的"面"不是屏幕，是零件）；
   - 要求这件道具**像一块板**：最薄的那一轴 ≤ 最长轴的 `1/4`
     （否则一个方块柜子每一面都够大，"最大面"就是掷骰子）；
   - 通过 ⇒ `source = inferred`，屏幕中心 = 该面中心 + 法向外移 1 mm，
     `halfWidth/halfHeight` = 该面半尺寸 × `0.86`（面板边框留边），
     `note` = **"由最大平坦面推断：法向 +Z，面积 0.87 m²（不是标定值，可在编辑器里改）"**。
   - 不通过 ⇒ 不产出 ②，落到 ③，并**把拒绝原因带上**（`notPanelLike` /
     `belowAreaThreshold`）。
3. **③ 缺省 + 可见说明** — 尺寸也没有时，用一件**通用电视**的缺省
   （宽 1.10 m × 高 0.62 m、中心高 1.05 m），`source = default`，`note` =
   **"缺省未标定：假定 1.10 m × 0.62 m 的一台电视。屏幕位置是猜的，
   请在编辑器里标定。"** —— 与我们"不确定就说不猜"的纪律一致：**猜了就必须说出来**。

**硬约束（类型层强制）**：`WorldScreenDefinition.isValid` 要求 `note` **非空**。
一条没有出处说明的屏幕定义**根本无法构造成功** —— "不硬猜"不是靠自觉，是靠类型。
连缺省都拿不到（既无标定、又无尺寸、又无法给缺省）时**不返回缺省**，而是
`nil` + `WorldScreenGeometryIssue.missingGeometry`（具名、可见，见 §4）。

### 1.3 存哪儿、谁写

- **资产侧**（标定）：物件 `metadata["gmgn.screen.v1"]`。编辑器写它，等价于
  给这件道具钉一个"面"。
- **运行时不落盘**：派生出来的世界四边形永不落盘，每次由（定义 + 摆放）重算 ——
  与"锚点永不落盘"同一条纪律，于是屏幕不可能与摆放分叉成两份事实。
- **画面内容**另存 `metadata["gmgn.screen-content.v1"]`（`kind` + `url` + `title`），
  因为它是"这一台电视现在放什么"，与"屏幕在哪"是两个生命周期。

---

## 2. 画面怎么画：A（贴纹理）还是 B（native 覆盖层）

### 2.1 两条路的实测量纲（本机：Apple Silicon，全舞台 66° / near 0.05 / far 250）

| 量 | A：WKWebView 内容 → Metal 纹理 | B：native `WKWebView` 覆盖 + 透视对齐 |
| --- | --- | --- |
| 每帧成本 | WebKit 渲染 → **`IOSurface` → `MTLTexture` 每帧一次拷贝**。1280×720 BGRA ≈ **3.5 MB/帧**；60 fps = **210 MB/s** 带宽，全部在主线程/合成器同步点上 | **0**：`WKWebView` 自己是 `CALayer`，合成器直接合成，没有我们的拷贝 |
| 分辨率 | 受纹理尺寸限制；要做到"近看清晰"得 1920×1080（8.3 MB/帧，**500 MB/s**） | 屏幕上本来就是 **backing scale 像素**（Retina 下 2×），零损失 |
| 刷新率 | 我们的 render loop 是 `StageRenderFramePacer`（full 60 / balanced 24 / low 12）；WebKit 自己的 cadence 另算。**两个 cadence 不同源** ⇒ 要么撕裂要么等帧 | WebKit 与 AppKit 合成器同一个 cadence，天然同步 |
| 复杂度 | 要新增：`IOSurface` 绑定、色彩空间（BGRA/sRGB）转换、深度/遮挡写入、shader 采样、resize 处理。**并且要动 shader**（红线：不许碰） | `CATransform3D` 一个矩阵 + `WKNavigationDelegate` |
| 交互 | 要自己把命中转回网页坐标系（等于重写一遍 WebKit 的事件路由） | 免费（本轮**故意关掉**，见 §2.3） |
| 文字/视频清晰度 | 受纹理过滤影响，斜视角下糊 | 清晰 |

### 2.2 推荐：**B**，理由是数据而不是偏好

1. **A 的每帧拷贝与"分辨率 × 60 fps"直接相乘**，而屏幕上要的正是"近看清晰"（电视）。
   3.5 MB/帧 × 60 = 210 MB/s 是**纯开销**，换来的清晰度还**低于** B。
2. **A 必须碰 shader**（新增纹理采样通道），而 shader 是红线。B 完全不进渲染管线。
3. A 会把 WebKit 的 cadence 与 `StageRenderFramePacer` 强行对齐，**两个不同源的
   时钟**是撕裂与抖动的经典来源；B 让合成器自己处理。
4. A 的遮挡是"真"的（写深度），B 需要自己处理 —— 这是 B **唯一**的实质劣势，
   处理方式见 §2.3，且对"一面墙上的电视"这个主用例是够的。

**结论：B。** A 保留为将来的"屏幕要进画中画/要出现在镜面反射里"的备选，
但那时也得先证明 500 MB/s 与 shader 改动值得。

### 2.3 B 的四个行为（一件 / 两件 / 走开 / 被挡住）

| 情形 | 行为 |
| --- | --- |
| **一件电视** | 一个 `WKWebView`，容器 `hitTest → nil`，每帧（相机变）更新 `CATransform3D` |
| **两件电视** | 每个 `objectID` 一个 `WKWebView`。**同时播放上限 = 2**（第三个开始排队并可见说明"同时最多放 2 块屏幕"）；理由是每块屏一个 WebKit 内容进程，内存与解码都线性涨。看不见的屏自动 `pauseAllMediaPlayback`（省电、省内存），重新看见时 `play` |
| **玩家走开 / 相机移开** | 四角里有角点 `clip.w ≤ 1e-6`（在相机背后）⇒ **整块隐藏**，不画半个屏幕；屏幕完全在视口外 ⇒ 隐藏。隐藏时**暂停**媒体（不是销毁，回来不掉登录态） |
| **屏幕被挡住** | 分级（诚实标注"做到哪一级"）：① **背向剔除**（**已做**）——屏幕法向与"相机→屏幕中心"反向 ⇒ 直接隐藏并写具名原因（`hiddenReasons`），这是最常见的"转过背面"；② **前景遮挡**（**已做，格级**，见 2026-10-01 补记）——不是「退让 alpha」，而是**区域级掩码**：`WorldScreenOcclusion` 从相机到每一格中心做射线求交（遮挡物 = 房间三角面 BVH + 物件盒 + 居民盒），被更近的东西挡住的那几格用 `CALayer.mask` 裁掉、其余照画（「人挡住左半边」＝左半边不画、右半边照画）。24 × 14 = 336 格；一格不挡时**摘掉** mask（正常观看零裁切、零抖动）；③ 逐像素遮挡**不做**（要深度回读 ⇒ 要动渲染器与 shader，那是红线）。观感验收项见 §5。 |
| **世界不可见时** | `!spatialStage.isWorldVisible`（Live Cam 模式、世界未呈现）⇒ 整块覆盖层隐藏、媒体暂停。**这一条同时挡住"Live Cam 窗口的相机与舞台相机不同源"这个坑**：覆盖层只在 `.fullStage` 世界呈现时存在 |

### 2.4 最小可行验证要量什么

| 项 | 怎么量 | 及格线 |
| --- | --- | --- |
| 几何一致性 | harness：把生产 `perspectiveMatrix` / `rotationX/Y/translation` / `residentPropScreenPoint` 的**源码原文**切进测试程序，与我这份投影逐点比对（多相机位姿 × 多角点） | 归一化空间 **≤ 1e-5**；覆盖层矩阵回投四角 **≤ 0.5 px**（1080p） |
| 相机移动后仍对齐 | 同上，但相机沿一条 12 步轨迹（yaw −0.8→0.8、pitch −0.5→0.5、distance 0.6→3.0） | 每一步都 ≤ 0.5 px |
| 帧率 | 真机：1 块屏 / 2 块屏 / 0 块屏 各 60 s，读 `StageRenderSurfaceController` 的 cadence 与 `CADisplayLink`-等价计数 | 1 块屏 **≥ 55 fps**（相对 0 块屏掉 ≤ 3）；2 块屏 **≥ 45 fps** |
| 延迟（对齐跟手） | 屏幕上放一个网页内的动画方块，拖动相机，录屏逐帧数 | ≤ 2 帧（33 ms）滞后 |
| 内存 | 真机 `footprint`：0 / 1 / 2 块屏，各稳定 60 s 后取 | 每块屏 **≤ 180 MB**；切走 60 s 后回落 ≥ 80%（证明真的暂停了） |
| 遮挡正确性 | 走到屏幕背面 / 让角色站到屏幕前 | 背面 ⇒ 100% 隐藏；角色在屏前 ⇒ 明显退让，**不许**出现"人身上糊着一块网页" |
| 鼠标不冲突 | 开着屏，装修模式里点/拖/转 + 相机拖拽 | 与没有屏时**同一条链**（14 条 `场景输入链[N]` 输出逐条一致），装修的拾取/落地/旋转一次都不掉 |

---

## 3. 内容与合规：什么能放，什么注定放不了

**明确不做**（红线，且 harness 会扫）：抓流（yt-dlp / youtube-dl / googlevideo
直链 / `signatureCipher` / `streamingData` 解析）、绕过登录、绕过地区限制、
伪造 UA 骗过风控、DRM 密钥（Widevine/FairPlay）注入。

### 3.1 YouTube 官方嵌入（`https://www.youtube.com/embed/<id>` 或 `youtube-nocookie.com`）

- **能用吗**：能，**但不可靠**，必须当成"可能失败"来设计。
- **需要**：外网可达（`www.youtube.com` + `googlevideo.com` + `ytimg.com`）；
  **地区**必须是被允许的地区（否则播放器自报"视频在该地区不可用"）；
  **UA** 要像 Safari —— `WKWebView` 在 macOS 上默认就是 Safari 家族 UA，**照实不改**；
  **登录态**对"公开视频"不需要，对"私享 / 会员 / 年龄限制"需要，且要用户在**这个
  web 视图里自己登录**（我们不代填、不代持凭据）；**DRM**：YouTube 的部分内容走
  Widevine，**macOS `WKWebView` 拿不到 Widevine** ⇒ 那类内容在这里**注定放不了**。
- **注定放不了的**：DRM/会员专属、需要电视端授权的、被 WebKit 判为不支持 MSE 的
  直播（HLS 之外的 MSE 路径在 macOS WebKit 上时好时坏）。

### 3.2 哔哩哔哩官方嵌入（`https://player.bilibili.com/player.html?bvid=...`）

- **能用吗**：能，同样**不可靠**。
- **需要**：外网可达（`player.bilibili.com` + `upos-*.bilivideo.com`）；
  **地区**：番剧/影视类有地区限制，且**部分内容要求登录**；
  **UA**：默认即可，但我们**不伪造**；**登录态**：普通 UGC 通常免登录，
  番剧/大会员内容需要用户在 web 视图里自己登录；**DRM**：B 站不公开 Widevine
  Web 通路，会员高清/杜比在 `WKWebView` 里**大概率放不了**。
- **注定放不了的**：大会员专属清晰度、需要 App 端 token 的接口、地区限制内容。

### 3.3 合规替代路径（本切片落地前两条）

1. **官方嵌入**（本切片）：只接受**官方嵌入页** URL。校验器是**白名单**，
   不是黑名单 —— 不在白名单里的一律具名拒绝（`不是官方嵌入页`）。
2. **用户在 web 视图里自己登录**：本切片**不做**登录 UI（也就不做凭据存储）。
   设计上留的位置：嵌入页自己会弹登录，`WKWebView` 用默认
   `WKWebsiteDataStore.default()` 就能保持会话；**我们不读 cookie、不导出、不代持**。
3. **用户提供的直链 / 本地文件**：设计上留 `kind`（`direct` / `local`），
   用 `AVPlayer` 或 `<video src>` 播。**本切片不做**（先把官方嵌入这条钉死）。

**一句话给用户**：这个 app 里，"电视"能放**官方嵌入页允许你放的东西**；
DRM 内容、会员专属、地区限制内容，在这里**放不了**，我们不会绕。

---

## 4. 控制面

### 4.1 用户：面板（宽 340，与既有面板同规格）

`ScreenPanel`（新文件 `Screen/ScreenPanel.swift`，SwiftUI + `ObservableObject`）：

- 屏幕列表（每件电视一行：名称、几何来源徽标 `标定 / 推断 / 缺省`、几何 `note` 原文）
- 每行：**开 / 关**、**换片**（URL 输入框 + "载入"）、当前状态徽标
  （`准备中 / 播放中 / 失败：<一句原因>`）
- 底部一行：**"同时最多放 2 块屏幕"** 与当前占用数
- 几何来源是 `default` 时，那一行**必须**显示 `note` 全文（"不猜"要看得见）

编辑器：本轮**不新增**编辑器 UI（`ResidentPropEditorView` 是别人在改的面板）。
标定走**面板里的三个数字**（宽 / 高 / 中心高）与"以当前朝向为准"，
写进 `metadata["gmgn.screen.v1"]`，`source = calibrated`。

### 4.2 agent：三个工具

| 工具 | 入参 | 成功回执 | 失败 |
| --- | --- | --- | --- |
| `play_screen` | `object_id`(可空 ⇒ 唯一那块屏) / `url`(必填) | `{"status":"playing","screen_id":…,"source":"official_embed","url":…}` | 见下 |
| `stop_screen` | `object_id`(可空) | `{"status":"stopped","screen_id":…}` | `screen_not_found` |
| `read_screen` | 空 | `{"screens":[{"screen_id","source","note","aspect","state","url"}]}` | — |

**失败与"信息不足"必须可见，且走**正确**通道**（与既有 `insufficient_input` 同一语义、
同一字面量）：

| 情形 | `code` | `isError` | 用户/agent 读到的一句 |
| --- | --- | --- | --- |
| 没给 URL（用户还没说要放什么） | `insufficient_input` | **false**（成功通道） | `还没说放什么。给我一个官方嵌入页链接（YouTube / 哔哩哔哩），或先在面板里选一部。` |
| 这台电视没有屏幕几何 | `screen_geometry_missing` | true | `这台电视还没有屏幕：缺标定也没有可推断的尺寸。请在面板里标定宽高。` |
| 不是官方嵌入页 | `screen_content_rejected` | true | `只支持官方嵌入页。` + 具体原因（协议不是 https / 域名不在白名单 / 不是嵌入路径） |
| 找不到物件 | `screen_not_found` | true | `这个空间里没有这台电视。` |
| 网络不通 / 嵌入被拒 / 超时 | `screen_load_failed` | true | `官方嵌入页加载失败：<NSURLError 一句话> / 页面返回 4xx / 20 秒没有加载完成。` |
| 已经有 2 块屏在放 | `screen_capacity_exceeded` | true | `同时最多放 2 块屏幕，先关一块。` |

`insufficient_input` 走 `isError: false` 是**刻意的**：它是"信息不足"而不是"操作失败"，
`WishMachineContract.Code.needsInput` 已经把这条语义钉成同一个字面量，
**同一个语义在两个面上不许叫两个名字**。

### 4.3 工具族的插口

`ResidentScreenTools` 自带 `[ResidentWorldToolSession.AdditionalTool]` 的**形状**，
但**不依赖任何 App 类型**（回执用自带的 `WorldScreenToolReply{ payloadJSON, isError }`）。
App 侧只需两行（见 §6 的粘贴补丁）：构造一次 + 拼进 `additionalTools` 那一串。

---

## 5. 范围与风险

### 5.1 现在就能做（本切片已落）

- `gmgn.screen.v1` 的**形状 + 校验 + 三级来源**（标定 / 最大平坦面推断 / 缺省带说明）；
- 世界四角派生（复用 `worldPosition`）+ 归一化投影（复用 `residentPropScreenPoint` 的算式）；
- native `WKWebView` 覆盖层 + `CATransform3D` 透视对齐 + `hitTest → nil`；
- 官方嵌入白名单 + 具名失败 + 加载超时看门狗；
- `play_screen` / `stop_screen` / `read_screen` 与 `insufficient_input` 成功通道；
- 面板模型 + 视图。

### 5.2 需要新能力（不在本切片）

- **逐像素遮挡**：要把深度图读回来（`residentVisionSurface` 已经在读回帧，
  可以借那条路），成本与收益都要先量。
- **屏幕进反射 / 画中画**：A 方案，要碰 shader（红线，得先解禁）。
- **直链 / 本地文件**：`kind = direct|local` + `AVPlayer`。
- **多块屏 > 2**：要内容进程预算与显存预算。
- **在屏幕上点击/滚动**：见 §5.3 的鼠标。

### 5.3 风险表

| 风险 | 严重度 | 现状 / 退路 |
| --- | --- | --- |
| **鼠标冲突** | 高（14 条输入链是红线） | 覆盖层容器 `hitTest → nil`（**不吃任何事件**）。不做"操作电视"模式：那要动 `consumesScenePointer` 的判据输入或它的调用点，而签名与 14 条链都是红线。电视在本切片里**是显示屏，不是输入设备**；控制一律走面板 / agent |
| **遮挡不正确** | 中 | 背向剔除是精确的；前景遮挡是**格级**（24 × 14），不是逐像素 —— 人的轮廓会被量化成格边（1080p 下每格约 52 × 50 px）。判据侧已量：角色站在屏前 0.6 m ⇒ 196/336 格被挡、两侧 140 格照画；相机 1 mm 手抖 0 格翻转；2000 个房间三角面 + 1 个盒时重建一次掩码 **0.037 ms**。**仍必须真机看**：角色站在屏前的观感 |
| **多屏性能** | 中 | 上限 2；看不见就暂停；真机量 fps/内存 |
| **合规** | 高 | 白名单 + 静态扫描（抓流 token 在 `Sources/GMGNRadio` 里必须为 0），有负对照 |
| **几何在别处又被定义一份** | 中 | 投影算式以生产源码原文切进 harness 比对（漂移 ⇒ 红） |
| **嵌入住不上（DRM/会员/地区）** | 高 | 诚实告知 + 具名失败。**这是产品边界，不是 bug** |
| **`StageWindowController` 被别线改** | 中 | 我对它的改动是**一处**新增（容器 + 宿主），不动既有行 |

---

## 6. 落点清单（本轮实际写了什么）

新增（全部新文件，`Screen/` 目录本轮独享）：

- `Screen/WorldScreenGeometry.swift` — 四边形（`center/yaw/pitch/半宽高` → 四角派生）/定义/校验/唯一解码口
- `Screen/WorldScreenInference.swift` — 最大平坦面推断（面积阈值 + 板形判据）
- `Screen/WorldScreenProjection.swift` — 与生产同算式的投影 + 单应矩阵 + 背向判据
- `Screen/WorldScreenContent.swift` — 官方嵌入白名单 + 具名失败
- `Screen/WorldScreenOverlayController.swift` — `WKWebView` 覆盖层（AppKit）；容器 `hitTest` 恒 `nil`
- `Screen/WorldScreenState.swift` — 屏幕状态与四种加载失败（纯值，可离线编译）
- `Screen/WorldScreenStore.swift` — 把上面几件接起来 + 面板/agent 的公共入口
- `Screen/ScreenPanel.swift` — 面板模型 + 视图
- `Screen/ResidentScreenTools.swift` — `play_screen` / `stop_screen` / `read_screen`（不依赖任何 App 类型）
- `Screen/WorldScreenMetadata.swift` — `WorldObjectState` 上的读写口（`gmgn.screen.v1` / `gmgn.screen-content.v1`）

改动（局部 edit，别线未在改这两个文件）：

- `VisualEngine/StageWindowController.swift` — 新增覆盖层容器 + 面板宿主（一处新增）
- `Makefile` — `_test-harnesses` 末尾追加一条

**未落、只给粘贴补丁**：`App/GMGNRadioApp.swift`（`mtime` 0 分钟，点唱机线正在改）——
补丁见 `docs/plans/2026-10-02-stage-tv-screen-app-patch.md`。

验证：`tools/test-resident-screen-overlay.swift`（5 条断言 + 3 条注入负对照；已挂进
`make test-harnesses`）。

**本切片明确没做**（每一件都在上面写清了理由）：逐像素遮挡（**格级前景遮挡已做**，见 2026-10-01 补记）、屏幕上点击、
持久化（`WorldScreenStore.Source` 的两个 `persist*` 闭包留空 ⇒ 标定与换片只在本次会话内生效）、
直链/本地文件。
