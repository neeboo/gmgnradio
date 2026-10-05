# 歌词视觉对照：禁止把几何候选算作原主题验收

权威来源：`StageOverlayView.swift` 的各 `Stage*LyricsFrame`、`StageFlowingLyricGlyph`；`StagePresentationModel.swift` 的 `StageLyricTypography`、`StageLyricTokenization`、`StageLyricFlowSceneModel`；`FoliaSceneDetailModels.swift`。

普通歌词使用连续文字。点阵为独立视觉效果，不应把所有歌词主题转成点字。GPU SDF 路径已恢复连续字体；GPU上传只发生在歌词、行、主题或尺寸边界，帧内动画由Compute执行。

本轮布局候选（未构建/未实图验收）：流光/莫奈/群唱的翻译按实际字体advance限制两行，Latin按词/CJK按grapheme换行，超过两行尾部省略；容器高度及后文位置跟随实际行数。流光翻译最大宽720并受窄视口边距约束，莫奈最大宽.62w，群唱翻译受会话容器宽限制。普通翻译字重/逐字tracking及系统字体lineHeight仍有差异，当前行距采用1.2倍字号，需真实同歌截图校准。

Flow/Monet/Chorus正文的displayUnit内部tracking=-font*.018，单位间spacing分别font*.015/.012/.012；每个单位所有字形共享实际quad bounds中心，存于timing.zw，布局leading/trailing平移同步中心。GPU整组旋转/缩放由配套compute/shader消费，不能仅从CPU字段认为动画已验收。新增effects向量后seed为144字节，效果参数按正文/翻译/上下文分别投影，避免上下文blur污染翻译。

构建验证入口GpuLyricsValidation.Validate增加Latin/CJK/emoji/长词/显式换行两行限制与surrogate完整性检查，度量采用可确定的grapheme宽度；实际Noto字体、两行高度、GPU效果仍由真实player验收。原11主题的其余缺项表仍有效；这里的源码候选不代表通过。

多字重候选：Flow/Monet/Chorus正文使用真实Bold FontAsset、翻译Medium，Flow及Monet upcoming上下文Semibold；莫奈passed与群唱上下文按原Medium。量宽、换行及glyph metrics均使用对应FontAsset，各字体页合并1024 Texture2DArray，metadata.z为全局pageoffset。全曲glyph预热按session/revision边界缓存，切风格复用预热；每行Rebuild合页，帧内不生成字形。折章Black、倾诉Light/Italic最新源码接线见后续批次，不能把接线当作所有字体已验收对齐。

v45稀疏glyph halo出现方块和多重字影，不能算glow通过。后续候选改为纯GPU离屏：四分之一backing尺寸双RenderTexture，mask批DrawProcedural后横/竖两次separable Gaussian Blit，fullscreen composite在bubble后正文前。RT仅尺寸变化分配，与每行glyph buffers释放分离，无CPU像素读取；无glow descriptor时不提交效果。暂统一radius18逻辑像素/莫奈22，经panel scale转换RT像素，仍需原版半径/强度与Retina实际画面对照，不能宣称精确一致。

下一批源码候选：折章active Black900、inactive Bold700；倾诉tilted Light300、其他Bold700，tilted的italic标记由style8/animated/transition.w=1供shader消费，尚需实图。心象/浮名/时计/镜台上下文Semibold600；重新核对群唱context原`.medium`，已修为Medium500；折章与时计翻译Semibold600，其余Medium500。五font同atlas映射，未退回合成字重。

云阶/回环已改按真实displayUnit分组（英文整词），同组glyph保留字体内部x/y差值，只整组放置，变换后timing.zw=placement中心。Editor验证真实descriptor重排不破坏内部偏移，并断言`Singin' in the Rain`为4单位。布局公式已有基础映射，原3D组合轴/透视、音频响应仍需真实对照。

镜台新增原panel：主black.26、28圆角、1逻辑像素三色细描边、padding34/28、翻译size=max15,.18font两行、间距14；前后white.025、24圆角、white.07/.8细描边，textSemibold24/两行，宽min520,.46w，位置(.23w,.3h)/(.78w,.7h)、34/-38°、scale.76/.82。装饰kind7独立background批，文字/背景共用plane transform。Shader斜轴比例、当前panel动画、阴影26+high18及粒子层次未全面实图验收，不标完整完成。

v47浮名上下文裁切返工：此前直接居中绘制无限宽文字，遗漏原Swift的`.frame(width:w*min(block.width,.42),alignment:leading/trailing)`与`.lineLimit(3)`。现依据实际非空白grapheme数计算原block.width（clamp(length/28,.34,.68)），每块受限三行，奇偶块分别leading/trailing，blur=min(distance*3.2,2.2)。投影frame若越界则仅平移到24逻辑像素安全边距；原投影frame本身在邻近反向列可越界，因此这是明确的可读性约束，不声称原版逐像素等价。摄像机Y累计高度也改用同一非空白grapheme计数。Editor覆盖720/1440左右实际descriptor顶点及三行限制，运行日志报告真实字体bounds；真实静音复验仍未完成。

