# NativeLinkPlayer 声音链：HLS `MTAudioProcessingTap` 支持边界与最小返工

> 交付对象：主代理（由主代理统一检查、提交、重构建并跑真实 App E2E）。
> 范围：macOS `NativeLinkPlayer` 声音链与诊断。
> 环境：macOS 26.5.2（25F84）。
> 不改对话架构、不碰生产 data / Keychain / 已装 App、不替换引擎、不独立 commit/push。

## 结论（先看这段）

真实音视频停滞的根因不是「tap 没挂上」，而是**对 HLS 用了平台明确不支持的东西**：

- 现行代码在清单（HLS / 直播）路径上调用 `AVMutableAudioMixInputParameters()`（无轨、「all-tracks」）并把它设进 `AVPlayerItem.audioMix`。Apple 文档写得很死：

  > An audio mix can only be used with file-based media and is not supported for use with media served using HTTP Live Streaming.
  > —— `AVPlayerItem.audioMix` 讨论区

- 本机同一台机器、同一条真实流上的 A/B 实测进一步证明：不设 `audioMix` 时画面正常；设无轨混音时 item 卡在 `preparing`，即 `decodedFrames=1`、`rate=0`、PCM 全 0；用真实轨的混音则不卡，但 HLS **静默忽略**它，tap 一次都不回调。
- 所以最小正确修改是：**只对 file-based 媒体（单文件合流 / 分轨 composition）用真实轨挂 tap；HLS / 清单不设 `audioMix`，由 `AVPlayer` 原生输出真实声音**。绝不为了「有采样」再设无轨混音。
- 修复后生产探针对真实 Twitch HLS 读到：`decodedFrames=630`、`gpuCopies=630`、`timeAdvancedSeconds=21.97`、`itemStatus=1`、`rate=1`、`playerState=playing`。**停滞已消除，画面真实在放。**
- HLS 的 tap 如实报 `audioTapAttached=false` / `audioTapInstallDetail=unsupported:hls-manifest`；E2E 的声音判据按既有逻辑 `blocked`，不冒充通过。file-based 链路仍能采到非静音 PCM；本机 440 Hz 测试片 `peak≈0.157`。

## 1. 权威边界

Apple 对 `AVPlayerItem.audioMix` 的原文（2026 年抓取）：

> An audio mix can only be used with file-based media and is not supported for use with media served using HTTP Live Streaming.

结论：**`MTAudioProcessingTap` 经 `AVPlayerItem.audioMix` 挂载，对 HLS 没有支持。** 这不是旗标猜测，也不是时序问题。

## 2. 本机 A/B 实测

探针（本地、已 gitignore）：`tmp/dsh-audio-tap-experiment/Probe.swift`，编译为 `/tmp/dsh-audio-tap-probe`。
测试素材：真实 Twitch HLS，链接 `https://www.twitch.tv/eslcs`，格式 `-f 360p30`；另有 Apple VOD HLS、本机 `ffmpeg` 生成的 440 Hz 渐进式 MP4。

| 策略 | 本地 MP4（file-based） | Twitch / Apple HLS |
|---|---|---|
| 不挂 tap | 正常播放 | 正常播放 |
| 无轨混音，起播前挂 | **卡死**（`rate=0`、`decodedFrames=1`、`tapBuffers=22`、`tapFrames=98428`、`tapPeak=0`、PCM 全 0） | **同样卡死**（数值一致） |
| 无轨混音，等 `ready` 后再挂 | 卡死 | 卡死 |
| 真实轨混音，等 `item.tracks` 出现后挂（暂停） | **正常**：`decodedFrames=163`、`timeAdvanced≈5.65 s`、`tapBuffers=64`、`tapFrames=286336`、`tapPeak≈0.157`、`tapRawNonZero=true` | 播放正常但 `tapBuffers=0`（**混音被忽略**） |
| 真实轨混音，播放中热挂 | —— | 播放正常但 `tapBuffers=0` |
| 真实轨混音 + PreEffects | —— | 播放正常但 `tapBuffers=0`（换旗标无效） |

