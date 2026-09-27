# 生活空间：素材生成、角色复用与演出包实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal：**让创作者用图片生成独立物件，让居民使用这些物件，并能换角色表演带音乐和运镜的舞蹈，逐步形成素材服务与授权内容市场。

**Architecture：**继续使用现有 Metal 客户端、Marble 空间、角色与动作系统、播放器及通用居民循环。生成任务在独立服务执行，客户端只接收经过校验的素材包；模型、动作、歌曲、镜头、交互能力和授权分别记录，通过包清单组合。

**Tech Stack：**Swift、Metal、WorldRuntime、GLB、VRM／PMX、VRMA／VMD、现有音乐库；候选生成后端为 ComfyUI 的 Pixal3D／TRELLIS.2 工作流；参考 Lobe Vidol 的演出组织与镜头适配。

日期：2026-09-06。状态：计划初稿已完成公开资料、工作流 JSON 和现有工程入口核对。用户随后授权子任务在其 DGX 现有环境旁搭建图片转道具服务、开放测试 API 并生成样品，现已开始环境检查；生成与空间融合结果尚未验收。主任务继续居民自主行动，素材服务作为主线依赖，不能替代居民行为验收。与[总路线](2026-09-05-living-space-roadmap.md)配套，覆盖阶段 2—5 的能力扩展以及阶段 7—8 的经营与合作方向。

## 一、产品判断与边界

最新排期以[许愿机与分级建造模式计划](2026-09-06-wish-machine-and-build-modes.md)为准：先完成简单图片生成与摆放、保存、下载分享，再做有限手持与网页；高级 CAD／机器人式装配后置。下方任务编号保留原研究拆分，不要求先完成任务 1—3 的演出系统才实施物件任务 4—5。当前生成服务已产生真实咖啡机，详见[证据](evidence/2026-09-06-complex-prop-coffee-machine.md)；通用空间导入与居民使用仍未验收。

图片转 3D 可以成为“原材料服务”的生产入口，但生成成功只证明取得了候选外形。进入生活空间，还要解决真实尺寸、落地位置、轻量化、碰撞、材质兼容和用途。用户购买或制作的是可以摆放和使用的东西，生成模型不应自动获得未实现的功能。

三类生产线保持分工：

| 生产线 | 主要产物 | 进入产品前要补的内容 |
| --- | --- | --- |
| Marble 空间 | 环境视觉与空间底稿 | 尺度、碰撞、导航、交互语义与可变物件 |
| 图片转 3D | 独立道具、家具、饰品候选 | 轻量 GLB、原点、尺寸、碰撞、安装点和能力绑定 |
| 角色与演出 | 人物、动作、歌曲和运镜组合 | 骨骼适配、统一时间、空间适配、打断与授权 |

首批保持一名居民、当前生活舱。先复用已存在的素材和动作，不要求先建交易市场、完整编辑器、自动绑定骨骼系统或迁移引擎。生成一把剑只能得到道具候选，战斗数值与技能规则另行实现；生成一个人物外形不等于获得可直接使用的 VRM。

## 二、已核对的依据

### 2.1 用户提供的 Comfy 工作流

