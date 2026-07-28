# gmgn radio 第一版实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 Apple Silicon 与 macOS 26 上完成 gmgn radio 的第一条原生纵向闭环：桌面呼吸球、Metal GFX、本地音乐、LiveKit 实时语音、OpenAI 兼容模型、ElevenLabs DJ 声线和自主节目决策。

**Architecture:** macOS 客户端使用 Swift、AppKit、SwiftUI、Metal 与 AVAudioEngine。实时语音由 LiveKit Swift SDK 接入自有 LiveKit Agents 服务，服务端通过 OpenAI 兼容接口调用模型，并通过 ElevenLabs 生成 DJ 声音。DJ 的状态、工具合同和记忆归 gmgn radio 所有，模型、语音和音乐来源都放在可替换协议之后。

**Tech Stack:** macOS 26、Xcode 26.6、Swift 6.3、AppKit、SwiftUI、MetalKit、AVFAudio、Accelerate、MusicKit、SQLite3、LiveKit Swift SDK、LiveKit Agents Python、OpenAI 兼容 API、ElevenLabs TTS、Python 3.12、uv、XcodeGen。

---

## 0. 已确认决策

- 产品显示名为 `gmgn radio`，Bundle ID 暂定 `ai.gmgn.radio`。
- 首版只支持 Apple Silicon 与 macOS 26。
- 官网签名与公证分发优先，暂不以 Mac App Store 沙盒为设计前提。
- 呼吸球、窗口、音频和 GFX 使用原生实现。
- LiveKit 负责实时音频传输、打断、会话与 Agent 运行时。
- 模型接口保持 OpenAI 兼容，通过服务端 `base_url`、`model` 和密钥配置切换。
- ElevenLabs 只负责 DJ 声线与 TTS；DJ 自主性、工具、记忆和节目策略留在 gmgn radio。
- OpenAI Realtime 保留为可选适配器；默认纵向闭环先使用 `STT / OpenAI-compatible LLM / ElevenLabs TTS` 流水线，方便控制 DJ 声线。
- 本地音乐是第一条高质量播放路径，能够提供精确 PCM、压低音乐和音画同步。
- Apple Music 先做独立可行性验证。MusicKit 不提供受保护音频的 PCM，也没有公开的每应用音量控制合同；验证不通过时，不让它影响本地音乐的招牌体验。

## 1. 仓库布局

```text
gmgnradio/
├── apps/
│   └── macos/
│       ├── project.yml
│       ├── Resources/
│       ├── Sources/GMGNRadio/
│       ├── Tests/GMGNRadioTests/
│       └── UITests/GMGNRadioUITests/
├── services/
│   └── agent/
│       ├── pyproject.toml
│       ├── src/gmgn_agent/
│       └── tests/
├── contracts/
│   ├── dj-tools.schema.json
│   ├── dj-event.schema.json
│   └── persona.schema.json
├── scripts/
├── docs/plans/
├── .env.example
├── .gitignore
└── Makefile
```

---

### Task 1: 建立可重复生成的 macOS 工程

**Files:**
- Create: `.gitignore`
- Create: `Makefile`
- Create: `apps/macos/project.yml`
- Create: `apps/macos/Resources/Info.plist`
- Create: `apps/macos/Resources/GMGNRadio.entitlements`
- Create: `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/AppSmokeTests.swift`

**Step 1: 写工程冒烟测试**

```swift
import Testing
@testable import GMGNRadio

@Test
func productIdentityIsStable() {
    #expect(ProductIdentity.displayName == "gmgn radio")
    #expect(ProductIdentity.bundleIdentifier == "ai.gmgn.radio")
}
```

**Step 2: 写最小应用入口**

```swift
import SwiftUI

enum ProductIdentity {
    static let displayName = "gmgn radio"
    static let bundleIdentifier = "ai.gmgn.radio"
}

@main
struct GMGNRadioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            Text(ProductIdentity.displayName)
                .frame(width: 420, height: 280)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {}
```

**Step 3: 配置 XcodeGen**

`apps/macos/project.yml` 至少包含：

```yaml
name: GMGNRadio
options:
  deploymentTarget:
    macOS: "26.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    MACOSX_DEPLOYMENT_TARGET: "26.0"
targets:
  GMGNRadio:
    type: application
    platform: macOS
    sources:
      - Sources/GMGNRadio
    resources:
      - Resources
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: ai.gmgn.radio
        PRODUCT_NAME: gmgn radio
        INFOPLIST_FILE: Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: Resources/GMGNRadio.entitlements
        ENABLE_HARDENED_RUNTIME: YES
  GMGNRadioTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - Tests/GMGNRadioTests
    dependencies:
      - target: GMGNRadio
schemes:
  GMGNRadio:
    build:
      targets:
        GMGNRadio: all
        GMGNRadioTests: [test]
    test:
      targets:
        - GMGNRadioTests
```

