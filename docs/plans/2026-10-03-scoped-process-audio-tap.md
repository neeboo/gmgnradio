# 按目标 PID 限定的系统输出音频采样器（HLS 真实声音开/停对照）

> 交付对象：主代理（由主代理启动真实隔离 App、处理 GUI 授权并做最终验收）。
> 范围：`tools/` 下**仅验收用途**的采样工具、测试与证据文档。
> 不改生产播放器，不用独立 `AVPlayer` 代替真实 App，不碰 Keychain / 已装 App / 生产数据。
> 基线：`HEAD 86e4f6c`；本轮未 commit / push / reset。

## 结论（先看这段）

- 新增 `tools/probe-scoped-process-audio.swift`：macOS 14.2+ Core Audio **进程 tap**，
  只抓**指定 PID / 指定 bundle** 的进程输出，报告 `peak` / `rms` / `buffers` / `frames` /
  目标 PID / 采样率 / 声道，并提供 `--ab` 真实播放**开/停对照**判真。
- 旧探针卡在 `AudioDeviceCreateIOProcIDWithBlock` 的问题已定位并绕开：聚合设备改用
  **最小配方**（只挂 tap，不设主子设备、不 `autostart`、不做 drift compensation），
  所有可能阻塞的 CoreAudio 调用都放到后台队列并加**有界超时**，主线程不跑 runloop 也不
  无限等待。
- 本机 `macOS 26.5.2` 实测：`--self-test` 全过；对真实隔离 App `ai.gmgn.radio.e2e`
  的 PID `53973` **只绑定该 PID**，10 秒读到 `peak=0.7346`、`rms=0.1175`、`buffers=939`；
  对另行启动的 `afplay` 工具自检，`--ab` 用 `SIGSTOP`/`SIGCONT` 对照得到 `contrast=28214`、`HLS_OUTPUT_CONFIRMED`（该枚举名在此仅证明工具开停判据，不证明真实 App HLS），
  无变化对照得到 `contrast=1.001`、`HLS_OUTPUT_NOT_CONFIRMED`。
- 明确不冒充：`file PCM`、`音轨存在`、`hasAudio`、`tapAttached` 一律**不构成** HLS 输出
  通过；只有“目标进程真实输出在播放窗口显著高于停止后”才算 `HLS_OUTPUT_CONFIRMED`。

## 1. 为什么需要它

主代理真实 App 的正式 `stop_screen` 对照另见返工任务文档：播放期 RMS 0.11745，停止期 RMS 0，均只采 PID 53973。工具 `--host-root --ab` 当前没有等待 HLS 真正起播，主代理实测可能因起播延迟 exit4；完整 driver 使用先等待真实播放再采样、正式停止后采静音的路径。本文 fake 邮箱测试只验证协议，不计为真实 App 业务验收。

`docs/plans/2026-10-03-dsh-native-audio-hls-tap-boundary.md` 已确证：生产电视的 HLS
声音**不能**经 `AVPlayerItem.audioMix` + `MTAudioProcessingTap` 采样（Apple 明确
不支持清单）。但验收又不能把“音轨存在”当“真实输出”。进程输出 tap 恰好补这个缺口：

- 抓的是目标进程**混音后的真实输出**，与播放管线解耦，不受 HLS 限制；
- `muteBehavior = .unmuted`：只旁路采样，**不改目标音量、不静音**；
- 不需要独立 `AVPlayer`，不需要改生产播放器。

## 2. 工具设计与安全边界

### 2.1 只采指定目标，绝不采全系统

- 默认 `--bundle-id ai.gmgn.radio.e2e`；`--pid <pid>` 最精确，优先。
- tap 描述只用 `CATapDescription(stereoMixdownOfProcesses: [processObjectID])`，
  **绝不**使用 `initStereoGlobalTapButExcludeProcesses` 这类“全系统减排除”描述。
- 报告里显式给出 `globalTap=false`、`scopedProcesses=[pid]`、`scopedBundleIDs=[...]`；
  `--self-test` 内置“没有创建全系统 tap”断言。
- 目标未运行、或目标暂时没有音频进程对象时，如实报 `TARGET_NOT_FOUND` /
  `no-process-object`，**绝不**退化成全局采集。

### 2.2 有界超时，不阻塞主 runloop

- 每个可能阻塞的 CoreAudio 步骤都跑在后台队列，主线程只用
  `DispatchSemaphore.wait(timeout:)` 有界等待；这些步骤包括
  `AudioHardwareCreateProcessTap`、`AudioHardwareCreateAggregateDevice`、
  `AudioDeviceCreateIOProcIDWithBlock`、`AudioDeviceStart` 以及销毁。
  默认单步 10 秒，`--setup-timeout` 可调。
