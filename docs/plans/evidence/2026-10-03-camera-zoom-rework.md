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