**Step 4: 生成工程**

Run:

```bash
command -v xcodegen >/dev/null || brew install xcodegen
cd apps/macos
xcodegen generate
```

Expected: 生成 `apps/macos/GMGNRadio.xcodeproj`。

**Step 5: 运行测试**

Run:

```bash
xcodebuild test \
  -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio \
  -destination 'platform=macOS'
```

Expected: `TEST SUCCEEDED`。

**Step 6: 提交**

```bash
git add .gitignore Makefile apps/macos
git commit -m "build: bootstrap native macOS app"
```

---

### Task 2: 固化 DJ、呼吸球和节目状态合同

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/Domain/DJState.swift`
- Create: `apps/macos/Sources/GMGNRadio/Domain/OrbState.swift`
- Create: `apps/macos/Sources/GMGNRadio/Domain/ProgramDecision.swift`
- Create: `apps/macos/Sources/GMGNRadio/Domain/PlaybackContext.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/Domain/DJStateTests.swift`
- Create: `contracts/dj-event.schema.json`
- Create: `contracts/dj-tools.schema.json`

**Step 1: 写状态转换失败测试**

```swift
@Test
func speakingThenMusicReturnsToPlaying() {
    var machine = DJStateMachine(initial: .playing)
    machine.handle(.agentSpeechStarted)
    #expect(machine.state == .speaking)
    machine.handle(.agentSpeechFinished)
    #expect(machine.state == .playing)
}
```

**Step 2: 实现最小状态机**

状态必须覆盖：

```swift
enum DJState: String, Codable, Sendable {
    case dormant
    case idle
    case listening
    case thinking
    case speaking
    case playing
    case reconnecting
    case privacyOff
    case failed
}
```

事件必须覆盖唤醒、开始/结束聆听、思考、说话、播放、断线和隐私关闭。

**Step 3: 建立模型工具合同**

首批工具：

- `search_music`
- `replace_upcoming_queue`
- `play_track`
- `skip_track`
- `set_music_gain`
- `remember_preference`
- `forget_current_context`
- `set_conversation_mode`
- `enter_immersive_visuals`
- `end_program`

每个工具都必须有 JSON Schema、稳定名称、明确错误结果和幂等键。

**Step 4: 运行测试**

Run:

```bash
xcodebuild test -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio -destination 'platform=macOS' \
  -only-testing:GMGNRadioTests/DJStateTests
```

Expected: `TEST SUCCEEDED`。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/Domain \
  apps/macos/Tests/GMGNRadioTests/Domain contracts
git commit -m "feat: define DJ state and tool contracts"
```

---

### Task 3: 建立透明呼吸球窗口

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/DesktopPresence/OrbPanel.swift`
- Create: `apps/macos/Sources/GMGNRadio/DesktopPresence/OrbWindowController.swift`
- Create: `apps/macos/Sources/GMGNRadio/DesktopPresence/WindowPlacement.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/DesktopPresence/WindowPlacementTests.swift`

**Step 1: 写窗口位置失败测试**

覆盖右下角默认位置、Dock 避让、多显示器记忆与边缘吸附。

```swift
@Test
func snapsToVisibleFrameBottomRight() {
    let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
    let result = WindowPlacement.defaultFrame(
        size: CGSize(width: 168, height: 168),
        visibleFrame: visible,
        margin: 24
    )
    #expect(result.maxX == 1416)
    #expect(result.minY == 64)
}
```

**Step 2: 实现 `OrbPanel`**

要求：

- `.borderless`
- 透明背景
- 不显示标题栏和阴影
- 能浮在普通窗口上
- `.canJoinAllSpaces` 与 `.fullScreenAuxiliary`
- 不进入常规窗口循环
- 空闲时鼠标穿透，靠近或按修饰键时恢复交互

**Step 3: 在 AppDelegate 启动窗口**

应用启动后只显示呼吸球；设置窗口按菜单栏命令打开。

**Step 4: 运行测试并手工检查**

Run:

```bash
xcodebuild test -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio -destination 'platform=macOS' \
  -only-testing:GMGNRadioTests/WindowPlacementTests
```

Manual:

- 切换 Space；
- 打开全屏应用；
- 连接第二台显示器；
- 拖动并重启应用。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/DesktopPresence \
  apps/macos/Tests/GMGNRadioTests/DesktopPresence
git commit -m "feat: add persistent orb window"
```

