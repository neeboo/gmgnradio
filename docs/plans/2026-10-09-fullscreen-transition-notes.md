# 全屏**转场**卡顿：取证与修复（2026-10-09，工作树 `rust-full-migration` @ `5e5dfa1`）

范围：只做**转场**（进/退全屏那一下）。全屏**稳态**实测不差（33.7–51.5 fps、卡顿帧 0–4），
窗口态更差（16.2 fps、卡顿帧 81）由**另一条线**负责，本轮没有碰。

## 1. 调用链（逐字，文件:行）

```
apps/unity-player/Assets/GMGN/PlayerScreen.cs:108
    case "ui.window.fullscreen": compactWindow.ToggleFullscreen(); return true;

apps/unity-player/Assets/GMGN/UnityCompactWindowController.cs:55
    public void ToggleFullscreen()
    {
        Debug.Log($"[LiveCamPointer] fullscreen clicked transitioning={transitioning} compact={IsCompact} fullscreen={Screen.fullScreen}");
        if (!transitioning) StartCoroutine(ChangeFullscreen());
    }
apps/unity-player/Assets/GMGN/UnityCompactWindowController.cs:68（ChangeFullscreen 内）
    NativeUIScale.ToggleFullscreen();

apps/unity-player/Assets/GMGN/NativeUIScale.cs:23
    if (width > 0 && height > 0) Screen.SetResolution(width, height, FullScreenMode.FullScreenWindow);
    // width/height 来自 NativeUIScale.cs:22 的 gmgn_unity_screen_pixels(0/1) = 4096x2304
```

`Metal RecreateSurface` **不是仓库代码**：它是 Unity 自己的 Metal 图形设备在
`Screen.SetResolution` / 窗口尺寸变化后重建 `CAMetalLayer` drawable 时打的日志。
真机（`tmp/fs-stutter/Player-1658.log`）里它紧跟在点击后面一行：

```
[LiveCamPointer] fullscreen clicked transitioning=False compact=False fullscreen=False
Metal RecreateSurface[0x108151260]: surface size 4096x2304
GPU frame timing ... screen=4096x2304 ... fullscreen=True/FullScreenWindow display=4096x2304
```

overlay 侧（同一进程、同一主线程）：

```
apps/unity-player/Assets/GMGN/GPUIChat2Probe.cs:177
    mounted = parent != IntPtr.Zero && gmgn_gpui_probe_mount(parent) == 0;
    // parent = gmgn_overlay_unity_content_view() = Unity 窗口的 contentView

tools/fixtures/gpui-unity-overlay-probe/host/OverlayHost.m:428-436
    for (NSNotificationName name in @[NSWindowDidResizeNotification, ... NSWindowDidEnterFullScreenNotification ...])
        ... queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { traceFacts(...); updateGeometry(); }

tools/fixtures/gpui-unity-overlay-probe/src/lib.rs:253-266  reconcile_host_geometry
    eprintln!("... event=hostViewportStale host={width}x{height} gpui={}x{} nativeChanged={native_changed}", ...);
    window.bounds_changed(cx);
    window.refresh();
```

**关键因果**：overlay 的 GPUI 视图挂在 Unity 进程里（`gmgn_gpui_probe_mount` 要求
`pthread_main_np()`，`lib.rs:310`），所以 **Unity 主线程上的同步重活就是 overlay 的
「没有帧」**。

## 2. 转场里唯一的同步重活（真机实测，非推断）

`apps/unity-player/Assets/GMGN/Lyrics/GpuLyricsView.cs` 是唯一按 `Screen.width/height`
重建的视图（`GpuPointCloud` / `GaussianWorldView` 只读 `Screen.height` 算缩放，不重建）。

```
GpuLyricsView.cs:141   var layoutChanged = SettleViewport(Screen.width, Screen.height, panelScale, ...);
GpuLyricsView.cs:144   Rebuild();
GpuLyricsView.cs:265   WarmFonts();
GpuLyricsView.cs:393   role.TryAddCharacters(text,out _);   // 一次性，整轨文本 × 6 套字体
```

`tmp/fs-stutter/Player-1658.log:860-863`（进全屏那一帧）：

| 项 | 实测 |
|---|---|
| `rebuildMs` | **422.807 ms** |
| └ `warmFontsMs` | **411.747 ms** |
| └ `glyphLayoutMs` | 4.724 ms |
| └ `atlasBindMs` | 6.162 ms |
| `GPU lyric font atlas` `uploadMs` | 5.253 ms（15 页） |
| `GPU lyric glow targets` `allocationMs` | **0.446 ms**（1024×576 ARGBHalf ×2） |
| 同一处 resize、字体已热之后 `rebuildMs` | **0.698 ms** |

⇒ 转场里那 455 ms 级的空档是 **411.7 ms 的一次性字体 warm**，不是像素、不是 RT、不是
overlay 布局。RT 重建 0.446 ms、resize 重绘 0.698 ms，都不值得为它们牺牲画面。

## 3. 一处对既有证据的更正（诚实边界）

