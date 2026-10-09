# 「浏览器放视频时 gmgn 切全屏就卡」——待办记录（用户 2026-10-09 指示：回头再看）

## 复现（用户原话）
> 我浏览器放 **YouTube**，gmgn 切全屏就会卡。

即：**浏览器在放视频**（不只是音频）+ gmgn 进全屏 ⇒ 卡顿。用户明确要求**先挂起**，等其它修复完成后再看。

## 已经拿到的证据（不要重复劳动）
- **出货包 223/224 里没有 GPUI 歌词层**：`Contents/PlugIns/libgmgn_gpui_overlay_probe.dylib` 内 `nm | grep -i lyric` = 0 符号、`gpu_atlas_frame_budget_exceeded` 字符串 0 次 ⇒ `apps/gpui-ui/src/lyrics*` 在该包里是死代码 ✗。产品里真正的动态歌词是 **Unity 侧 `GpuLyricsView`**（`Assembly-CSharp.dll`），且默认 `stageLyricsMode=automatic` + 无曲目时只走纯文本 Label。
- **副屏全屏实测不掉帧**（一条线以 223 的原 dylib 做隔离实验）：窗口态 720×450pt fps **73.2–74.6**；全屏 1280×1600pt（像素 ×6.3）fps **71.0–73.6**，`framesOver50ms` ≈ 0 ⇒ 那一格**没复现**。
- **overlay 侧无 resize/重排风暴**：`[GPUIOverlay] geometry changed=` 窗口态约 15–40s 一次；进全屏只有 1 次 `hostViewportStale`（+~20ms 跟随）；`sample` 6s 主线程 700/1145 采样在 `mach_msg` 等待，**没有主线程阻塞**。
- **没跑通的那一格正是用户报的情形**：**主屏**全屏（2048×1152pt / 4096×2304px，进全屏会**切显示模式**）+ **浏览器同时放视频** —— 因当时机器内存 63/64G 满、load 14–34、并发实验实例互相抢焦点，未能稳定复现。
- 历史基线（`docs/plans/2026-10-04-unity-space-migration.md:258`）：4096×2304 + 音乐/歌词曾稳定 73.0–74.4 fps ⇒ **全屏本身在历史版本上不掉帧**，所以更像"某条 pass 回归 + 浏览器抢 GPU"。
- 环境侧已知热源：`coreaudiod`、`WindowServer`、`SkyLight`、浏览器 renderer 在放视频时都显著吃 CPU/GPU。

## 主要假设（按可能性排序）
1. **显示模式切换 + 浏览器视频解码/合成抢 GPU**：进全屏触发 macOS 重新配置显示，同时浏览器视频管线与 Unity 抢 GPU/合成 ⇒ 卡。
2. **Unity `GpuLyricsView` 全分辨率 pass 无像素预算**（`apps/unity-player/Assets/GMGN/Lyrics/GpuLyricsView.cs`）：每帧 1 次 compute + 1–3 次**全分辨率** `Graphics.RenderPrimitives`（glyph/glow/合成），只有 glow 链按 `width/4 × height/4`；`SettleViewport` 后 `Rebuild()`。修法：把 `tools/gpui-lyrics-metal-probe/lyrics_layer.m:133-134` 的预算搬过去（`effectiveScale = sqrt(budget/area)`，`budget = min(4194304, 256MiB/(4*(5+depth)))`），先降采样 glow/effect 两个全屏 pass 也能显著减负。
3. 与 UI 层无关的可能：Unity 全屏分辨率 ×3 像素本身 + 视频播放的 CPU 抢占。

## 下一步（需要人参与的地方已标注）
1. **在主屏复现**：浏览器放 YouTube（1080p 以上）+ gmgn 点全屏（**必须真人点**，本项目合成点击不可靠且现已禁止 ✗），同时记录：Unity fps、`framesOver50ms`、`[GPUIOverlay] geometry` 频率、`sample` 主线程热点、浏览器是否也掉帧。
2. **二分**：同一场景下 gmgn 放全屏而**浏览器暂停视频** ⇒ 若不卡，基本锁定"视频合成 + 显示模式切换"；若仍卡，走假设 2。
3. 若指向假设 2：改 `GpuLyricsView` → **重出一次 Unity Player** → 用同一台机器、同一视频、同一显示模式复测。
4. 另需澄清：卡的是**画面**还是**声音**（用户尚未回答），以及 gmgn 自己当时是否也在放歌（历史日志里出现过 `LocalMusicPlayer state=playing`）。

## 不要做的事
- 不要再为这个问题起一堆实验包（会把机器堆满内存/IO，反而制造"卡"）；不要合成点击；不要改系统分辨率/音量/设备。