---

### Task 4: 建立 Metal 呼吸球渲染器

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/OrbMetalView.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/OrbRenderer.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/OrbUniforms.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/Shaders/Orb.metal`
- Create: `apps/macos/Tests/GMGNRadioTests/VisualEngine/OrbUniformTests.swift`

**Step 1: 写 uniform 映射失败测试**

```swift
@Test(arguments: [
    (DJState.idle, Float(0.18)),
    (DJState.listening, Float(0.72)),
    (DJState.speaking, Float(0.90)),
])
func energyMatchesState(state: DJState, expected: Float) {
    #expect(OrbUniforms.forState(state).energy == expected)
}
```

**Step 2: 实现渲染循环**

- `MTKView` 使用透明色；
- 根据屏幕能力选择刷新率；
- 待机降到 15 FPS；
- 监听、说话和音乐状态提升到 60/120 FPS；
- 所有时间统一使用单调时钟；
- SwiftUI 不参与逐帧状态更新。

**Step 3: 实现第一版材质**

`Orb.metal` 至少包含：

- 球体 SDF；
- 多层 Fresnel 光晕；
- 低频形变；
- 内部流体噪声；
- 粒子边缘；
- 颜色与亮度的平滑插值；
- 预乘 Alpha 输出。

**Step 4: 验证**

Run:

```bash
xcodebuild test -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio -destination 'platform=macOS' \
  -only-testing:GMGNRadioTests/OrbUniformTests
```

Manual acceptance:

- 透明边缘没有黑边；
- 60/120 FPS 下没有明显抖动；
- 待机时风扇与功耗不持续上升；
- 缩放屏幕与多显示器切换后像素密度正确。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/VisualEngine \
  apps/macos/Tests/GMGNRadioTests/VisualEngine
git commit -m "feat: render native Metal breathing orb"
```

---

### Task 5: 完成呼吸球状态动作与全屏 GFX 转场

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/OrbMotionModel.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/ImmersiveSceneController.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/Shaders/Immersive.metal`
- Create: `apps/macos/Tests/GMGNRadioTests/VisualEngine/OrbMotionModelTests.swift`

**Step 1: 为每个状态写确定性动作测试**

固定随机种子与时间输入，测试待机、唤醒、聆听、理解、说话、播放和隐私关闭的参数范围。

**Step 2: 实现可打断状态过渡**

任何过渡都必须支持中途反向。例如用户在 DJ 说话时开口，画面应立即从 `speaking` 转向 `listening`，不能等待动画结束。

**Step 3: 实现全屏展开**

- 以呼吸球当前中心与颜色为起点；
- 先扩大光晕，再溶解球体边界；
- 全屏场景接管同一份音频特征；
- 退出时按反向时间线凝聚；
- 多显示器默认只占当前球体所在显示器。

**Step 4: 录制视觉基准**

在 `docs/design/visual-baselines/` 保存每种状态的基准截图和 10 秒录屏，后续改动必须对照。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/VisualEngine \
  apps/macos/Tests/GMGNRadioTests/VisualEngine \
  docs/design/visual-baselines
git commit -m "feat: add orb motion and immersive transition"
```

---

### Task 6: 建立本地音乐播放图

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/AudioEngine/AudioGraphController.swift`
- Create: `apps/macos/Sources/GMGNRadio/AudioEngine/LocalMusicPlayer.swift`
- Create: `apps/macos/Sources/GMGNRadio/AudioEngine/AudioDeviceMonitor.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/AudioEngine/AudioGraphTests.swift`
- Create: `apps/macos/Tests/Fixtures/audio/sine-440hz.wav`

**Step 1: 写播放状态失败测试**

测试加载、播放、暂停、跳过、结束、设备切换和恢复。

**Step 2: 实现音频图**

```text
LocalMusicPlayerNode ─┐
                     ├─ MusicMixer ─┐
LiveKitRemoteNode ───┘              ├─ MainMixer ─ Output
                                    │
Effects / limiter ──────────────────┘
```

音乐与 DJ 语音保留独立增益控制。所有图修改必须在安全队列执行，实时回调不得分配内存或访问数据库。

**Step 3: 添加离线渲染测试**

使用测试 WAV 渲染 2 秒，断言：

- 输出非静音；
- 峰值低于削波阈值；
- 暂停后输出静音；
- 恢复时没有不连续的大幅跳变。

**Step 4: 运行测试**

```bash
xcodebuild test -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio -destination 'platform=macOS' \
  -only-testing:GMGNRadioTests/AudioGraphTests
