# 播放屏幕附近缩放卡顿返工

用户反馈：对着屏幕缩放镜头仍很卡。

主代理与只读审查确认两处主线程等待：NativeLinkPlayer 新视频帧 blit 的 waitUntilCompleted，以及 MarbleSpatialView 的无限 inFlightSemaphore 等待。滚轮路径本身只更新镜头，未发现缩放专门触发视频纹理或 PMX 重建。以上是明确阻塞路径，尚不能据此量化真实缩放改善。

修改：

- 视频 blit 改异步完成后发布；已发布帧不可变，最多一个拷贝在途，资源容器保活 pixel buffer/包装/source/destination。stop 提升 generation，旧完成结果不得发布。
- renderer 两帧在途许可用非阻塞获取，没有许可直接跳过本帧，保留主线程处理输入。
- 未修改缩放系数、画质或碰撞规则；未安装或重启已装 App。

验证：

- 初次两轮完整构建暴露跨 actor MTLTexture 传递错误，未把局部检查当通过；改用仅限不可变 GPU 帧资源的 Sendable 所有权容器后修复。
- 当前完整 App 构建 `/tmp/gmgn-parent-zoom-fix-build3.log` exit0。
- 专属 Swift6 优化编译 `/tmp/gmgn-native-frame-copy-emit.log` exit0；离线生产探针11项通过，不能替代真实 App。
- 新构建真实全新流程已启动：根 `/tmp/gmgn-e2e-20261003-zoom-final`，日志 `/tmp/gmgn-parent-full-zoom-final.log`，session60618。包含真实生成与按PID HLS声音开停对照；尚未结束。
- 缩放实际输入延迟、帧耗时与视觉复验待完成；当前不得报告卡顿已解决或完整验收通过。

## 全新业务结果与后续性能门槛

`/tmp/gmgn-parent-full-zoom-final.log` 最终 exit0：160pass/0fail/0blocked。任务 BADB4C80-51A5-402C-8528-217E3226663D 是本轮真实新生成，已完成正式领取入库、摆放/手持/放回、实际人物动作、HLS GPU画面与指定PID输出开停对照、通知已读、重启物件/屏幕恢复及真实chat。该结果证明业务全链，不证明缩放帧率。

主代理 CUA 对实际隔离 App 在场景位置滚轮up120/down120，截图确认镜头发生变化；没有测得输入延迟或FPS，不计性能通过。实际5秒CPU采样 `/tmp/gmgn-zoom-current-sample.txt`：主线程3209样本中2091事件等待、场景draw246，PMX绘制144/接地53；后台SPZ sortLoop2881样本中Swift排序2598。镜头静止仍重复全量排序来自依赖updateCameraPose每render无条件needsSort，排序请求布尔合并。当前无法从CPU采样判断GPU填充率或FPS。

后续只在调用侧添加有界短窗排序计数/耗时、CPU/GPU帧耗时/跳帧统计，以真实缩放对比验证；不修改可再生依赖checkout作为交付，不降低接地判据或画质掩盖卡顿。

## 短窗真实测量

调用侧已加入120帧有界CPU/GPU窗口、跳帧计数和最近2秒排序耗时，测试status的renderPerformance可读；SplatRenderer的accessTimeout/sortTimeout显式设0，忙时跳帧，不改排序资源保留逻辑。完整构建 `/tmp/gmgn-parent-zoom-metrics-build.log` exit0。

同一真实隔离App（PID71623、50万splats）从正式play_screen起播并实际解码20帧后，采180次status，再通过正式stop_screen关闭电视。CUA在播放中实际滚轮up500两次，截图确认镜头变化。运行 `/tmp/gmgn-parent-zoom-metrics-live.log` exit0。分段如下，P95数值是多个重叠120帧窗口P95的中位数，不能当作全部帧的整体P95或FPS：

| 段 | status快照 | CPU窗口P95中位(ms) | CPU单帧最大(ms) | GPU窗口P95中位(ms) | 窗口最大跳帧数 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 开播初始，sample5–30 | 26 | 1.297 | 10.571 | 8.341 | 0 |
| 混合缩放播放，sample40–115 | 76 | 1.565 | 31.273 | 8.881 | 0 |
| 停止电视，sample130–179 | 50 | 3.061 | 27.250 | 8.517 | 0 |

三段排序窗口约59–60次/2秒，静止仍持续排序；当前不能归因“关闭电视更慢”，镜头轨迹与时间条件不一致，窗口亦重叠。没有输入分发延迟和最终显示延迟证据，暂不关闭用户卡顿反馈。worker正在加入只读滚轮事件到主线程处理的有界延迟诊断，下一轮须真实CUA测试；该指标也不等于显示延迟。已装App完全没有替换或重启。

## 实际滚轮分发延迟

输入诊断接入真实NSEvent.timestamp，最近120有效样本，缺失/非法不填零；不改变镜头行为。完整构建 `/tmp/gmgn-parent-zoom-input-build.log` exit0。同隔离App正式HLS解码后，通过CUA在实际场景滚轮up120一次及8次上下往返；记录120状态快照 `/tmp/gmgn-parent-zoom-input-live.log` exit0。

