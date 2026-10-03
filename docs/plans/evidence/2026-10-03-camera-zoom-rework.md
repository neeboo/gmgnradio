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

### 手动渲染节拍的恢复延迟（接续中）

源码确认MTKView已isPaused，fullStage/liveCam共用MainActor Task.sleep手动loop，不能归因于MTKView默认定时器。新增120样本draw开始间隔/计划sleep恢复延迟/draw耗时，以及12个>50ms间隔的uptime和恢复后的RunLoop mode，status `renderScheduling`可读。诊断版构建 `/tmp/gmgn-parent-render-schedule-build.log` exit0，生产提取节拍测试exit0。

真实PID83891，实际HLS解码>=20且GPU fragments>0后，3840×2160同80次滚轮，180快照及指定PID声音开停 `/tmp/gmgn-parent-render-schedule-live.log` exit0。draw开始间隔窗口最大297.310ms/P95峰值291.149ms，sleep恢复超时最大280.643ms/P95峰值274.482ms；draw本身最大10.114ms/P95峰值1.333ms。最近异常267–293ms间隔对应250–276ms恢复延迟，恢复时mode default；证实延迟发生在渲染任务恢复，未证实停顿期间的RunLoop mode。Metal呈现最大316.686ms。音频播放RMS0.134761/751buffers，正式stop后RMS0/752buffers，均指定PID/globalTap=false。

对照修改仅将手动节拍改主RunLoop .common单次Timer，保留pacer、质量动态、可见性、ownership、取消及无追赶burst；独立pacer/generation避免draw同步触发start/stop/restart产生双loop。诊断kind=timer-common，延迟字段改为waitResumeOvershoot，不虚称sleep。严格Swift6生产提取测试覆盖tracking mode、过载取消、重入、停启、质量降档exit0。首次完整构建 `/tmp/gmgn-parent-render-common-build.log` exit65，Timer对象跨assumeIsolated的数据竞态诊断；已改callback只带generation/deadline与MainActor self，不传Timer、不加 blanket concurrency绕过。第二轮完整构建和真实对照待完成。

common Timer第二轮完整构建 `/tmp/gmgn-parent-render-common-build2.log` exit0，但真实PID84434同80次滚轮仍约270–290ms调用间隔、250–270ms唤醒延迟、Metal呈现最大316.686ms，`/tmp/gmgn-parent-render-common-live.log`。对照无改善，Timer行为已撤回，恢复原Task+pacer，保留有界诊断并统一标为schedulerKind=task-sleep/waitResumeOvershoot。恢复后严格Swift6提取测试及完整构建 `/tmp/gmgn-parent-render-schedule-restored-build.log` exit0。失败实验不作为修复提交。

新同步滚轮12秒sample `/tmp/gmgn-scroll-blocked-sample.txt`，PID85057，CUA实际50次滚轮：主线程7482样本中screen.tick→overlay.update→updateOcclusion→WorldScreenOcclusion.mask为1976（约26.4%），内部射线firstHit；draw614、SwiftUI layout185、AX约29、currentDrawable18，没有copyFrameTexture热栈。可确认显著主线程CPU工作，尚不能精确对应某一次270ms异常。

实际发现nativeLink屏仍进入遗留网页24×14射线掩码，虽然原生视频已经Metal深度遮挡。最小修复store传nativeSceneScreenIDs，overlay跳过这些屏幕投影/CPU遮挡、隐藏遗留层、清旧遮挡stats/签名/节流缓存；仅原生屏时不建CPU occluder index，网页屏保持原质量与遮挡逻辑。hide只暂停WKWebView，不接触nativeplayer。当前构建 `/tmp/gmgn-parent-native-mask-bypass-build.log`，真实同条件缩放及声音对照待复验。

### 原生遮挡绕行的实际复验结果

完整构建 `/tmp/gmgn-parent-native-mask-window-build.log` exit0，原生/网页实际内容路由与负对照检查 exit0。真实隔离PID89145，稳定全屏后80次实际滚轮、180快照，80有效/0缺失。输入P95 13.435ms/最大16.322ms；输入后59个快照渲染调用间隔滚动最大43.752ms，Metal呈现滚动最大50.003ms/P95峰值33.335ms。此前约300ms停顿未在该窗口复现。宽标记区间仍有51.699ms调用间隔，不宣称恒定60fps、物理显示或输入到光子测量。日志 `/tmp/gmgn-parent-native-mask-window-live.log`。

音频保持拒收：首轮PID87775真实开停RMS0.106416→0；后续PID89145及同源PID89319指定PID有751buffer但RMS0，门禁失败。后者视频解码继续增长、rate1/volume1/未静音/hasAudio=true，不能以这些状态覆盖声音失败。替换monstercat来源未开播并超时，亦不算通过。当前声音原因未判定，最新完整流程尚待复验。