```

Expected: `TEST SUCCEEDED`。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/AudioEngine \
  apps/macos/Tests/GMGNRadioTests/AudioEngine \
  apps/macos/Tests/Fixtures/audio
git commit -m "feat: add local music audio graph"
```

---

### Task 7: 将音频特征同步到 Metal

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/AudioEngine/AudioAnalyzer.swift`
- Create: `apps/macos/Sources/GMGNRadio/AudioEngine/AudioFeatureFrame.swift`
- Create: `apps/macos/Sources/GMGNRadio/AudioEngine/LockFreeFeatureBuffer.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/AudioEngine/AudioAnalyzerTests.swift`

**Step 1: 写正弦波识别失败测试**

```swift
@Test
func detectsDominant440HzBand() throws {
    let samples = TestSignal.sine(frequency: 440, sampleRate: 48_000, count: 4_096)
    let frame = AudioAnalyzer(sampleRate: 48_000).analyze(samples)
    #expect(frame.dominantFrequency.isApproximatelyEqual(to: 440, tolerance: 12))
}
```

**Step 2: 使用 Accelerate/vDSP 实现分析**

输出：

- RMS；
- 峰值；
- 32 个对数频段；
- 频谱质心；
- 低频冲击；
- onset；
- 粗略 beat pulse；
- 音频主机时间戳。

**Step 3: 建立无锁交换**

音频线程只写固定大小结构；Metal 线程读取最近完成帧。过期帧直接丢弃，不能阻塞音频。

**Step 4: 验证同步**

播放点击音轨并录制屏幕，目标是音频到视觉偏差小于 30 毫秒。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/AudioEngine \
  apps/macos/Tests/GMGNRadioTests/AudioEngine
git commit -m "feat: drive Metal visuals from audio features"
```

---

### Task 8: 实现 DJ 语音压低音乐与打断

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/AudioEngine/DuckingEnvelope.swift`
- Create: `apps/macos/Sources/GMGNRadio/AudioEngine/InterruptionCoordinator.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/AudioEngine/DuckingEnvelopeTests.swift`

**Step 1: 写包络测试**

覆盖：

- 120–180 毫秒下压；
- DJ 语音期间保持目标增益；
- 350–600 毫秒恢复；
- 用户打断 DJ 时立即清空未播放语音；
- 连续短句不会造成音量抽动。

**Step 2: 实现样本时间驱动的包络**

包络由音频时钟推进，不使用 UI Timer。

**Step 3: 接入状态机**

- 远端 DJ 音频开始：进入 `speaking` 并下压音乐；
- 用户语音开始：停止远端语音、通知 LiveKit Agent 中断、切到 `listening`；
- DJ 音频结束：根据当前节目状态恢复音乐。

**Step 4: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/AudioEngine \
  apps/macos/Tests/GMGNRadioTests/AudioEngine
git commit -m "feat: add sample-timed DJ ducking and interruption"
```

---

### Task 9: 接入 LiveKit Swift SDK

**Files:**
- Modify: `apps/macos/project.yml`
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/LiveKit/LiveKitRoomClient.swift`
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/LiveKit/LiveKitTokenProvider.swift`
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/LiveKit/RemoteAudioBridge.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/VoiceSession/LiveKitRoomClientTests.swift`

**Step 1: 添加固定版本的 SPM 依赖**

执行时查看 LiveKit Swift SDK 最新稳定版本，固定精确版本并提交 `Package.resolved`，不跟随 `main`。

**Step 2: 写连接状态测试**

使用假 TokenProvider 与假 RoomAdapter，测试：

- 请求 token；
- 连接；
- 订阅 agent 音轨；
- 断线重连；
- token 失效；
- 用户主动结束。

**Step 3: 实现远端 PCM 桥接**

使用 LiveKit `AudioManager` 的远端 AudioRenderer 获取 PCM。禁止让 WebRTC 音频直接绕过 gmgn radio 的混音图：

```swift
AudioManager.shared.add(remoteAudioRenderer: remoteAudioBridge)
```

`RemoteAudioBridge` 把固定格式 PCM 写入 `LiveKitRemoteNode`，同时提供语音活动事件给状态机。

**Step 4: 手工验证**

- 麦克风与远端音频均可选择设备；
- 蓝牙耳机切换后恢复；
- LiveKit 会话断开时本地音乐继续；
- LiveKit 语音可以进入压低音乐与 GFX 分析路径。

**Step 5: 提交**

```bash
git add apps/macos/project.yml apps/macos/Sources/GMGNRadio/VoiceSession \
  apps/macos/Tests/GMGNRadioTests/VoiceSession apps/macos/Package.resolved
