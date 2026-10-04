# GPU 歌词点阵迁移状态

`GpuLyricsView` 在歌词revision、当前行或viewport改变时按字形排版；Compute每字形仅更新一个描述，`GpuLyricsGlyphDraw`每字形一个procedural quad，fragment直接连续采样TextCore SDF atlas。正常字幕不再强行采样成24×24点阵。点阵及粒子仍使用各自GPU绘制，CPU没有逐点更新或字形像素扫描。GPU绘制透明叠加，不切相机背景、不覆盖背景为黑色。

入口：`SetLyrics(sessionId, revision, LyricPointLine[], mode)`，`SetPlayback(seconds,bass,vocal,treble)`，`SetVisible(bool)`。所有行按startsAt排序。换session或revision首先释放旧点，避免换歌旧歌词残留；空内容清空。句/词秒数使用播放器真实时钟。

11种样式已有独立几何布局及Compute动画候选，尚未与原Swift画面对照，不代表完整视觉对齐。`SetTheme(LyricVisualTheme)`消费真实primary/accent/secondary/wordColors。逐字时间按Unicode组合字符分配，UTF16代理对不再拆开。

2026-10-05 对照修复（仍需下一次真实画面验收）：旧Swift歌词均使用连续字体，上一版全部点字不符合视觉语义，现恢复GPU SDF字体。流光按 `StageLyricTypography` 的可见字数/18..112字号公式、上下文15..24与0.18/0.28透明度、翻译max(16,size*.22)/0.66、22间隔和前左/后右对齐。莫奈字体按0.58宽度计算，上下文17..28、行间14、翻译max(15,size*.2)/0.54、左对齐；以实际字高安排行距避免与翻译重叠。TryAddCharacters成功时out参数仍可能返回全串，不再错误记录缺字。

v33运行反馈修复候选：群唱原Swift确有三气泡，但上/下为轻色Capsule（填充0.045、描边0.08/0.8px），当前为黑0.32填充、不规则8/30圆角、描边0.34/1px或合唱0.46。现按实测字宽/字号算气泡、以当前气泡高度+18定位上下文、翻译max(14,size*.19)/0.56左对齐，shader连续SDF描边替代原粗点框。34/27声部圆圈已接，但声部图标及渐变尚未对齐。重复翻译还需PlayerScreen隐藏旧UI Toolkit translation标签（属整合模块，不能仅修改此shader解决）。

完整映射来自StagePresentationModel/StageOverlayView：

|正式mode|原样式|依赖原模型|当前覆盖|
|---|---|---|---|
|automatic|自动选主题|StageLyricModeDirector|宿主真实选择后送resolved mode|
|luminous|流光|Flow/字词时间/Theme|GPU点阵候选，待验收|
|mindscape|心象|SceneLine深度/opacity/blur|前后行缩放旋转/alpha；透视与blur待对齐|
|cloud_steps|云阶|Partita glyph placements|列/阶梯/散布/合唱扇形；原stableUnit细节待对齐|
|article|浮名|Fume blocks/cameraTarget|多行背景文字场；原精确block参数待对齐|
|chorus_chat|群唱|Cappella voices/bubbles|前后行气泡轮廓；头像/声部及圆角待对齐|
|confession|倾诉|Tilt segments/revealAt|分段逐时显现/倾斜；字体italic/透视待对齐|
|claddagh|回环|glyph弧线/3D投影|逐字弧线/漂浮；真实3D透视待对齐|
|monet_poster|莫奈|Monet rail entries/status|五行左对齐/竖轨/翻译；blur/glow待对齐|
|pendulum|时计|Pendolo wheel/ring|9行半轮/旋转/alpha/轮廓；glow待对齐|
|diorama|镜台|panels/perspective/180particle field|前后行旋转/180 GPU粒子；面板/真实透视待对齐|
|folding_verse|折章|Fold历史/当前组、方向、进度|4行/5秒段落分组与0.72秒GPU折转；Y透视待对齐|

未知mode明确返回未迁移状态，不偷偷显示流光。动态字体各atlas页复制到GPU Texture2DArray，并以字形页号采样；中文/日文实测、原布局换行及表中未覆盖视觉均需继续完成。共享模式的shader动画没有每帧CPU点循环；仅歌词行/布局变化时生成字形描述。

验收必须：Unity6000.6 Metal真实编译+画面；CJK歌词可读；换歌立即清空；暂停时钟一致；全屏/window固定逻辑字号；GPU Capture确认为Compute+单批draw；性能按主代理当前75fps验收。未构建/未GPU Capture时不得声称通过。

构建时可调用 `GMGN.UnityPlayer.Editor.GpuLyricsValidation.Validate()` 检查seed stride、资源和当前shader编译错误。它不能证明Metal draw已经执行。

运行对照顺序：真实中文/日文歌曲分别切换11模式→窗口/全屏→跳到段落边界→切歌→暂停→恢复。记录 `Status`、`PointCapacity`、Profiler CPU main/GPU时间、帧时间p95；目标75fps预算约13.33ms。CPU Profiler内 `LateUpdate` 应仅参数上传/Dispatch/Draw，布局和atlas复制只应出现在行、歌曲、主题或viewport边界。群唱/镜台的面板及上述未覆盖视觉不计已通过。