- 任一步超时即输出结构化 JSON 并**退出码 3**，绝不让验收挂死。
- 聚合设备最小配方（本机实测不再挂起）：

  ```swift
  [kAudioAggregateDeviceIsPrivateKey: true,
   kAudioAggregateDeviceIsStackedKey: false,
   kAudioAggregateDeviceTapListKey: [[
     kAudioSubTapUIDKey: <tap uuid>,
     kAudioSubTapDriftCompensationKey: false]]]
  ```

  旧探针额外设了 `kAudioAggregateDeviceMainSubDeviceKey: ""`、
  `kAudioAggregateDeviceTapAutoStartKey: true`、`driftCompensation: true`；本机同机实测
  那套 recipe 会停在 `AudioDeviceCreateIOProcIDWithBlock`，本工具不再使用。

### 2.3 开/停对照判真

`--ab` 的相位固定为：**先停 → baseline → 开 → playing → 停 → quiet**。判据：

```
confirmed = playing.rms ≥ minAudibleRms
          ∧ playing.buffers > 0
          ∧ playing.rms / max(baseline.rms, quiet.rms, 1e-5) ≥ minContrast（默认 4）
          ∧ playing 只绑定目标 PID
```

两种驱动方式：

1. `--host-root <测试根> --object-id <电视物件> --hls-url <原始页面链接>`：
   直接走隔离测试 App **仅测试控制面**的文件邮箱，发生产 `play_screen` / `stop_screen`。
   生产 App 未设 `GMGN_E2E_DATA_ROOT` 时不存在该控制面，零生产副作用。
2. `--on-cmd` / `--off-cmd`：由主代理给任意“启动/停止真实播放”的 shell 命令。
   子进程输出被丢弃，**不回显**签名地址或凭据。

### 2.4 ScreenCaptureKit 备选后端

`--backend screencapturekit` 用 `SCContentFilter(display:including:exceptingWindows:)`
**只含指定 runningApplication**，`capturesAudio = true`、
`excludesCurrentProcessAudio = true`。已实现并在本机自检可用；它是 Core Audio 的后备，
权限被拒时具名 `PERMISSION_DENIED` 并给出授权路径，不静默当通过。
`--backend auto` 先 Core Audio，失败才回落。
`--self-check` 会读取一次 `SCShareableContent` 以报告屏幕录制授权状态，首次可能触发一次系统同意框。

## 3. 构建与运行命令

```bash
# 1) 构建（离线；产物在 .gitignore 覆盖的 tmp/ 下）
bash tools/build-scoped-audio-sampler.sh --print-path
#   默认同时生成带 NSAudioCaptureUsageDescription 的 .app：
#   tmp/scoped-audio-sampler/ScopedAudioSampler.app
#   需要 TCC 授权时，由主代理在“系统设置 → 隐私与安全性 → 麦克风/音频录制”里授权该 .app。

# 2) 能力 / 权限自检
tmp/scoped-audio-sampler/gmgn-scoped-audio --self-check

# 3) 按 PID 采集真实 App 输出（示例：8 秒，要求非静音）
tmp/scoped-audio-sampler/gmgn-scoped-audio \
  --bundle-id ai.gmgn.radio.e2e --seconds 8 --expect audible --output /tmp/app-audio.json

# 4) 真实 HLS 开/停对照（主机邮箱驱动；测试根与电视物件 id 由主代理给出）
tmp/scoped-audio-sampler/gmgn-scoped-audio \
  --bundle-id ai.gmgn.radio.e2e --ab \
  --host-root /tmp/gmgn-e2e-XXXXXXXX \
  --object-id <电视物件 id> \
  --hls-url <用户粘的原始页面链接> \
  --ab-baseline-seconds 3 --seconds 8 --ab-quiet-seconds 3 \
  --output /tmp/hls-ab.json

# 5) 开/停对照（shell 命令行变体）
tmp/scoped-audio-sampler/gmgn-scoped-audio \
  --pid <真实 App pid> --ab \
  --on-cmd '<启动真实播放>' --off-cmd '<停止真实播放>' \
  --ab-baseline-seconds 3 --seconds 8 --ab-quiet-seconds 3

# 6) 单元/集成测试
python3 -m unittest tools.tests.test_process_audio_sampler -v
```

退出码：`0` 达到预期；`2` 参数/目标错误；`3` tap 初始化有界超时；`4` 需要声音但未采到
或开/停对照不成立；`5` 权限被拒；`6` 后端不可用；`7` `--self-test` 失败。

## 4. 主代理验收流程