|主题|原始构图/关键参数|已移植源码|尚未通过的精确项|
|---|---|---|---|
|流光|居中VStack，22间隔；当前字体18..112；前文左/后文右、15..24、alpha.18/.28；翻译max16,size*.22/alpha.66|max字号公式、位置/比例/alpha；真实单位词级时间、阶段颜色/缩放/lift、FNV稳定motion；连续GPU字体；displayUnit共享bounds中心；翻译两行布局及后文随高度移动|系统rounded字体/字重、整组GPU变换实图、上下文blur1.5/.9、动态glow和黑shadow实图、两行真实字体行高/tracking、节目侧栏-150偏移|
|莫奈|左侧渐变竖轨宽3+high*2，高min520,h*.7；上下文±2，spacing14；当前可用宽.58w；翻译max15,size*.2/alpha.54|五行左对齐、字号公式、alpha、实际字高避免重叠；词级原阶段动画；displayUnit中心；翻译.62w两行/后文高度|竖轨原三段渐变/真实width高频响应、上下文blurabs(offset)*.34实图、字体字重、两行真实行高、当前glow22实图、节目侧栏-96|
|群唱|前文右/后文左；上下间18；当前黑.32填充、不规则8/30圆角、accent.34或chorus secondary.46细1px；上下胶囊fill.045/stroke.08细.8px|真实字宽/高度、字号.5w、翻译max14,size*.19/alpha.56、原alpha/圆角、Retina-aware逻辑线宽；声部stableHash11/23/37及冲突规则、chorus ensemble；4声部GPU矢量图标、34/27圆圈及当前对角渐变；displayUnit中心；翻译两行及bubble高度|跨平台对应图标形状不等同SF Symbols；字体/字重、渐变阴影glow实图、节目侧栏-140、两行真实行高；须真实画面复验蓝边是否与原细描边一致|
|心象|前后row±92/96，active38/context24，前后scale.82/.9、alpha.3/.46，3D Y±12|基础构图、字体、alpha/GPU透视|gradient/tracking、blur2.4/1.5、原透视轴与比例、活动beatLift|
|云阶|Partita FNV列/阶梯/散布/chorus扇形，每displayUnit位置，不是每字母位置|FNV/布局参数及动画；最新改displayUnit分组保留词内字形偏移|整组真实画面、原3D轴、translation/字体/particle响应|
|浮名|Fume实际字符数累计Y及交错X、cameraTarget；active居中.62w|实际block Y/X、上下文场、字号/alpha|原block宽度/换行/视距blur与背景圆角、镜头过渡、tracking|
|倾诉|按1..4段逐时显现、某段italic/light/secondary gradient、-7°旋转|真实分段数量/时间与稳定选段|原字重italic、三色gradient、真实3D perspective、段落token整体布局|
|回环|逐displayUnit弧角(-.79..+.79)，radiusmin430,.38w、Y=-cos*92、Y轴perspective|基本弧和时钟漂浮、字号26..72；最新整词共享placement中心|整体displayUnit投影实图、原视角轴、翻译/黑shadow及音频响应|
|时计|±4行、20.5°步进、scale/opacity、半轮渐变细1.2+high*1.4与宽弧、中心glow|9行角度/scale/alpha、半轮与字号|原双渐变弧/中心glow、轮廓高频响应、原文字leading锚点投影|
|镜台|主black.26/28圆角；前后white.025/24圆角，Y视角34/-38、180原粒子|kind7主/前后panel原fill/描边/padding/翻译两行及位置scale；180 GPU粒子|panel及描边/翻译实图、粒子blur/深度/glow、原透视/尺寸|
|折章|最大4行/5秒段落分组，.72秒smoothstep；前组±90°Z/±7°Y退场，当前从.68h进场|分组/方向/.72秒GPU折转、scale/alpha|原Y透视、上下文组真实多行字体尺寸与行距、侧栏偏移、active translation/glow|

自动模式由真实 `StageLyricModeDirector` 选择，不能用随机或固定GPU主题代替。

Retina：统一使用 `Screen.width / panelSettings.scale` 的逻辑视口；shader转换NDC后由真实target rasterize。细描边的coverage使用`fwidth(distance)`，不把backing像素数当逻辑像素宽度。需在窗口/全屏实际截图及render target尺寸读回验证，不能从缩略图推断倍率。

验收需同一真实歌曲、时间点和同一主题与原版对照，分别记录当前/翻译/上下文是否单份、基线/字宽、颜色透明度、真实帧率、切歌及风格切换。上表中的源码移植不能替代视觉验收。
