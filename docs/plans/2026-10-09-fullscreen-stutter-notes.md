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

---

## 2026-10-09 17:20 定位完成 + 修复（工作树 `codex/rust-full-migration` @ 97b50cb，已装 228）

### 结论先说
「切全屏会卡」那一帧的主线程成本**不是**像素、不是 GPU、也不是显示模式切换，
而是 **GPUI 轮询快照的 Newtonsoft Json.NET 树**：20 Hz 的 `NativePlayerBackend.Tick()`
把整份宿主信封（真机实测 **158 472 B**）**解析 2 次、整树深拷 1 次、序列化 2 次**，
再把字符串交给 `GPUIChat2Probe.ApplySnapshot()` **重新解析**一次，最后编码成 UTF-16
字符串再转 UTF-8。窗口态就已经是这样，全屏只是把同一份成本叠在更小的像素预算上。

### 怎么量出来的（不需要点界面）
`sample <pid> 5` 的调用图里主线程 71 % 是 Mono JIT 的 `<unknown binary>`；用
`lldb -p <pid>` + Mono 导出的 `mono_pmip()` 把地址还原成方法名（脚本留在
`tmp/fs-stutter/resolve_jit.py`），得到（全屏态那一份，3392 个采样）：

| 采样点 | 占比 | 是什么 |
|---|---|---|
| `PlayerScreen.Update()` | 71 % | 2420/3392 |
| └ `NativePlayerBackend.Tick()` | 43 % | 20 Hz（`nextPoll = Time.unscaledTime + .05f`） |
| &nbsp;&nbsp;├ `gmgn_unity_host_snapshot`（原生） | 12.8 % | 宿主现造 158 KB JSON |
| &nbsp;&nbsp;├ `JObject.Parse(json)` | 13.1 % | 解析 ①（Tick:261） |
| &nbsp;&nbsp;├ `PublishGPUIProjection` → `JToken.DeepClone()` | 9.3 % | 整树深拷 |
| &nbsp;&nbsp;├ `PublishGPUIProjection` → `JToken.ToString(None)` | 4.1 % | 序列化 ① |
| &nbsp;&nbsp;├ `ApplySnapshot` → `JObject.Parse(string)` | 11.8 % | 解析 ②（自己刚写出来的字符串） |
| &nbsp;&nbsp;├ `ApplySnapshot` → `JToken.ToString(None)` | 4.1 % | 序列化 ②（走 UTF-16） |
| &nbsp;&nbsp;└ `gmgn_gpui_chat_snapshot`（原生） | 12.2 % | overlay 用 serde 再解析一次 + 重投影面板 |

窗口态同一份采样形状完全一样（`CallUpdateMethod` 3163/3532、`PlayerScreen.Update`
3102/3532、`Tick` 1816/3532），所以**窗口态与全屏是同一条热点**。

### 数字（同一会话，已装 228 实例）
| 条件 | fps | framesOver50ms/5 s | cpuMs（轮询帧 / 无轮询帧） | gpuMs |
|---|---|---|---|---|
| 窗口态 1440×900，`stageActive=False points=0` | 31.0–34.6 | 12–23 | 40.3 / 13.6 | 6.9 |
| 全屏 4096×2304 `FullScreenWindow` | 12–30 | 28–83 | 53.0–62.8 | 15.4（2.2×） |
| 窗口态 `stageActive=True points=22536`（`Player-prev.log`） | 11.3 均 | 57 均 | 80.8–92.5 | 1.0–7.0 |

**显示模式没有变**：`system_profiler` 主屏 U3277WB 原生 4096×2304「UI looks like
2048×1152 @60Hz」；`Player.log` 里窗口态与全屏态都是 `display=4096x2304`，全屏只是
`Metal RecreateSurface surface size 4096x2304`（1440×900 → 4096×2304，8.1× 像素）；
`log show` 在 16:50–16:58 的 WindowServer / SkyLight / loginwindow 里 **0 条**
`reconfig|modeset|DisplayMode` —— 本次主屏全屏**没有切显示模式**，第 1 条历史假设
（模式切换）在这一格不成立。

### 修了什么
1. 新增 `apps/unity-player/Assets/GMGN/GPUIProjectionPayload.cs`：一次轮询只许
   `Parse` 一次、`Encode` 一次（UTF-8 直写、无 BOM、无 UTF-16 中转），`Augment`
   就地加主线程附件、不再整树 `DeepClone`。
2. `NativePlayerBackend.PublishGPUIProjection`：把**解析好的树**交给探针
   （事件 `Action<string> GPUIHostSnapshot` → `Action<JObject> GPUIHostProjection`），
   去掉整树 `DeepClone()` 与 `ToString()`；Tick 里 3 处 `JObject.Parse(json)["…"]`
   改成读同一棵树。
3. `GPUIChat2Probe.ApplySnapshot(JObject)`：不再解析自己刚序列化的字符串。
   载荷逐字节不变（有判据）。
4. 判据 `tools/test-gpui-projection-cost.py`（挂在 `make _test-harnesses`）：结构 6 条
   必须绿、且**在改前修订的源码上必须条条红**；代价用真代码编译实测，**必须与改前
   逐字节相同（无 BOM）且中位耗时 ≤ 改前的 60 %**，负对照是改前实现本身。
   （2026-10-09 收口补记：修复随 `e474e0a` 进版后 `HEAD:` 已经是修好的形状，固定读
   `HEAD:` 的负对照变成"条条已绿"，判据空转。脚本改为从 HEAD 往回找第一条 6 条结构
   还全红的祖先作锚点——build 230 在 `HEAD~2`（`97b50cb`）上命中；判据强度不变。）

真机 158 472 B 信封实测（同一进程内跑改前实现 vs 现在的实现）：

    payload 161 521 B，逐字节相同、无 BOM
    中位一次轮询 29.2 ms → 6.5 ms（22.4 %）；p95 62.1 → 18.9 ms
    每次轮询分配 9.86 MB → 3.87 MB

### 还没覆盖到的（需要一次 Unity Player 重建，本轮按要求没打包）
- 端到端 fps/`framesOver50ms` 的前后对比要重出 player：本轮「不许打包装机、不占版本号」，
  所以只交代码 + 判据 + 同会话量测。
- 剩余主线程成本（改后仍占大头）：`gmgn_unity_host_snapshot` 12.8 %（宿主把
  overlay 明确丢弃的 world/grid blob 也塞进信封）、overlay 侧 `gmgn_gpui_chat_snapshot`
  12.2 %（每次轮询都重算 `visual_projection` 两遍、`normalize_chat(旧)` 两遍，并
  无条件刷新设置窗——和已修的 `availableMotions` 是同一类「每帧重建投影」）。
  这两处都在其它线正在改的文件里（`apps/macos/UnityHost/**`、`tools/fixtures/gpui-unity-overlay-probe/**`），
  本轮按红线没有同时改。
- 全屏每像素 pass（`GpuLyricsView` 的预算）：本次会话 `gpuMs` 全屏只 15.4 ms 而
  `cpuMs` 40–125 ms ⇒ **不是**这一格的瓶颈；等 CPU 修完、重出 player 后再看
  `gpuMs`/`stageSubmitMs` 才有意义（历史基线 73–75 fps 说明这一格曾经够用）。
