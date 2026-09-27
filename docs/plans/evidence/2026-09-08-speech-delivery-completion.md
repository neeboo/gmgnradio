# 语音朗读交付回调（完成/失败/取消）——供主代理接线语音记忆确认

日期：2026-09-08。本文件只说明本轮已完成的最小可靠 completion 接口、成功语义，以及
App 应如何调用它去确认“该轮回复已真实语音交付”。本阶段不做 App 接线（由主代理后续
安排），completion 内部也**不**调用 memory_ingest——只把结果上报给 App 侧调用方。

## 1. 本轮交付（本协作者独占文件）

| 文件 | 内容 |
| --- | --- |
| `apps/macos/Sources/GMGNRadio/Agent/AgentSpeech.swift` | 新增 `AgentSpeechOutcome`/`AgentSpeechCompletion`；`SpeechSynthesizing` 增加带 completion 的 `speak(_:completion:)`；`MacSpeechSynthesizer` 改为每 utterance 独立引擎（`SystemVoiceSpeaking` 边界）+ 身份归属；`AgentSpeechAnnouncer` 新增 `announce(_:completion:)`（旧 `announce(_:)`/`stop()` 保持可编译）；`BailianSpeechSynthesizer` 全分段播完才 `finished`。 |
| `apps/macos/Tests/GMGNRadioTests/Agent/AgentSpeechTests.swift` | 全部改用 fake 引擎/合成器；新增完成/禁用/空文本/启动失败/stop/替换/迟到回调/多分段等单元测试（不实例化真实 NSSpeechSynthesizer）。 |
| `tools/test-agent-speech-completion.swift`（新增） | 离线工具测试：编译真实 AgentSpeech.swift + fake synthesizer/voice/player/loader，55 项断言覆盖成功、disabled、空文本、start=false、stop、替换、迟到回调、Bailian 全分段完成/中途失败/取消、回调恰好一次。 |
| `tools/test-agent-speech-playback.swift` | 仅给内部 swiftc 增加 `-disable-sandbox`（本环境 macro plugin 限制，见 §4），无逻辑改动；21 项播放生命周期断言保持通过。 |
| `docs/plans/evidence/2026-09-08-speech-delivery-completion.md`（本文件） | 交接说明。 |

未触碰其它协作者文件（AgentConversationService 记忆接线、DSH 原生工具桥、
App/Presence/Inbox/工程/Rust 均未修改），未回退任何他人未提交改动。

## 2. 接口与成功语义（最小可靠契约）

```swift
enum AgentSpeechOutcome: Equatable, Sendable {
    case finished   // 整段语音自然播放完毕（Bailian = 全部分段全部播完）
    case cancelled  // 被新朗读替换 / 用户 stop / 朗读被禁用 / 文本为空（从未开始）
    case failed     // 启动、网络、合成或播放失败
}
typealias AgentSpeechCompletion = @MainActor (AgentSpeechOutcome) -> Void

@MainActor protocol SpeechSynthesizing: AnyObject {
    @discardableResult func speak(_ text: String) -> Bool
    @discardableResult func speak(_ text: String, completion: @escaping AgentSpeechCompletion) -> Bool
    func stopSpeaking()
}
```

- **回调恰好一次**：同一次 `speak(_:completion:)` / `announce(_:completion:)` 请求，
  无论成功、取消或失败，最终只触发一次 completion，且都在 MainActor 上。
- **只有“一次 utterance 真完成”才算成功**：`speak` 返回 true 不代表成功；第一段
  播完不代表成功；Bailian 必须**所有 chunk 全部播放完成**才报告 `.finished`。
- **保证不成功**：启动失败、网络/合成失败、播放失败 → `.failed`；用户 `stop`、
  新朗读替换旧朗读、朗读被禁用、文本为空 → `.cancelled`。App 只在 `.finished`
  时做“已语音交付”的记忆确认，其它两种一律不得触发。
- **旧 operation / 迟到回调不能给新朗读报成功**：
  - Bailian 沿用 generation UUID 守卫：`resolve` 只允许 `generation == current`；
    替换/stop 先结算旧请求为 `.cancelled`，旧 Task 的迟到网络/播放结果不再生效。
  - 系统 NSSpeechSynthesizer 不再用“无法归属的全局计数 Bool”，改为**每次朗读
    独立引擎实例**（`SystemVoiceSpeaking` + `MacSystemVoice`），完成事件必须匹配
    “当前引擎”身份（`self.voice === voice`）；`stopSpeaking()` 先摘除旧引擎的
    `onFinished` 并释放，因此 stop 后迟到的 `didFinish` 只会归属旧实例、不能
    误匹配新 utterance（delegate 为 weak，实例随旧引擎释放安全）。
- **既有功能全部保留**：口型/`AgentSpeechPlaybackState`、`AgentSpeechAudioPlayer`
  设备边界、`AgentSpeechStatusStore.lastErrorMessage`/`isSpeaking`、`stopSpeaking()`
  对外状态清理、无回调旧入口（`speak(_:)`/`announce(_:)`）行为与文案一致；
  取消/替换绝不写错误消息（与旧行为一致）。
- 失败/状态文案保持原样（“启动失败…”“百炼朗读请求失败（500）…”“语音播放失败…”“语音朗读
  失败，请检查系统语音设置…”），具体错误仍写 `statusStore.lastErrorMessage` 供 UI 展示。