git commit -m "feat: connect native client to LiveKit voice sessions"
```

---

### Task 10: 建立 LiveKit Agents 服务

**Files:**
- Create: `services/agent/pyproject.toml`
- Create: `services/agent/src/gmgn_agent/main.py`
- Create: `services/agent/src/gmgn_agent/config.py`
- Create: `services/agent/src/gmgn_agent/session.py`
- Create: `services/agent/src/gmgn_agent/token_api.py`
- Create: `services/agent/tests/test_config.py`
- Create: `.env.example`

**Step 1: 初始化 Python 服务**

Run:

```bash
cd services/agent
uv init --package
uv add "livekit-agents[openai,elevenlabs]" fastapi uvicorn pydantic-settings
uv add --dev pytest pytest-asyncio
```

**Step 2: 写配置失败测试**

```python
def test_openai_compatible_endpoint_is_required(settings_factory):
    settings = settings_factory(
        llm_base_url="https://models.example.com/v1",
        llm_model="dj-model",
    )
    assert settings.llm_base_url.endswith("/v1")
    assert settings.llm_model == "dj-model"
```

配置字段：

- `LIVEKIT_URL`
- `LIVEKIT_API_KEY`
- `LIVEKIT_API_SECRET`
- `LLM_BASE_URL`
- `LLM_API_KEY`
- `LLM_MODEL`
- `ELEVENLABS_API_KEY`
- `ELEVENLABS_VOICE_ID`

密钥不得下发到 macOS 客户端。

**Step 3: 创建 AgentSession**

默认使用：

```python
session = AgentSession(
    llm=openai.LLM(
        model=settings.llm_model,
        base_url=settings.llm_base_url,
        api_key=settings.llm_api_key,
    ),
    tts=elevenlabs.TTS(
        voice_id=settings.elevenlabs_voice_id,
    ),
    # STT、VAD 与 turn detection 在下一步固定。
)
```

ElevenLabs 模型名保持配置化，不使用已移除的 v1 TTS 模型，不使用已废弃的 `api-global-preview.elevenlabs.io`。

**Step 4: 添加短期 LiveKit token 接口**

FastAPI 只向已授权客户端签发短期房间 token。第一阶段允许本地开发身份，生产前必须替换成账号鉴权。

**Step 5: 运行测试**

```bash
cd services/agent
uv run pytest -q
```

Expected: 全部通过。

**Step 6: 提交**

```bash
git add services/agent .env.example
git commit -m "feat: add LiveKit agent service with configurable providers"
```

---

### Task 11: 实现 OpenAI 兼容模型工具循环

**Files:**
- Create: `services/agent/src/gmgn_agent/contracts.py`
- Create: `services/agent/src/gmgn_agent/tools.py`
- Create: `services/agent/src/gmgn_agent/prompts.py`
- Create: `services/agent/tests/test_tools.py`
- Modify: `contracts/dj-tools.schema.json`

**Step 1: 为每个工具写合同测试**

测试必须拒绝：

- 未知工具；
- 缺失必填参数；
- 非法音量；
- 无幂等键的播放修改；
- 超过队列长度上限的替换请求。

**Step 2: 实现客户端工具调用**

服务端只决定工具名称与参数；本地播放、音乐搜索、设置和记忆写入由 macOS 客户端执行。工具结果按稳定 JSON 结构返回 AgentSession。

**Step 3: 写 DJ 基础提示词**

必须明确：

- DJ 拥有自主性；
- 用户设置表达偏好；
- 深夜场景减少废话；
- 不要逐条解释自己的决策；
- 无需每次回应都调用工具；
- 选歌失败时保留气氛并换候选；
- 不把模型供应商、工具名或内部状态说给用户。

**Step 4: 添加 OpenAI Realtime 可选适配器**

建立 `VOICE_PIPELINE_MODE=pipeline|openai_realtime`。Realtime 模型名由服务端配置，不写死在客户端。Realtime 模式仍通过 LiveKit 连接，并复用相同工具合同。

**Step 5: 运行测试并提交**

```bash
cd services/agent
uv run pytest -q
cd ../..
git add services/agent contracts
git commit -m "feat: add provider-neutral DJ tool loop"
```

---

### Task 12: 麦克风权限、全局快捷键与陪伴时段

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/MicrophonePermission.swift`
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/GlobalTalkShortcut.swift`
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/ConversationModeController.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/VoiceSession/ConversationModeTests.swift`

**Step 1: 写模式测试**

覆盖：

