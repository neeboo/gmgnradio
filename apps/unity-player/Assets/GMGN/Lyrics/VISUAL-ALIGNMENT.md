# 歌词视觉对照：禁止把几何候选算作原主题验收

权威来源：`StageOverlayView.swift` 的各 `Stage*LyricsFrame`、`StageFlowingLyricGlyph`；`StagePresentationModel.swift` 的 `StageLyricTypography`、`StageLyricTokenization`、`StageLyricFlowSceneModel`；`FoliaSceneDetailModels.swift`。

普通歌词使用连续文字。点阵为独立视觉效果，不应把所有歌词主题转成点字。GPU SDF 路径已恢复连续字体；GPU上传只发生在歌词、行、主题或尺寸边界，帧内动画由Compute执行。

|主题|原始构图/关键参数|已移植源码|尚未通过的精确项|
|---|---|---|---|
|流光|居中VStack，22间隔；当前字体18..112；前文左/后文右、15..24、alpha.18/.28；翻译max16,size*.22/alpha.66|max字号公式、位置/比例/alpha；真实单位词级时间、阶段颜色/缩放/lift、FNV稳定motion；连续GPU字体|系统rounded字体/字重、逐词组整体旋转中心、上下文blur1.5/.9、动态glow半径10..18和黑shadow、长翻译2行、节目侧栏-150偏移|
|莫奈|左侧渐变竖轨宽3+high*2，高min520,h*.7；上下文±2，spacing14；当前可用宽.58w；翻译max15,size*.2/alpha.54|五行左对齐、字号公式、alpha、实际字高避免重叠；词级原阶段动画|竖轨原三段渐变/真实width高频响应、上下文blurabs(offset)*.34、字体字重、2行换行、当前glow22、节目侧栏-96|
|群唱|前文右/后文左；上下间18；当前黑.32填充、不规则8/30圆角、accent.34或chorus secondary.46细1px；上下胶囊fill.045/stroke.08细.8px|真实字宽/高度、字号.5w、翻译max14,size*.19/alpha.56、原alpha/圆角、Retina-aware逻辑线宽；声部stableHash11/23/37及冲突规则、chorus ensemble；4声部GPU矢量图标、34/27圆圈及当前对角渐变|跨平台对应图标形状不等同SF Symbols；字体/字重、渐变阴影glow、节目侧栏-140、长文2行；须真实画面复验蓝边是否与原细描边一致|
|心象|前后row±92/96，active38/context24，前后scale.82/.9、alpha.3/.46，3D Y±12|基础构图、字体、alpha/GPU透视|gradient/tracking、blur2.4/1.5、原透视轴与比例、活动beatLift|
|云阶|Partita FNV列/阶梯/散布/chorus扇形，每displayUnit位置，不是每字母位置|FNV/布局参数及动画|当前物理glyph布局仍需改按displayUnit整体布局、原3D轴、translation/字体/particle响应|
|浮名|Fume实际字符数累计Y及交错X、cameraTarget；active居中.62w|实际block Y/X、上下文场、字号/alpha|原block宽度/换行/视距blur与背景圆角、镜头过渡、tracking|
|倾诉|按1..4段逐时显现、某段italic/light/secondary gradient、-7°旋转|真实分段数量/时间与稳定选段|原字重italic、三色gradient、真实3D perspective、段落token整体布局|
|回环|逐displayUnit弧角(-.79..+.79)，radiusmin430,.38w、Y=-cos*92、Y轴perspective|基本弧和时钟漂浮、字号26..72|整体displayUnit投影、原视角轴、翻译/黑shadow及音频响应|
|时计|±4行、20.5°步进、scale/opacity、半轮渐变细1.2+high*1.4与宽弧、中心glow|9行角度/scale/alpha、半轮与字号|原双渐变弧/中心glow、轮廓高频响应、原文字leading锚点投影|
|镜台|三个黑.26背景面板、主panel28圆角、前后Y视角34/-38、180原粒子|基本三行/投影、180 GPU粒子|原panel及描边/翻译布局、粒子blur/深度/glow、原透视/尺寸|
|折章|最大4行/5秒段落分组，.72秒smoothstep；前组±90°Z/±7°Y退场，当前从.68h进场|分组/方向/.72秒GPU折转、scale/alpha|原Y透视、上下文组真实多行字体尺寸与行距、侧栏偏移、active translation/glow|

自动模式由真实 `StageLyricModeDirector` 选择，不能用随机或固定GPU主题代替。

Retina：统一使用 `Screen.width / panelSettings.scale` 的逻辑视口；shader转换NDC后由真实target rasterize。细描边的coverage使用`fwidth(distance)`，不把backing像素数当逻辑像素宽度。需在窗口/全屏实际截图及render target尺寸读回验证，不能从缩略图推断倍率。

验收需同一真实歌曲、时间点和同一主题与原版对照，分别记录当前/翻译/上下文是否单份、基线/字宽、颜色透明度、真实帧率、切歌及风格切换。上表中的源码移植不能替代视觉验收。
