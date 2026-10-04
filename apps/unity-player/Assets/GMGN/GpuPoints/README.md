# GPU 点阵接入与验收边界

此目录提供通用 GPU 更新/绘制模块。AudioSculpture 已接入 48 个环形点的 GPU 更新及批量绘制，移除了旧的逐柱 GameObject/Transform 更新。仍不表示原有歌词风格已迁移。

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