- 待机只运行本地唤醒检测；
- 快捷键按下进入聆听，释放后提交；
- 单轮结束回待机；
- 陪伴时段保持连接；
- “你先别听了”立即关闭远端麦克风发送。

**Step 2: 实现权限状态**

权限未授权时仍允许本地音乐播放。靠近呼吸球后显示修复入口，禁止无限弹系统权限框。

**Step 3: 实现全局快捷键**

第一版默认 `⌥ Space`，允许在设置里修改。快捷键冲突时给出可恢复提示。

**Step 4: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/VoiceSession \
  apps/macos/Tests/GMGNRadioTests/VoiceSession
git commit -m "feat: add microphone modes and global talk shortcut"
```

---

### Task 13: 本地唤醒词

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/WakeWord/WakeWordDetector.swift`
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/WakeWord/SoundAnalysisWakeWordDetector.swift`
- Create: `apps/macos/Resources/Models/GMGNWakeWord.mlmodel`
- Create: `apps/macos/Tests/GMGNRadioTests/VoiceSession/WakeWordDetectorTests.swift`
- Create: `apps/macos/Tests/Fixtures/wake-word/`

**Step 1: 定义可替换协议**

```swift
protocol WakeWordDetector: Sendable {
    func start() async throws
    func stop() async
    var detections: AsyncStream<WakeWordDetection> { get }
}
```

**Step 2: 准备模型评测集**

至少包含：

- 20 条不同说法与距离的正样本；
- 100 条音乐、环境声和相似词负样本；
- 内置扬声器、耳机和外接麦克风；
- 中英文混合环境。

**Step 3: 使用 SoundAnalysis/Core ML 实现本地检测**

原始待机音频不离开设备。检测命中后才开启 LiveKit 会话。模型缺失或置信度过低时，快捷键必须始终可用。

**Step 4: 验收**

- 安静环境漏检率满足内部阈值；
- 音乐播放时误唤醒可接受；
- 待机功耗符合长期常驻要求；
- 屏幕锁定与睡眠恢复后能重新工作。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/VoiceSession/WakeWord \
  apps/macos/Resources/Models \
  apps/macos/Tests/GMGNRadioTests/VoiceSession \
  apps/macos/Tests/Fixtures/wake-word
git commit -m "feat: add on-device wake word detection"
```

---

### Task 14: 本地音乐库与搜索

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/MusicSources/MusicSource.swift`
- Create: `apps/macos/Sources/GMGNRadio/MusicSources/Local/LocalLibraryScanner.swift`
- Create: `apps/macos/Sources/GMGNRadio/MusicSources/Local/LocalMusicSource.swift`
- Create: `apps/macos/Sources/GMGNRadio/Persistence/SQLiteDatabase.swift`
- Create: `apps/macos/Sources/GMGNRadio/Persistence/Migrations/001_initial.sql`
- Create: `apps/macos/Tests/GMGNRadioTests/MusicSources/LocalLibraryTests.swift`

**Step 1: 写临时音乐库测试**

测试：

- 扫描支持格式；
- 跳过损坏文件；
- 读取标题、艺人、专辑、时长和封面；
- 重复文件去重；
- 文件移动后重新关联；
- 查询“安静但不伤感”的候选标签。

**Step 2: 实现 SQLite 迁移**

表：

- `tracks`
- `track_locations`
- `play_history`
- `preferences`
- `personas`
- `session_memories`
- `schema_migrations`

**Step 3: 实现增量扫描**

首次扫描后台运行并持续报告进度。之后按目录修改时间与文件指纹增量更新，不能每次启动全盘重扫。

**Step 4: 实现统一搜索结果**

`MusicCandidate` 必须带来源、可播放性、匹配理由和稳定 ID，方便 DJ 混合多个来源排序。

**Step 5: 运行测试并提交**

```bash
xcodebuild test -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio -destination 'platform=macOS' \
  -only-testing:GMGNRadioTests/LocalLibraryTests
git add apps/macos/Sources/GMGNRadio/MusicSources \
  apps/macos/Sources/GMGNRadio/Persistence \
  apps/macos/Tests/GMGNRadioTests/MusicSources
git commit -m "feat: index and search local music"
```

---

### Task 15: DJ 自主节目规划与本地记忆

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/DJCore/AutonomyPolicy.swift`
- Create: `apps/macos/Sources/GMGNRadio/DJCore/ProgramPlanner.swift`
- Create: `apps/macos/Sources/GMGNRadio/DJCore/MemoryPolicy.swift`
- Create: `apps/macos/Sources/GMGNRadio/DJCore/ToolExecutor.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/DJCore/ProgramPlannerTests.swift`