9个输入/9有效/0非法：OS事件到主线程处理P50=14.063ms，P95/最大=17.311ms。末段120帧窗口CPU P95=9.849ms/最大22.108ms，GPU P95=8.648ms/最大11.340ms，跳帧0；排序57次/2秒。未复现持续主线程阻塞，样本有限、没有修复前同条件输入对照，也未测物理显示延迟或FPS，不能夸大为全部缩放情形通过。

本轮仅独立测试构建，已装App未更新。业务全新160项通过来自此前1dd687d构建；本轮是诊断与零等待渲染路径实际复验，未重复花费生成任务。剩余性能范围为高负载/持续快速缩放、更大场景及最终显示时序；静止重复排序仍占CPU，后续应通过可维护依赖版本处理，不能修改ignored checkout当交付。

## 全屏连续输入复验

### 长帧分段定位与最小修复（接续中）

新增有界诊断：最近12个超过33ms的draw，记录uptime/帧号/各阶段耗时；最近120个Metal drawable呈现间隔，不标为物理显示或输入到光子延迟。诊断类直接提取的21项Swift检查exit0，完整App `/tmp/gmgn-parent-zoom-phases-build.log` exit0。真实HLS解码>=20且GPU fragments>0后，全屏80次CUA往返，300快照 `/tmp/gmgn-parent-zoom-phases-live.log` exit0：输入P95=16.848ms，捕获72.936/73.024ms两帧，其中物件视频阶段71.718/71.913ms；首批初始化还有96.541ms人物/jukebox长帧。Metal滚动呈现间隔P95约33.335ms，不能因显式跳帧0宣称60fps。

再细分生成道具/摆放道具/格子/取视频帧/视频编码，构建 `/tmp/gmgn-parent-zoom-subphases-build.log` exit0；PID78395真实同条件80次滚轮，捕获73.960ms长帧，其中 `videoFrameAcquisition` 72.670ms，即 `registry.frames()` 取视频帧。同步Time Profiler仅目标PID的聚合样本也显示draw中的NativeLinkPlayer.copyFrameTexture/AVPlayerItemVideoOutput.copyPixelBuffer；不是visibility completion主线程等待。raw trace含继承环境信息，禁止提交/分享，仅白名单聚合函数与数字。

最小修复仅把provider改为读取已发布不可变纹理，AVPlayer/CoreVideo取帧由现有30Hz帧泵负责；stop/generation/资源保活/音频不变。帧泵仍MainActor，不能声称所有输入阻塞已解除。修后构建、同条件真实画面及按PID声音开停对照待完成。

修后完整构建 `/tmp/gmgn-parent-video-readonly-build.log` exit0；真实PID78641，原始Twitch页正式起播，实际decoded>=20且GPU fragments>0，3840×2160同80次up/down300，300状态快照及音频开停完成exit0，日志 `/tmp/gmgn-parent-video-readonly-live.log`。80有效/0非法，输入P95=14.485ms/最大17.704ms；取帧阶段不再出现>33ms draw，输入后窗口CPU最大1.537ms。仅保留启动人物/jukebox104.800ms长帧。音频只绑定PID78641/globalTap=false：播放751buffers/384512frames/RMS0.093667/peak0.553750；正式stop后751buffers/384512frames/RMS0/peak0。测试App正常退出，未安装更新已装App。

重要未通过项：修前与修后真实连续滚轮期间，Metal呈现间隔窗口最大分别316.686ms/333.353ms，窗口P95峰值均300.018ms；静止末窗P95约33.335ms。不能只取末窗掩盖滚轮过程停画，也不能由移除draw取帧推断整体体验通过。下一步核查MTKView/RunLoop滚轮期间调度与主线程帧泵，针对呈现停顿实际修复复验；没有物理显示测量，不宣称以上是输入到光子的精确延迟。性能技能要求按实测范围保留此拒收项。

第一段 `/tmp/gmgn-parent-zoom-stress-live.log` 240个快照没有收到滚轮输入，只记全屏静态基线，不能计缩放通过。随后重新启动同隔离根、同构建，PID74741，正式play_screen返回ok；CUA截图确认3840×2160全屏，在实际场景坐标连续60次up/down120，约20.7秒。日志 `/tmp/gmgn-parent-zoom-stress2-live.log`。

60输入/60有效/0非法：事件到主线程处理P50=7.391ms、P95=19.958ms、最大20.260ms。输入后的滚动窗口出现CPU编码最大69.321ms；不能因跳帧计数0判为流畅。该长帧没有同步栈证据，暂不归因于排序、PMX或视频。仍需捕获最终显示节奏与长帧对应调用栈，性能问题保持开放。本轮不重复生成，不替换已装App；正式播放返回ok也不单独作为本轮电视解码/声音新验收证据。

追加40次up/down300，约13.4秒；运行最终exit0，360个快照、总计100输入/100有效/0非法。最终分发P50=6.678ms/P95=18.945ms/最大20.260ms；最后120帧窗口CPU P95=1.468ms、GPU P95=15.389ms、跳帧0。末窗没有包含此前69.321ms长帧，不能用末窗覆盖该异常。补充5秒CPU采样完成exit0，仅静态补充，不是异常当帧栈。App已由隔离host正常退出，没有遗留本轮测试/构建进程。