要点：

1. **无轨混音本身就是坏的**：与是否 HLS 无关，本地文件也会把播放管线卡死在 `preparing`；
2. **真实轨混音对 file-based 有效**，且能采到非静音真 PCM；
3. **HLS 对真实轨混音静默忽略**，与 `ready` 前后、`PostEffects` / `PreEffects`、轨道发现方式（`item.tracks` / `asset.tracks`）都无关；
4. 回调写法（直通 `flagsOut` 的规范写法 vs 现行写法）也不是原因，两种都卡在无轨混音上。

对应日志：`/tmp/gmgn-dsh-audio-tap-experiment2.log`、`/tmp/gmgn-dsh-audio-tap-experiment3.log`、`/tmp/gmgn-dsh-audio-tap-experiment4.log`。

## 3. 最小正确修改

### 3.1 `NativeLinkPlayer.install(_:)`

- 删除「起播前同步挂无轨混音，挂不上再等协商」的老逻辑；
- 改为：
  - 未声明音频 → `noteUnavailable("no-audio-declared")`；
  - 环境禁用 → `noteUnavailable("disabled:env")`；
  - **file-based 且有真实轨** → `audioSampler.install(on:track:)` 用真实轨挂；
  - **清单 / HLS** → `noteUnavailable("unsupported:hls-manifest")`，**不设 `audioMix`**，`AVPlayer` 原生输出声音；
- 删除已死的 `attachAudioTapWhenReady` 与 `audioTapTask`（它的无轨兜底正是卡死源）。

### 3.2 `NativeAudioSampleTap`

- `install(on:track:)` 现在**要求真实轨**：`track == nil` 时只记 `unsupported:no-track` 并返回，绝不退化成 `AVMutableAudioMixInputParameters()`；
- 新增 `noteUnavailable(_:)`，如实记录未挂原因，便于 E2E / 驱动具名诊断；
- 挂载成功时 `installDetail = "track:<trackID>"`。

### 3.3 诊断增强

- `NativeLinkPlayer` 新增：`waitingReason`、`isPlaybackLikelyToKeepUp`、`isPlaybackBufferEmpty`、`isPlaybackBufferFull`；`timeControlStatus` 原已有；
- `NativeScreenPlaybackCoordinator.Metrics` 与 `GMGNRadioApp` 的 `playback_state.nativeLink` 投影同步暴露这些字段；
- `tools/probe-native-link-playback.swift`：
  - `timeControlStatus` / `waitingReason` / 缓冲健康度改到 `stop()` **之前**读；此前在 `stop()` 之后读，恒为 `-1`；
  - verdict 区分「画面在放但 HLS 声音采样平台不支持」与真正的停滞：前者为 `PLAYING_VIDEO_HLS_AUDIO_TAP_UNSUPPORTED`，后者为 `FAILED_OR_STALLED`；不再把平台边界误报成停滞。

## 4. 验证证据（本次实际运行）

1. 生产源码经现有探针编译通过 + 离线判据 11/11 PASS。
2. 修复后生产探针对真实 Twitch HLS（观测 20 s，最终一次）：

   ```json
   {"verdict":"PLAYING_VIDEO_HLS_AUDIO_TAP_UNSUPPORTED",
    "decodedFrames":455,"gpuCopies":455,"timeAdvancedSeconds":15.789,
    "itemStatus":1,"timeControlStatus":2,"rate":1,"playerState":"playing",
    "likelyToKeepUp":true,"bufferEmpty":false,
    "audioTapAttached":false,"audioTapInstallDetail":"unsupported:hls-manifest",
    "isMuted":false,"volume":1}
   ```

   探针退出码 0（画面通过、HLS 声音采样平台不支持如实标注）。日志：`/tmp/gmgn-dsh-probe-verify-final.log`。
   更早一次 30 s 运行读到 `decodedFrames=630`、`timeAdvancedSeconds=21.97`，日志 `/tmp/gmgn-dsh-probe-twitch-fixed.log`。