**Step 1: 写节目连续性测试**

覆盖：

- 用户说“太冷”时只调整后续候选；
- 连续跳过提高修正幅度；
- 用户说“少说话”后 DJ 保持沉默倾向；
- 一次偶然跳过不写入长期厌恶；
- “别记住这个”阻止当前会话写入长期记忆；
- 工具重试不重复播放或重复写偏好。

**Step 2: 实现本地权威状态**

模型提出决策，本地 `ToolExecutor` 验证并执行。当前歌曲、队列、音量、隐私与记忆写入结果都以客户端状态为准。

**Step 3: 实现短期与长期记忆分层**

- 当前节目上下文：内存；
- 会话摘要：本地 SQLite；
- 长期偏好：结构化、可查看、可编辑、可删除；
- 原始音频：默认不保存。

**Step 4: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/DJCore \
  apps/macos/Tests/GMGNRadioTests/DJCore
git commit -m "feat: add autonomous program planning and memory"
```

---

### Task 16: Apple Music 可行性闸门

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/MusicSources/AppleMusic/AppleMusicSource.swift`
- Create: `apps/macos/Sources/GMGNRadio/MusicSources/AppleMusic/AppleMusicPlaybackProbe.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/MusicSources/AppleMusicSourceTests.swift`
- Create: `docs/spikes/apple-music-playback.md`

**Step 1: 核对授权**

实现 `MusicAuthorization.request()`，并在 `Info.plist` 添加 `NSAppleMusicUsageDescription`。检查订阅能力后才展示连接成功。

**Step 2: 验证搜索与队列**

使用 `MusicCatalogSearchRequest` 与 `ApplicationMusicPlayer` 验证：

- 搜索；
- 设置队列；
- 播放、暂停、跳过；
- 当前播放时间；
- crossfade；
- 后台与菜单栏运行。

**Step 3: 验证体验关键能力**

必须实测并记录：

- 是否能得到 PCM；
- 是否能按应用精确控制增益；
- DJ 语音与 Apple Music 是否能可靠混音；
- 是否能在不申请屏幕录制权限的前提下驱动精确 GFX；
- 设备切换与睡眠恢复。

**Step 4: 作出闸门结论**

满足音画与混音要求：纳入第一版。

不满足：保留搜索、推荐和播放控制实验，不进入招牌演示；第一版的完整 DJ 体验继续以本地音乐为准。禁止使用私有 API。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/MusicSources/AppleMusic \
  apps/macos/Tests/GMGNRadioTests/MusicSources \
  apps/macos/Resources/Info.plist docs/spikes/apple-music-playback.md
git commit -m "spike: evaluate Apple Music playback constraints"
```

---

### Task 17: SwiftUI 控制中心

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/ControlCenter/ControlCenterView.swift`
- Create: `apps/macos/Sources/GMGNRadio/ControlCenter/PersonaEditorView.swift`
- Create: `apps/macos/Sources/GMGNRadio/ControlCenter/AudioSettingsView.swift`
- Create: `apps/macos/Sources/GMGNRadio/ControlCenter/PrivacySettingsView.swift`
- Create: `apps/macos/Sources/GMGNRadio/ControlCenter/MemorySettingsView.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/ControlCenter/SettingsModelTests.swift`

**Step 1: 建立设置模型**

首版设置：

- 更健谈 / 更安静；
- 熟悉歌曲 / 探索新歌；
- 温柔陪伴 / 有观点的 DJ；
- 唤醒词与快捷键；
- 默认输入输出设备；
- 陪伴时段；
- ElevenLabs 声线；
- 人格提示词；
- 长期记忆查看与清除；
- 语音情绪特征开关。

**Step 2: 实现窗口**

设置窗口遵循 macOS 原生布局。呼吸球与 GFX 不复用设置界面的视觉控件。

**Step 3: 为危险操作增加确认**

只有清空全部长期记忆需要确认；普通偏好变化即时生效。

**Step 4: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/ControlCenter \
  apps/macos/Tests/GMGNRadioTests/ControlCenter
git commit -m "feat: add native control center"
```

---

### Task 18: 诊断、恢复与隐私保护

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/Diagnostics/DiagnosticsStore.swift`
- Create: `apps/macos/Sources/GMGNRadio/Diagnostics/RecoveryCoordinator.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/Diagnostics/RecoveryTests.swift`
- Create: `services/agent/tests/test_recovery.py`

**Step 1: 写故障矩阵测试**

覆盖：

