# GPU 点阵接入与验收边界

此前 AudioSculpture 的 48 点圆环只是一段接入探针，未迁移原播放器，不能作为完整点阵。最新候选已经替换为原 StageRenderer 实际使用的 albumCanvas144²（20736点）及 ambientField1800（1170 dust/324 shard/306 floor），共22536点；种子按原SplitMix64及数值生成一次，拓扑、音频形变、真实封面采样、色彩传播、环境浮动由GPU更新。原 djTotem 仅留在Swift几何工具，StageRenderer未使用，不能把它误当当前播放器主体。

模式映射：flowingCanvas流幕、orbitalShell星球、openRibbon光带、vinylRecord封面浅浮雕、galaxyField六层星河、tunnel滚筒、void留白；automatic消费宿主真实timeline.weights/composition，不在Unity伪造轮播。原Stage.metal的折幕/双螺旋/bloom复合形通过composition0..1连续混合，三个手动变体使用composition2。所有模式共用GPU buffer，切模式不逐点上传。

当前仍是源码候选：原多层bloom、palette主题混色、视频porous/compositing/背景渐变、完整摄像机轨道与环境shape fragment的细节尚未逐像素移植；空间world可见性由WorldBridge控制，不从点阵模块擅自改。不能把22536点或编译通过当作8模式视觉/帧率全部验收。

集成接口：AudioSculpture.SetVisual(choice,intensity,particleSize,automaticWeights,automaticComposition)，SetRhythm真实beat/onset/amplitude/均值和8波形，SetArtwork真实Texture。PointCloudArtworkLoader.Load(artworkURL)异步读取真实library封面，URL变化才请求；失败/空元数据不使用假图。Intensity0..1，particleSize.6..1.6，按原ScreenHeight/1080缩放（.72..2）并在pixel billboard绘制中应用。默认场景中心与Camera看向0，移除旧小环左偏镜头。

独立构建检查入口StagePointsValidation.Validate：48-byte stride、22536精确区域数量、确定性种子、所有手动模式ID与Compute/Draw shader错误。主代理还须真实静音逐模式截图、封面/音频关联、切模式/切歌/窗口全屏/空间恢复及CPU/GPU帧时间验收。

## 接口

- 将 `GpuPointCloud` 添加到点阵对象，调用 `Initialize()` 并检查返回值及 `Status`。
- 在歌词或布局 revision 变化时生成 `GpuPointSeed[]` 并调用 `SetPoints()`。position 为局部坐标及 billboard 半径，color 为 RGBA；timing 为高亮开始秒、结束秒、音频频段 0/1/2、动画相位。
- 不高亮的点使用开始时间大于结束时间。歌词字形排版及采样仍需调用方在文本变化时完成，不能放进逐帧循环。
- 每帧仅调用 `SetPlayback(seconds, playing, bass, vocal, treble)`。`LateUpdate()` 调度计算和单批程序化三角形绘制，不读取 GPU 结果，不上传逐点数据。
- `localBounds` 必须包住整个点阵及动画位移。点的位置随对象变换，半径以世界单位定义。
- 空内容调用 `SetPoints(Array.Empty<GpuPointSeed>())`；销毁组件时释放 GPU 资源。
- 不支持 Compute Shader、绘制 Shader 或资源缺失时明确失败，没有 CPU 点阵替代路径。

## 主代理真实验证

1. 使用 Unity 6000.6 的 Metal Release 构建，检查 Compute 和 URP 绘制 Shader 的编译日志。
2. 逐级上传 1 千、1 万、10 万点；每个级别维持 60fps，记录 Unity Profiler 的主线程、渲染线程、GPU 时长和内存。目标每帧总预算 16.67ms；性能数据未测前不得声称达标。
3. Frame Debugger/RenderDoc 或 Xcode GPU capture 确认 UpdatePoints Dispatch 和一批程序化绘制；确认每帧没有 GraphicsBuffer.SetData/GetData、GameObject/Transform 逐点操作。
4. 歌词换行/切歌只上传新 revision；音频与时钟变化检查颜色、波动及暂停。全屏、窗口切换和双 GPU 点阵对象测试独立 buffer/material，场景切换确认释放。
5. 各原有风格逐项移植自己的 Compute 行为并对照原画面；本模块的单一波动效果不能代替全部风格验收。

API 依据：Unity 官方 Graphics.RenderPrimitives 和 URP Compute Shader recipe。
https://docs.unity.com/en-us/engine/6000.5/script-reference/unityengine/graphics/renderprimitives
https://learn.unity.com/tutorial/urp-recipe-compute-shaders?publish=true