3. file-based 对照（本机 440 Hz MP4，策略探针）采到真实非静音 PCM：`tapPeak≈0.157`、`tapRawNonZero=true`。

复现命令：

```bash
# 1) 编译生产源码 + 离线判据（无网络）
swift tools/probe-native-link-playback.swift

# 2) 真实 HLS：画面必须真在放；tap 如实 unsupported
GMGN_SCREEN_LINK_HELPER=/opt/homebrew/bin/yt-dlp \
  swift tools/probe-native-link-playback.swift https://www.twitch.tv/eslcs 20

# 3) file-based 声音对照（先造 440 Hz 测试片；A/B 策略探针见 tmp/，已被 .gitignore 忽略）
ffmpeg -y -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
  -f lavfi -i "testsrc=duration=6:size=320x240:rate=30" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest /tmp/dsh-tone.mp4
```

## 5. 明确的未通过 / 边界（不冒充）

1. **HLS 真实声音无法用 `MTAudioProcessingTap` 采样取证**。这是平台文档级边界，不是实现缺陷；E2E 的 `check_screen_audio` 会按既有逻辑把 HLS 声音判为 `blocked`，判据是 `audioTapAttached` 不为 true；这是诚实的，不能改成通过。
2. **Core Audio 进程输出 tap 已调研但不采用**：`AudioHardwareCreateProcessTap`。
   - macOS 14.2+ 可用，理论上抓的是本进程混音后的真实输出，不受 HLS 限制；
   - 本机实测：`AudioHardwareCreateProcessTap` 与聚合设备创建都成功，但 `AudioDeviceCreateIOProcIDWithBlock` **挂起不返回**；探针为 `tmp/dsh-audio-tap-experiment/ProcessTapProbe.swift`，日志停在 `stage: create-aggregate ok`。
   - 在无交互应答者的 E2E 环境里会卡死，风险高于收益，故**不接入生产**；如主代理要推进，需先解决系统音频采集的 TCC / 授权与超时兜底。
3. 本次**没有**实跑真实 App。真实 App 的重构建与端到端验收由主代理执行（见下）。

## 6. 交付主代理：重构建与 E2E 预期

改动文件：

- `apps/macos/Sources/GMGNRadio/Screen/NativeMedia/NativeLinkPlayer.swift`
- `apps/macos/Sources/GMGNRadio/Screen/NativeMedia/NativeScreenPlaybackCoordinator.swift`
- `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`
- `tools/probe-native-link-playback.swift`（诊断增强）

建议步骤：

1. 主代理在宿主重构建：`GMGN_BUNDLE_SCREEN_LINK_HELPER=1 bash tools/e2e-app-build.sh --print-path`；
2. 用既有 `tools/e2e-real-app.py` 跑真实 App 流程（隔离测试根，不复用旧 root）；
3. 预期变化：
   - 电视视频项 **由 fail 转 pass**：真实画面在放（原 `decodedFrames=1 / rate=0` 的停滞消失）；
   - 电视声音项对 Twitch HLS 仍是 `blocked`，原因字符串为 `unsupported:hls-manifest`（**平台边界，已文档化**）；
   - `playback_state.nativeLink` 新增 `waitingReason` / `likelyToKeepUp` / `bufferEmpty` / `bufferFull`，便于日后卡顿定位；
4. 若要拿到「真实非静音 PCM」的通过证据，需用 **file-based**（直链渐进式）链接驱动电视：该路径 `tapAttached=true` 且 `audioPeakAmplitude>0`。是否调整 E2E 素材/判据由主代理与用户决定，DSH 不擅自改判据。

## 7. 边界与保护

- 未改对话架构（真实 chat 专项 7 pass 不受影响）；
- 未回退主代理的 MainActor 回调修复与 AppHost 旧 quit 邮箱修复；
- 未碰生产 data、Keychain、已装 App；未跑同一 root；未替换引擎；
- 未独立 commit / push，等待主代理统一检查提交。