- LiveKit 断线；
- ElevenLabs TTS 超时；
- LLM 429/5xx；
- 本地文件消失；
- 音频设备断开；
- Metal drawable 暂时不可用；
- 麦克风权限被撤回；
- 睡眠后恢复。

**Step 2: 实现恢复优先级**

音乐优先继续。DJ 语音失败时保持安静；恢复后不补说过期串场。模型工具调用必须使用幂等键。

**Step 3: 限制日志**

日志允许：

- 请求 ID；
- 会话 ID；
- 状态转换；
- 延迟；
- 错误码；
- 音频设备与采样率。

日志禁止：

- API key；
- 原始麦克风音频；
- 完整提示词；
- 完整私人对话；
- 用户音乐目录绝对路径。

**Step 4: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/Diagnostics \
  apps/macos/Tests/GMGNRadioTests/Diagnostics services/agent/tests
git commit -m "feat: add privacy-safe diagnostics and recovery"
```

---

### Task 19: 端到端深夜电台验收

**Files:**
- Create: `scripts/run-local-stack.sh`
- Create: `scripts/verify-macos.sh`
- Create: `docs/qa/deep-night-radio-checklist.md`
- Create: `docs/qa/performance-budget.md`

**Step 1: 建立本地运行入口**

`scripts/run-local-stack.sh` 启动 LiveKit、Agent 服务和 token API，并打印 macOS 客户端所需的本地地址。脚本不得打印任何密钥。

**Step 2: 建立自动验证**

`scripts/verify-macos.sh` 依次运行：

```bash
xcodegen generate
xcodebuild test -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio -destination 'platform=macOS'
cd services/agent
uv run pytest -q
```

**Step 3: 执行招牌流程**

场景：

1. 启动后只出现呼吸球；
2. 用户按 `⌥ Space` 或说唤醒词；
3. 用户说“今天有点累，想听安静一点，但别太伤感”；
4. DJ 简短回应；
5. 5 秒内开始本地音乐；
6. 呼吸球按音乐响应；
7. DJ 在合适转场自主说话；
8. 用户打断，DJ 立即停止；
9. 用户说“少说话”，后续主动程度下降；
10. 用户说“晚安”，音乐淡出并结束节目。

**Step 4: 测量性能**

目标：

- 唤醒视觉反馈 < 100 ms；
- 正常网络下首段语音感知等待尽量 < 800 ms；
- 本地音乐启动 < 5 s；
- 音频到视觉偏差 < 30 ms；
- 普通屏幕稳定 60 FPS，高刷屏按能力提升；
- 待机显著降低 GPU 与音频分析负载；
- 连续运行 4 小时无持续内存增长。

**Step 5: 公证前检查**

- Release 签名；
- Hardened Runtime；
- 麦克风说明；
- MusicKit 说明；
- 网络权限；
- 崩溃日志脱敏；
- `notarytool` 上传与 stapling；
- 干净机器安装验证。

**Step 6: 提交**

```bash
git add scripts docs/qa
git commit -m "test: add deep-night radio acceptance suite"
```

---

## 外部文档与版本检查

- LiveKit Agents 支持通过 `base_url` 接入 OpenAI 兼容模型：  
  https://docs.livekit.io/agents/models/llm/openai-compatible-llms/
- LiveKit Swift SDK 支持 macOS，并能通过远端 AudioRenderer 获取 PCM：  
  https://docs.livekit.io/reference/client-sdk-swift/documentation/livekit/audiomanager/
- LiveKit 可以让 OpenAI Realtime 输出文本，再使用独立 TTS：  
  https://docs.livekit.io/agents/models/realtime/plugins/openai/
- ElevenLabs Swift SDK：  
  https://elevenlabs.io/docs/agents-platform/libraries/swift
- ElevenLabs 自定义 LLM 支持 Chat Completions 与 Responses 兼容结构：  
  https://elevenlabs.io/docs/eleven-agents/customization/llm/custom-llm
- ElevenLabs 已废弃 `api-global-preview.elevenlabs.io`，使用默认全球路由：  
  https://elevenlabs.io/docs/changelog/2026/2/9
- MusicKit 授权与播放：  
  https://developer.apple.com/documentation/musickit

## 实施节奏

按任务顺序执行，每个任务独立提交。Task 1–8 先完成离线视觉与本地音频长板；Task 9–15 接通实时 DJ；Task 16 作为 Apple Music 的独立闸门；Task 17–19 完成设置、恢复和验收。

任何外部供应商的当前模型名、SDK 版本和价格都保持配置化。执行到对应任务时，先读取官方文档与 changelog，再固定版本并提交锁文件。
