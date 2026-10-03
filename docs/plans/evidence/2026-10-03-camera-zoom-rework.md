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
