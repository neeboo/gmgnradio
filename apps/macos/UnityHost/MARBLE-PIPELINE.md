# Unity Marble 正式空间包链

这条链只响应明确的设置命令。构造桥、刷新列表、重启恢复均不会提交新的生成请求。

## Host 接线

创建 `UnityMarbleWorldBridge(root:authority:blobRoot:services:runtimeReady:register:onRegistered:)`，把它传入 `UnitySpaceLibraryBridge` 的 `marble:` 参数。`authority` 必须复用当前宿主的真实 endpoint/helper/session，`blobRoot` 为同一 taskServiceRoot 下的 blobs，不创建第二权威。

- `root` 与 Unity 当前独立根一致；密钥仅从 `root/secrets/world-labs-api-key` 读取，下载目录为 `root/gmgn radio/MarbleCache`。
- `runtimeReady` 只有真实 SPZ 通用渲染和同包碰撞消费均接通后才能返回 true；仅编译通过不足以开启。
- Rust Marble 控制负责创建或恢复对应权威记录；`register` 使用 `UnityMarbleAuthorityRegistration` 只读校验包及回执，验证世界编号、包编号/版本、初始源字节 SHA256 与最新状态 digest；回读通过才返回 true。不同 existing 记录拒绝覆盖，合法演进的同包状态保持原样。
- `onRegistered` 返回 `spaceLibrary.registerPackage(package)`，让已验证包出现在真实选择列表。生成完成不会自动更改原空间。
- `registeredWorldRoots()` 加入 `UnityMarblePackageBuilder.registeredRoots(root:)`，恢复已经成功登记的包。
- settings 命令路由和白名单加入 `UnityMarbleWorldBridge.supportedCommands`；设置快照合并桥状态。

命令为 `space.marble.generate`（`presetID`）、`space.marble.resume`、`space.marble.import`（确切 `worldID`）、`space.marble.cancel`。Rust 生成原始 HTTP 请求计划、持久 claim 和轮询时钟，原生 `MarbleWorldClient` 只执行指定 method/path/body；不按目录名称匹配生成结果。Rust 校验操作响应的 `response.world_id`，随后计划读取同编号世界资源。

## 正式包与坐标

目录为 `root/gmgn radio/WorldPackages/SHA256(worldID)`。包含 `world.json`、`scene.spz`、`collider.glb`、`marble-runtime.json`。manifest 对三份资源逐一记录 SHA256；资源类型分别为 `environment.spz`、`environment.collider`、`environment.marble`。

`UnityMarbleRuntimeDocument` schema 1 记录：`worldID`、`splatPath`、`colliderPath`、`colliderAxisConversion`、`origin`、`uniformScale`、`minimum`、`maximum`。SPZ 经 SplatIO 实际解码为 RDF 坐标，Rust 指定抽样索引及视景变换；原生全点校验不跳过解码错误。原始 GLB 三角面和碰撞测量按 SHA 文件登记到同一权威，Rust 分页选择落点。API glTF collider 采用 identity；已声明 WorldLabs OpenCV 的来源采用 flipYAndZ。游戏位置为 `(转换后的源位置-origin)*uniformScale`。

manifest 实体、spawn、waypoints 已经是游戏坐标，calibration 为 identity/1；视觉与碰撞消费环境 metadata 的单一变换，避免重复应用。spawn 由真实 GLB 三角面及原碰撞可站立查询测得；没有安全位置则明确失败，不复制生活舱锚点和物件。Unity 支持范围为 SPZ v2、SH0–3；注册前检查格式并完整解码，其他版本拒绝登记。

SPZ 点数上限与 Unity GPU 的正式上限一致，为 8,600,000。Host 初始 capability 为 false，只接受 C# 实际后端确认 `world.runtime.capabilities` 中整数 `marbleSPZVersion: 2` 后开启；布尔、非整数、其他版本和 closed 时的回执都拒绝。

`registered.sha256` 只在 authority 注册读回成功后写入，内容为 manifest SHA256。重启读取同时验证 marker、manifest 和全部资源完整性；下载缓存、待注册包、改坏的文件不进入选择列表。

## 失败与取消

生成 operation ID、动作回执和 preset 包绑定保存于 taskd 的同一 SQLite。旧 pending 文件仅用于一次只读导入，不再写回。只有显式 resume 才续查既有任务；未知付费提交不得自动重放。存在待处理 operation 时拒绝再次生成。服务错误、identity 缺失、格式或碰撞失败、权威回读拒绝均投影为 failed，保持原选择。HTTP 错误只公开状态码，不回显服务响应中的可能凭据。

已注册 preset 保存 manifest-bound 回执，`activatePreset` 可复用同一待处理操作或正式包，重启后不重复生成。Host 的 `setSpatialEnvironment` 等待登记后再发真实选择请求，只在 selection revision、activate 阶段、当前世界和持久选择均一致后继续天气设置。等待超时或取消会撤销该未激活请求，迟到渲染回执不能退役原世界会话。

权威 `world_snapshot` 不提供包编号；包身份来自 `world.imported` 事实。原始 seed 的 preimage SHA256 与该事实比对；最新 `world.imported` / `world.stateCommitted` 的状态 SHA256 与当前快照一致。新导入还要求 import 回执与快照 hash 一致、解码状态等于原始 seed。Swift 的 Date/Float 重编码会改变规范 JSON 表现，不把 Swift 重编码 hash 当成 Rust 服务的 canonical hash。

本地取消停止下载/注册推进，并保留 operation 回执供恢复。当前服务没有接入远端取消 API，因此投影说明远端任务可能仍在进行；不将取消按钮当作远端生成已终止的证明。取消已提交的 authority 注册可能留下未展示记录，后续 resume 必须以宿主幂等注册及读回为准。

## 验证范围

`python3 tools/test-unity-marble-pipeline.py` 使用临时 localhost HTTP 服务、真实 taskd 及隔离根，编译真实 Client、Cache、SplatIO、WorldRuntime、包构建、注册 helper 与桥。覆盖 generate/poll/确切 world 查询、SPZ 和 GLB 实际下载/解码、hash 校验、实际 import/facts/snapshot 回读、演进状态幂等保留、列表可用、重启与 preset 复用、无隐式选择、错误 identity、取消回执、拒绝注册、runtime gate 和资源篡改。包身份和状态 hash 不一致的 negative fixtures 明确拒绝，且不写原记录。

`python3 tools/test-unity-marble-host-wiring.py` 编译 Host 的真实 capability 和空间设置方法切片，用隔离状态边界验证整数回执、选择 revision/currentID/持久记录等待、天气先后顺序与取消旧空间保留。

临时 taskd 的真实回读已经验收；上述测试未操作用户 authority，也不能证明 Unity 实际渲染完成。真实付费生成、正式服务返回格式、实际场景渲染与用户空间切换需分别验收。