### 长帧分段定位与最小修复（接续中）

新增有界诊断：最近12个超过33ms的draw，记录uptime/帧号/各阶段耗时；最近120个Metal drawable呈现间隔，不标为物理显示或输入到光子延迟。诊断类直接提取的21项Swift检查exit0，完整App `/tmp/gmgn-parent-zoom-phases-build.log` exit0。真实HLS解码>=20且GPU fragments>0后，全屏80次CUA往返，300快照 `/tmp/gmgn-parent-zoom-phases-live.log` exit0：输入P95=16.848ms，捕获72.936/73.024ms两帧，其中物件视频阶段71.718/71.913ms；首批初始化还有96.541ms人物/jukebox长帧。Metal滚动呈现间隔P95约33.335ms，不能因显式跳帧0宣称60fps。

再细分生成道具/摆放道具/格子/取视频帧/视频编码，构建 `/tmp/gmgn-parent-zoom-subphases-build.log` exit0；PID78395真实同条件80次滚轮，捕获73.960ms长帧，其中 `videoFrameAcquisition` 72.670ms，即 `registry.frames()` 取视频帧。同步Time Profiler仅目标PID的聚合样本也显示draw中的NativeLinkPlayer.copyFrameTexture/AVPlayerItemVideoOutput.copyPixelBuffer；不是visibility completion主线程等待。raw trace含继承环境信息，禁止提交/分享，仅白名单聚合函数与数字。

最小修复仅把provider改为读取已发布不可变纹理，AVPlayer/CoreVideo取帧由现有30Hz帧泵负责；stop/generation/资源保活/音频不变。帧泵仍MainActor，不能声称所有输入阻塞已解除。修后构建、同条件真实画面及按PID声音开停对照待完成。

修后完整构建 `/tmp/gmgn-parent-video-readonly-build.log` exit0；真实PID78641，原始Twitch页正式起播，实际decoded>=20且GPU fragments>0，3840×2160同80次up/down300，300状态快照及音频开停完成exit0，日志 `/tmp/gmgn-parent-video-readonly-live.log`。80有效/0非法，输入P95=14.485ms/最大17.704ms；取帧阶段不再出现>33ms draw，输入后窗口CPU最大1.537ms。仅保留启动人物/jukebox104.800ms长帧。音频只绑定PID78641/globalTap=false：播放751buffers/384512frames/RMS0.093667/peak0.553750；正式stop后751buffers/384512frames/RMS0/peak0。测试App正常退出，未安装更新已装App。

重要未通过项：修前与修后真实连续滚轮期间，Metal呈现间隔窗口最大分别316.686ms/333.353ms，窗口P95峰值均300.018ms；静止末窗P95约33.335ms。不能只取末窗掩盖滚轮过程停画，也不能由移除draw取帧推断整体体验通过。下一步核查MTKView/RunLoop滚轮期间调度与主线程帧泵，针对呈现停顿实际修复复验；没有物理显示测量，不宣称以上是输入到光子的精确延迟。性能技能要求按实测范围保留此拒收项。

第一段 `/tmp/gmgn-parent-zoom-stress-live.log` 240个快照没有收到滚轮输入，只记全屏静态基线，不能计缩放通过。随后重新启动同隔离根、同构建，PID74741，正式play_screen返回ok；CUA截图确认3840×2160全屏，在实际场景坐标连续60次up/down120，约20.7秒。日志 `/tmp/gmgn-parent-zoom-stress2-live.log`。

60输入/60有效/0非法：事件到主线程处理P50=7.391ms、P95=19.958ms、最大20.260ms。输入后的滚动窗口出现CPU编码最大69.321ms；不能因跳帧计数0判为流畅。该长帧没有同步栈证据，暂不归因于排序、PMX或视频。仍需捕获最终显示节奏与长帧对应调用栈，性能问题保持开放。本轮不重复生成，不替换已装App；正式播放返回ok也不单独作为本轮电视解码/声音新验收证据。

追加40次up/down300，约13.4秒；运行最终exit0，360个快照、总计100输入/100有效/0非法。最终分发P50=6.678ms/P95=18.945ms/最大20.260ms；最后120帧窗口CPU P95=1.468ms、GPU P95=15.389ms、跳帧0。末窗没有包含此前69.321ms长帧，不能用末窗覆盖该异常。补充5秒CPU采样完成exit0，仅静态补充，不是异常当帧栈。App已由隔离host正常退出，没有遗留本轮测试/构建进程。