链接：[Pixal3D & TRELLIS.2: Image to Model](https://comfy.org/workflows/920c795f693a-920c795f693a/)。页面介绍单图生成带 PBR 材质的模型，并在两种模型之间切换。

已只读获取[工作流 JSON](https://comfy.org/workflows/download/920c795f693a.json?filename=920c795f693a)，当次 SHA-256 为 `a4ffdea180901016255224df7e509f7db0fe2325f688a8c4376bf153dcf1b7a0`。这是包含 `nodes` 的编辑器图，不能将其原样当作已验证的服务调用载荷；实施时还需导出并核验 API 格式、输出节点与目标运行环境。

实际图中包含去背景、形状与纹理生成、重建网格、减面、UV 展开、纹理与法线烘焙以及 3D 保存节点。`DecimateMesh`（186）参数为 `700000`，纹理烘焙含 2,048 分辨率；这些是模板参数，不是客户端预算，也不保证最终产物数量或质量。轻量版本必须另外验收。

Comfy 官方说明这两种模型已有原生集成：[集成说明](https://blog.comfy.org/p/trellis2-and-pixal3d-are-now-native)。具体节点在云端、稳定版和自托管版本的可用性仍需检查。模型本体分别参考 [TRELLIS.2](https://github.com/microsoft/TRELLIS.2) 与 [Pixal3D](https://github.com/TencentARC/Pixal3D)。不以模型演示耗时推算端到端报价，不承诺普通 Mac 本地推理；先验证远端生成、低配置客户端使用产物的分工。

### 2.2 Lobe Vidol

核对源码版本 `39f3d3a376cb12919c3df7060910a07df7fcd7ed`：

- [舞蹈结构](https://github.com/lobehub/lobe-vidol/blob/39f3d3a376cb12919c3df7060910a07df7fcd7ed/src/types/dance.ts)将动作 `src`、音频 `audio`、可选镜头 `camera` 和作者说明组合起来。
- [Viewer](https://github.com/lobehub/lobe-vidol/blob/39f3d3a376cb12919c3df7060910a07df7fcd7ed/src/libs/vrmViewer/viewer.ts)加载音频和镜头，再启动 VMD 动作与播放；按帧推进角色与镜头，音乐结束恢复待机。它是编排素材播放的参考，不能据此声称支持任意歌曲自动编舞。
- [镜头加载](https://github.com/lobehub/lobe-vidol/blob/39f3d3a376cb12919c3df7060910a07df7fcd7ed/src/libs/VMDAnimation/loadVMDCamera.ts)参考价值在于镜头轨道转换与尺度适配。其经验尺度不能直接用于我们实际房间，不照搬注释中的 MMD 单位假设。
- 程序采用 [Apache 2.0](https://github.com/lobehub/lobe-vidol/blob/39f3d3a376cb12919c3df7060910a07df7fcd7ed/LICENSE)。实施时核对实际复用文件与依赖的声明并保留相应通知；舞曲、动作、角色和舞台的许可单独检查。

### 2.3 跨游戏角色与动作

借鉴的是“角色资产与动作分离，再做骨骼映射与适配”的制作方式。[Epic 官方重定向教程](https://dev.epicgames.com/documentation/fortnite/transfer-character-animations-in-unreal-editor-for-fortnite?lang=en-US)提供了具体流程；这不证明每个商业联动都直接搬用原游戏文件。原游戏逻辑、装备效果、战斗系统不会随外形自动导入。

VRM 动作优先遵循 [VRMA 标准](https://vrm.dev/en/vrma/)，PMX／VMD 保留独立兼容路径。相同动作在不同身高、骨骼、服装上仍需检查。商业联动仅使用明确授权来源，不将网络可下载或用户购买游戏视作再分发许可。

## 三、现有工程与缺口

以下路径相对 `/Users/ghostcorn/dev/gmgnradio`；拟新增文件仅为实施落点，实施前确认是否已有等价实现。

| 范围 | 复用入口 | 需要补齐 |
| --- | --- | --- |
| 动作包 | `apps/macos/Sources/GMGNRadio/Presence/MotionPackageStore.swift` | 演出组合清单，避免把音乐塞进单动作格式 |
| VMD 动作 | `apps/macos/Sources/GMGNRadio/MMD/VMDMotionDocument.swift`、`NanoemVMDLoader.swift`、`VMDToVRMClipAdapter.swift` | 当前自有文档提取骨骼与表情，需补镜头轨道；PMX 路径另查兼容 |
| 活动与镜头 | `apps/macos/Sources/GMGNRadio/VisualEngine/StageAvatarMotionPlayback.swift`、`StageCameraCoordinator.swift` | 演出时间、镜头占用与手动接管恢复 |
| 音乐与居民 | `apps/macos/Sources/GMGNRadio/Agent/ResidentMusicToolBridge.swift`、`MusicLibraryAgentService.swift`、`App/GMGNRadioApp.swift` | 复用正式音乐准备与活动执行结果，不新建独立聊天播放器 |
| 空间包 | `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldManifest.swift`、`WorldPackageValidator.swift` | 独立物件包及能力引用，不误将碰撞 GLB 解码当作完整材质渲染 |
| 创作加工 | `tools/blender/publish_gmgn_world.py`、`validate_gmgn_world.py` | 物件尺度、资源预算、碰撞与贴图检查 |
| 生成与分发 | `tools/motion/`、`apps/macos/Packages/MotionDistribution/` | 借鉴任务和分发经验，图转物件作为独立类型，避免强塞进动作接口 |

## 四、实施顺序与小任务

先完成正在进行的居民真实选歌、播放与中断验收，再开始演出样片。图片转物件可做独立受控样品验证，不阻塞当前版本。所有任务按“新增失败测试 → 最小实现 → 重跑 → 单独提交”执行；已有行为先测通过，不人为制造失败。编译与重型任务串行、低优先级运行，不让用户电脑执行素材批量推理。

### 任务 1：演出包与导入检查

拟新增 `apps/macos/Sources/GMGNRadio/Presence/PerformancePackage.swift`、`tools/test-performance-package.swift`，复用 `MotionPackageStore.swift` 的安装与校验思路。

1. 写最小清单测试：稳定编号、版本、动作引用、音频引用、可选镜头、起始偏移、所需空间、来源许可。
2. 运行 `/usr/bin/nice -n 15 swift tools/test-performance-package.swift`，记录缺失实现导致的失败。
3. 实现本地包导入，验证缺失资源、越界路径、重复版本、损坏资源和不支持格式；无镜头允许自由观察，缺歌曲不得伪装成完整演出。
4. 重跑上述入口，预期全部通过，再单独提交。

最小清单例子（格式草案）：

```json
{"schemaVersion":1,"id":"sample.performance","motion":"dance.vmd","audio":"song.wav","camera":"camera.vmd","startOffsetSeconds":0,"rights":"rights.json"}
```

引用合法音乐服务时另存曲目身份与授权条件，不把账号、临时签名地址或可下载歌曲默认装入公开包。

### 任务 2：统一时间与 VMD 镜头

拟新增 `Presence/PerformanceTimeline.swift`、`MMD/VMDCameraTrack.swift`、`tools/test-performance-timeline.swift`；修改上述 VMD 加载与镜头协调入口。`Presence/`、`MMD/` 均相对 `apps/macos/Sources/GMGNRadio/`。

1. 写测试覆盖开始、暂停、恢复、拖动进度、加载失败、结束和旧回调；音乐、身体与镜头读取同一演出时间。
2. 写已知 VMD 镜头样本测试，覆盖位置、目标、旋转、视野角和插值；拒绝仅有预览图的“镜头支持”。
3. 运行 `/usr/bin/nice -n 15 swift tools/test-performance-timeline.swift`，确认失败后实现最小同步与轨道采样。测试脚本内部编译采用 `-j1`。
4. 用房间原点、角色站位与已校准尺度变换镜头；用户移动视角时释放运镜控制，结束后不覆盖用户的新视角。不可用镜头退回可观察视角，并显示实际状态。
5. 重跑测试并提交。设备验收记录音画偏移、暂停恢复偏移和运镜穿墙情况，不能用单元测试代替画面。

### 任务 3：让居民调用演出，并验证换角色

拟新增 `Agent/ResidentPerformanceToolBridge.swift`、`tools/test-resident-performance-tools.swift`；复用现有世界活动、租约和停止入口，修改 `App/GMGNRadioApp.swift` 仅做接线。

1. 先写发现演出、查询要求、开始、读取进度、停止的协议测试，工具名称在实施时对照已有清单确定。
2. 运行 `/usr/bin/nice -n 15 swift tools/test-resident-performance-tools.swift`，记录缺口。
3. 实现演出活动：空间足够才开始，缺少资源回报可处理状态；不在主循环写固定“跳舞问答”，模型可继续查询或换活动。
4. 中断、换空间、手动换歌和换角色后，旧演出不能继续抢声音、身体或镜头；TTS 与歌曲按现有声音策略协调。
5. 重跑并提交；先验收一套授权演出与一个 VRM，再换第二个 VRM，最后独立验收当前 PMX。记录滑步、穿衣、比例和表情差异，不以 VRM 通过替代 PMX。

### 任务 4：图片转物件服务小样

进度修订：已有实际实现为 `tools/assets/prop_service.py`、`workflow_adapter.py`、`glb_inspect.py`、`example_client.py` 及同目录测试。后续复用这些入口，不按下方旧拟定名称另造一套服务。下一步转向许愿机用户入口、照片转换、真实尺度采用与空间融合；分件研究不加入首版生成必经步骤。

拟新增 `tools/assets/comfy_asset_job.py`、`tools/assets/tests/test_comfy_asset_job.py`、`docs/plans/evidence/2026-09-06-image-to-prop.md`。只有确定目标后端后才增加运行配置；公开工作流不能要求客户端执行任意节点或安装代码。

1. 先用替代服务测试提交、状态查询、取消、超时、重复请求和迟到结果；返回实际任务编号及产物，不使用“任务完成”替代产物校验。
2. 运行 `/usr/bin/nice -n 15 python3 -m unittest discover -s tools/assets/tests -p 'test_comfy_asset_job.py'`，确认失败。
3. 固定可信 Comfy 版本、工作流哈希、模型权重版本和输出格式；将编辑器图转换为目标环境可执行的 API 图，核验全部节点可用。
4. 实现最小服务适配并重跑测试。凭据留在服务配置或用户自己的安全配置，不写进素材、日志和分享包；不得访问钥匙串做迁移。
5. 在明确生成预算和运行目标后，用有权使用的单物体图片测试花盆、杯子、椅子、咖啡机外壳、剑形装饰五类。先跑一件，再决定其余样品；不自动同时运行两个模型或无限重试。
6. 记录输入与模型版本、排队／推理／加工耗时、显存、失败、重试、实际费用和产物质量；测试通过与远端实际运行分开记录，独立提交适配代码。

### 任务 5：轻量物件包与交互融合

拟新增 `tools/blender/prepare_gmgn_prop.py`、`tools/blender/tests/test_prepare_gmgn_prop.py`、`apps/macos/Sources/GMGNRadio/Presence/PropPackageStore.swift`、`tools/test-prop-package.swift`。复用 `WorldManifest.swift`、`WorldPackageValidator.swift`、`VisualEngine/Metal/MarbleSpatialView.swift` 与当前交互框架。

1. 先写原点、朝向、尺寸、资源缺失、网格预算、贴图与碰撞独立性的测试；预览产物先不进入正式世界。
2. 运行 `/usr/bin/nice -n 15 python3 -m unittest discover -s tools/blender/tests -p 'test_prepare_gmgn_prop.py'` 和 `/usr/bin/nice -n 15 swift tools/test-prop-package.swift`，分别记录预期失败，串行执行。
3. 实现加工：保留生成原稿，另输出轻量 GLB、包清单和简化碰撞。首轮尝试每个普通道具 5,000—30,000 三角形、1K／2K 贴图；此为实验档位，按实机结果调整，不作为已验证最低配置。
4. 用已知尺寸或创作者填写值校准米制尺度；单图不能保证背面、内部和真实尺寸。以实际导出 GLB 的统计验证减面效果，不能只读模板参数。
5. 通用物件默认可摆放；咖啡机、点唱机、椅子只绑定受支持的能力与操作锚点。需要开门、抽屉或握持时，补独立部件、枢轴和动作，不能假定整块生成网格已具备这些结构。
6. 重跑并提交；验收“图片 → 生成 → 预览 → 校准 → 放进生活舱 → 居民发现 → 到达操作点 → 正式结果 → 保存重进”。移动物件后碰撞和交互点一起变化，删除使用中的物件会中止活动。

## 五、素材服务与市场分阶段开放

先提供素材生成、加工和个人库，再开放分享；有采用率和成本数据后才提供收费。服务费用与空间租金、访客模型用量分别显示，沿用创作者承担制作成本、访客自带燃料的方向。

生成任务可抽象为 `queued → running → processing → ready / failed / cancelled`；`ready` 只表示候选产物就绪，发布或装入世界需另一个明确操作。取消若未停止远端计算，要显示实际情况。扣费重试使用同一请求身份核对，费用不明时禁止盲目重新提交。公开原图和素材均需创作者确认，私有输入默认不发布。

两档许可继续沿用个人使用与商业空间使用；另列改作、录像分享、源文件交付、再分发和再售卖。代码、生成模型及依赖权重、输入图片、角色 IP、动作、歌曲、镜头、舞台分别核对；不能把其中一种许可扩张到全部内容。角色装饰还需绑定部位、比例、穿模与角色自身许可检查。

后续经营条目：授权角色包、动作包、演出包、装饰与家具包、空间模板、生成加工额度；IP 联动、品牌物件与游戏体验按真实合作项目洽谈。开放市场前补订单、授权交付、失败退款、创作者分成与下架流程，暂不开发大型交易系统。

## 六、放行条件与暂缓项目

- 演出：一套内容能换两个 VRM；PMX 单独记录；音乐、动作与镜头同步，用户可中断，结束恢复生活活动。
- 物件：至少一个生成物件进入真实生活舱并可被居民使用；另一个只作装饰也必须如实标注。生成预览好看不等于交互验收通过。
- 性能：记录目标机器上同房间添加前后的帧率、内存、载入耗时与包体积；不运行本机重型推理来换取低下载成本。
- 服务：有实际成功与失败任务、采用率、单件采用成本及可解释的用量；仅有工作流和接口不能宣布商业模式成立。
- 暂缓：任意歌曲自动编舞、自动给任意生成角色绑定完整骨骼、全自动拆可动部件、多角色舞台编排、搬入原游戏完整玩法和大规模 IP 市场。

用户已授权并行实施 DGX 私有素材服务和首件生成试验；生成产物、空间导入与居民使用分别以证据验收。其他项目继续服从居民循环的验收顺序，设备结果、用量与许可补入证据文档。智能绑定、动作生成及后续强化学习的现成能力与采用门槛见[外部模型复用跟踪](2026-09-06-world-model-reuse-watchlist.md)。