`OverlayHost.m:449-456` 的帧泵是

```
frameTimer = [NSTimer timerWithTimeInterval:1.0/30 repeats:YES block:... {
    if (NSProcessInfo.processInfo.systemUptime < frameUntil) drawMountedFrame(); }];
frameUntil = NSProcessInfo.processInfo.systemUptime + 2;   // OverlayHost.m:132 wakeFrames
```

即 `drawMountedFrame` **只在被唤醒后的 2 秒内**才画。所以
**两条 `drawMountedFrame` 之间大于 2 s 的空档是「空闲」，不是「卡住」**。
用户报的 **18 662.7 ms** 与 **2 254.8 ms** 两条空档都 > 2 s ⇒ 按这条规则它们是空闲，
不能作为转场卡顿的证据；`56.490→56.945` 的 **454.9 ms < 2 s**，那一条才是真卡顿，
且与上面测到的 411.7 ms warm 同量级、同机制。
采集脚本已经把这条规则写进判读里。

## 4. 修法（只碰 `apps/unity-player/Assets/GMGN/**`，画面语义不变）

1. 新增 `ViewportTransition.cs`：**纯值类型**的有界转场窗口。下限 1.0 s（盖住实测
   795 ms 的 AppKit 动画）、上限 2.0 s（怎么都不许超）、连续 3 帧 framebuffer 稳定可提前收。
2. `NativeUIScale.cs`：它是**唯一**改 `Screen.width/height` 的代码路径，所以由它
   `BeginViewportTransition()`（`ToggleFullscreen` 的两个分支各一次，在
   `Screen.SetResolution` 之前），并在 `Update()` 每帧 `Observe(...)` 驱动。
   对外只暴露 `FramebufferMoving`。
3. `GpuLyricsView.cs`：`LateUpdate` 里**只把「整内容重绘」（`WarmPending`）挡在窗口外**
   （`ViewportTransition.DeferFullRebuild`），保留上一份完整布局，窗口一收就在稳定帧上重绘。
   **0.698 ms 的 resize 重绘不挡**——挡它只会让画面停留在旧布局，换不来可测的收益。
4. `GpuLyricsView.RenderGlow`：窗口内**不扩**glow RT（沿用转场前那对，合成按 UV 采样），
   转场结束再补到全尺寸。这就是「按既有质量档在转场期间降档、结束后恢复」。
5. `UnityCompactWindowController.ChangeFullscreen`：compact 路径上 framebuffer 会动两次
   （先窗口、后分辨率），入口处开一次窗口覆盖整段。

画面影响：只在「某轨第一次上屏」恰好撞上全屏切换时，歌词晚到 ≤2 s（`PointCapacity` 本来就是 0，
没有错位帧）；已上屏的歌词不受影响。**没有改分辨率/音量/设备，`Screen.SetResolution` 原样保留。**

## 5. 能失败的判据

`tools/test-viewport-transition-defer.py`（挂在 `make _test-harnesses`）：

- 用 Unity 自带 Roslyn（`Scripting/DotNetSdk/.../csc.dll`）**真编译真跑** `ViewportTransition.cs`，
  按实测时间线（0 ms 请求、+1 ms RecreateSurface、+795 ms didEnterFullScreen）驱动，
  断言窗口盖住动画、有界、NaN 时钟也收；断言一次性 warm 落在窗口外，**并断言 HEAD 的
  无条件重建落在窗口内**（负对照）。
- 7 条结构门禁，逐条对 `git show HEAD:<path>` 必须红。
- 自检：跑完重算 sha256，源码被改动即红。

自查（都在 `/tmp` 影子树里做，没有碰工作树）：HEAD 全树 ⇒ 7+1 条全红；9 种注入
（放大上限、去掉下限、`Observe` 忽略上限、把 gate 挪到重建旁边、窗口内照样扩 RT、
`WarmPending` 恒真、少一个 `Begin`、少一处 `Observe`、少一次开窗）⇒ 逐条红；
**未注入的基线必须绿**。

## 6. 真机采集（请用户点一次全屏并保持 40 秒）

```
GMGN_GPUI_INPUT_DIAGNOSTICS=1 open -a "gmgn radio"
bash tmp/fs-transition-232/collect-transition.sh before     # 旧 player
bash tmp/fs-transition-232/collect-transition.sh after      # 重建后的 player
```

脚本只读日志 / `sample` / `log stream`，不发合成输入、不改分辨率、不碰钥匙串；
等待 `fullscreen clicked` 后采样转场并停留 40 s，输出 `summary.txt`：
转场时间线、`Metal RecreateSurface` 时刻、歌词重建分解、`drawMountedFrame`
空档（按 ≤2 s 才算卡顿分开统计）、WindowServer/SkyLight 行。

## 7. 必须重建 player 才能验证的部分

代码与判据都已就位，但**端到端 fps / 转场空档的前后对比必须重出一次 Unity Player**
（本轮按要求不打包、不装机、不占版本号）。离线只能量到「决策」与「耗时分解」，
量不到「重出 player 后转场里还剩多少空档」。