### Announcer 新入口

```swift
// 旧入口不变
func announce(_ text: String)
func stop()
// 新入口：每次调用恰好回调一次
func announce(_ text: String, completion: @escaping AgentSpeechCompletion)
```

`performAnnounce` 先清空 `lastErrorMessage`；启用且文本非空才 `synthesizer.speak(...)`；
启动失败且合成器未给出更具体错误时补通用“启动失败”文案（与旧 announce 行为一致）。

## 3. App 应如何调用 completion（供主代理接线，本阶段未接线）

1. 在现有 `GMGNRadioApp.swift` `onReply`（约 3531 行）里把朗读入口换成带回调版本，
   用 `.finished` 作为“该轮回复已语音交付”的唯一信号；App 收到 `.finished` 后再做
   需要的人工确认/语音记忆（`completion` 本身不 ingest，也不该在 speech 模块里 ingest）：

   ```swift
   agentSpeechAnnouncer.announce(reply) { [weak self] outcome in
       guard outcome == .finished else { return }   // cancelled/failed 一律不确认
       self?.confirmReplyVoiceDelivered(reply)      // 由主代理/App 决定：可再写记忆
   }
   ```

2. 文字回复的展示/落库路径完全不变：`.failed`/`.cancelled` 只意味着“这一轮没被语音
   读出”，文字已照常交付，不应重复播报或吞掉文字。
3. 若未来需要区分“被用户主动打断”与“系统故障”做 UX，可在 `.cancelled` vs `.failed`
   上分支；当前两个合成器对“新朗读替换旧朗读”都会先给旧请求 `.cancelled`。
4. 不需要 App 侧额外适配的保证：任何时刻至多一个 pending utterance；重复
   `announce` 即替换语义，App 不用自己先 `stop()`（`speak` 内部先结算旧请求）。

## 4. 已验证（本机离线，退出码真实）

编译环境说明：本会话文件沙箱禁止 swiftc 的 macro plugin server（`@Observable` 展开
失败），因此在工具测试的 swiftc 参数中加入 `-disable-sandbox` 后离线编译运行；不涉及
Xcode、App、音频设备、系统语音、网络或任何真实服务。

| 检查 | 结果 |
| --- | --- |
| `swift tools/test-agent-speech-completion.swift`（新） | `PASS: 55 speech delivery completion checks`，退出码 0 |
| `swift tools/test-agent-speech-playback.swift` | `PASS: 21 speech playback checks`，退出码 0 |
| `tools/test-bailian-agent-tts.swift`（verbatim 临时副本 + `-disable-sandbox` 运行，文件未改） | `PASS: 35 Bailian Agent TTS checks`，退出码 0 |
| `tools/test-resident-speech-ducking.swift`（verbatim 临时副本 + `-disable-sandbox` 运行，文件未改） | `PASS: 12 actual TTS/music ducking checks`，退出码 0 |

新增 Xcode 单元测试（`AgentSpeechTests.swift`，需主代理在完整测试目标中编译运行；
全部 fake，无真实 NSSpeechSynthesizer/音频设备）：
`speechCompletionFiresFinishedExactlyOnce`、`speechCompletionCancelsWhenDisabledOrTextEmpty`、
`speechCompletionFailsWhenStartFails`、`speechCompletionCancelsOnStop`、
`macSpeechTracksEngineIdentityAcrossStopAndNewUtterance`、
`macSpeechReplacementCancelsOldUtterance`、`macSpeechCompletionFailsWhenEngineCannotStart`、
`macSpeechEmptyTextCancelsWithoutCreatingEngine`、
`bailianCompletionFiresOnlyAfterEveryChunkPlayed`、`bailianStopDuringPlaybackCancelsExactlyOnce`、
`bailianMissingKeyFailsLocallyWithCompletion`（原有三个测试保留/适配）。

覆盖矩阵（离线 55 项 + Xcode 镜像）：成功（播完一次 finished）、disabled、空文本、
start=false、用户 stop、新朗读替换、迟到 didFinish/迟到 HTTP resume 不能成功或干扰
新朗读、Bailian 全分段完成后才 finished（speak=true 与第一段完成都不算）、分段中途
网络失败/播放失败、取消不写错误文案、回调恰好一次、缺密钥本地失败无网络。

## 5. 局限与边界

- 系统语音路径只验证到 `SystemVoiceSpeaking` 抽象层与 fake 引擎；真实
  `NSSpeechSynthesizer` 的 `didFinish` 时序未在真机上验证（禁真机/系统语音），
  但每 utterance 独立实例 + weak delegate + 先摘 handler 的设计不依赖真机时序。
- `AgentSpeechTests.swift` 属 GMGNRadioTests 目标，需主代理在完整测试目标编译运行；
  如遇编译错误请回传本协作者修复，勿改他人文件。
- 未运行 xcodebuild / 全 App / cargo，未提交、未推送、未部署；未动
  App/Presence/Inbox/工程/Rust/AgentConversationService/DSH 桥等其它协作者文件。
- `tools/test-agent-speech-playback.swift` 中新增的 `-disable-sandbox` 仅为适配本
  环境编译；在普通开发环境亦无副作用，如需可后续移除。