1. 启动真实隔离 App 并设置 `GMGN_E2E_DATA_ROOT`，拿到电视物件 id 与用户原始页面链接。
2. 先跑 `--self-check`，确认 `globalTapRefused=true`、目标进程对象存在。
3. 跑 `--ab --host-root ... --object-id ... --hls-url ...`。
   - `HLS_OUTPUT_CONFIRMED`（退出码 0）才是“真实 HLS 输出”实证；
   - `HLS_OUTPUT_NOT_CONFIRMED`（退出码 4）必须按未通过计，不得用 `tapAttached` 或
     音轨存在替代。
4. 跑一次负对照，例如同一目标不切播放、或 `--on-cmd/--off-cmd` 都设为 `true`，确认返回
   `HLS_OUTPUT_NOT_CONFIRMED`，证明判据不是恒真。
5. 证据落盘：`--output` 的 JSON、进程 PID、命令行、`--self-check` 输出。

## 5. DSH 内已跑的验证与证据

| 项 | 命令 | 结果 | 证据 |
|---|---|---|---|
| 编译 | `bash tools/build-scoped-audio-sampler.sh --print-path` | exit 0，产物 + 带 `NSAudioCaptureUsageDescription` 的 ad-hoc 签名 `.app` | 见 §3 |
| 自测 | `... --self-test` | `SELF-TEST PASS`：440 Hz 采到非静音、静音片峰值近 0、只绑定目标 PID、无全系统 tap | `evidence/scoped-process-audio/self-test.txt` |
| 能力自检 | `... --self-check` | `globalTapRefused=true`、`coreAudioProcessTapAvailable=true`、目标进程对象 `278` | `evidence/scoped-process-audio/self-check.json` |
| 真实 App 播放期采样 | `... --pid 53973 --seconds 10` | `peak=0.7346`、`rms=0.1175`、`buffers=939`、`scopedProcesses=[53973]`、`globalTap=false` | `evidence/scoped-process-audio/live-app-playing-sample.json` |
| 真实 App 空闲采样 | `... --bundle-id ai.gmgn.radio.e2e --seconds 6` | `rms=0`、`peak=0`、`buffers=561`、`scopedProcesses=[59080]`（空闲时如实为静音，不冒充） | `evidence/scoped-process-audio/live-app-idle-sample.json` |
| 开/停对照（真） | `... --ab --off-cmd 'kill -STOP' --on-cmd 'kill -CONT'` | `contrast=28214`、`HLS_OUTPUT_CONFIRMED`、exit 0 | `evidence/scoped-process-audio/ab-positive.json` |
| 开/停对照（负） | `... --ab --off-cmd true --on-cmd true` | `contrast=1.001`、`HLS_OUTPUT_NOT_CONFIRMED`、exit 4 | `evidence/scoped-process-audio/ab-negative.json` |
| 无音频进程对象 | `--pid <sleep> --expect audible` | `NO_SIGNAL`、`tapBuffers=0`、exit 4，**不挂起** | `evidence/scoped-process-audio/no-process-object.json` |
| 测试 | `python3 -m unittest tools.tests.test_process_audio_sampler -v` | 6 tests OK，含 fake 主机邮箱驱动真实 `play_screen`/`stop_screen` | `evidence/scoped-process-audio/unittest.log` |

## 6. 明确不通过 / 边界（不冒充）

1. 本工具只证明“**指定目标进程在播放窗口有真实非静音输出**”；它不解析视频内容，也不判断
   该声音是不是某条特定 HLS 流。要把它归因到某条 HLS，必须在**播放该链接期间**运行，并用
   生产 `playback_state` 佐证。
2. `file PCM`、直链 MP4、音轨存在、`tapAttached`、`hasAudio` 都不是 HLS 输出通过。
3. `--ab` 的 `on-cmd`/`off-cmd` 由调用方提供；本工具不回显子进程输出，避免泄漏签名地址。
4. 进程 tap 抓的是“目标进程送往输出设备的混音”，即使系统物理音量被调低也能采到；这不等于
   “扬声器可听”。验收口径是“App 真的在输出声音”。
5. ScreenCaptureKit 备选后端已实现；在目标未渲染声音时它照样交付零值缓冲，不能据此判通过。
6. 本轮**未**改生产代码、**未**改 `e2e-real-app.py` 判据、**未** commit / push / reset，
   **未**碰 Keychain 与已装 `/Applications` App。

## 7. 文件清单

- `tools/probe-scoped-process-audio.swift`：采样器；Core Audio tap 为主、SCK 为备，支持 `--ab` 与 `--self-test`。
- `tools/build-scoped-audio-sampler.sh`：离线编译 + 可选带 `NSAudioCaptureUsageDescription` 的 `.app`。
- `tools/tests/test_process_audio_sampler.py`：6 条端到端门禁（真实 `afplay`、fake 主机邮箱）。
- `docs/plans/evidence/scoped-process-audio/`：本轮证据 JSON / 日志。
