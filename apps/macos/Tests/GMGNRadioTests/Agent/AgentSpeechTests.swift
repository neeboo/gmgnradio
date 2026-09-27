import Foundation
import Testing
@testable import GMGNRadio

@MainActor
private final class FailingSpeechSynthesizer: SpeechSynthesizing {
    private(set) var spokenTexts: [String] = []

    func speak(_ text: String) -> Bool {
        spokenTexts.append(text)
        return false
    }

    func speak(_ text: String, completion: @escaping AgentSpeechCompletion) -> Bool {
        spokenTexts.append(text)
        completion(.failed)
        return false
    }

    func stopSpeaking() {}
}

@MainActor
private final class ScriptedSpeechSynthesizer: SpeechSynthesizing {
    var canStart = true
    private(set) var spokenTexts: [String] = []
    private var pending: [AgentSpeechCompletion] = []
    private(set) var stopCount = 0

    func speak(_ text: String) -> Bool { start(text, completion: nil) }
    func speak(_ text: String, completion: @escaping AgentSpeechCompletion) -> Bool {
        start(text, completion: completion)
    }

    private func start(_ text: String, completion: AgentSpeechCompletion?) -> Bool {
        spokenTexts.append(text)
        guard canStart else {
            completion?(.failed)
            return false
        }
        if let completion { pending.append(completion) }
        return true
    }

    func stopSpeaking() {
        stopCount += 1
        if let completion = pending.popLast() { completion(.cancelled) }
    }

    func finish(_ outcome: AgentSpeechOutcome) {
        if let completion = pending.popLast() { completion(outcome) }
    }
}

/// Per-utterance system voice fake: never touches a real NSSpeechSynthesizer.
@MainActor
private final class FakeVoice: SystemVoiceSpeaking {
    var onFinished: (@MainActor (Bool) -> Void)?
    var canStart = true
    private(set) var stopCount = 0
    func startSpeaking(_ text: String) -> Bool { canStart }
    func stopSpeaking() { stopCount += 1 }
    func finish(_ ok: Bool) { onFinished?(ok) }
}

@MainActor
private final class VoiceFactory {
    private(set) var created: [FakeVoice] = []
    var refuseStart = false
    func make() -> FakeVoice {
        let voice = FakeVoice()
        voice.canStart = !refuseStart
        refuseStart = false
        created.append(voice)
        return voice
    }
}

@MainActor
private final class FakeBailianAudio: AgentSpeechAudioPlaying {
    var played: [Data] = []
    var hold = false
    private var waiter: CheckedContinuation<Void, Error>?

    func play(_ data: Data, onPlaybackChanged: @escaping @MainActor (AgentSpeechPlaybackState) -> Void) async throws {
        played.append(data)
        onPlaybackChanged(.init(isPlaying: true, level: 0.3))
        defer { onPlaybackChanged(.idle) }
        if hold {
            try await withCheckedThrowingContinuation { waiter = $0 }
        }
    }
    func stop() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

@MainActor
private final class FakeBailianLoader {
    var requests: [URLRequest] = []
    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let body: Data
        if request.httpMethod == "POST" {
            body = try JSONSerialization.data(withJSONObject: [
                "output": ["audio": ["url": "http://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/fixture.wav?Signature=private"]],
            ])
        } else {
            body = Data("fixture-audio".utf8)
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
@Test
func speechFailureDoesNotRemoveAgentReplyText() {
    let store = AgentSpeechStatusStore()
    let synthesizer = FailingSpeechSynthesizer()
    let announcer = AgentSpeechAnnouncer(
        synthesizer: synthesizer,
        isEnabled: true,
        statusStore: store
    )

    let reply = "这是 Agent 的文字回复。"
    announcer.announce(reply)

    // 朗读失败只更新轻量状态，不吞掉文字。
    #expect(synthesizer.spokenTexts == [reply])
    #expect(store.lastErrorMessage != nil)
    #expect(reply == "这是 Agent 的文字回复。")
}

@MainActor
@Test
func disabledAnnouncerSkipsSpeechWithoutError() {
    let store = AgentSpeechStatusStore()
    let synthesizer = FailingSpeechSynthesizer()
    let announcer = AgentSpeechAnnouncer(
        synthesizer: synthesizer,
        isEnabled: false,
        statusStore: store
    )

    announcer.announce("你好")
    #expect(synthesizer.spokenTexts.isEmpty)
    #expect(store.lastErrorMessage == nil)
}

@MainActor
@Test
func macSpeechSynthesizerSkipsEmptyText() {
    let synthesizer = MacSpeechSynthesizer(
        statusStore: AgentSpeechStatusStore()
    )
    #expect(synthesizer.speak("   ") == false)
}

@MainActor
@Test
func speechCompletionFiresFinishedExactlyOnce() {
    let store = AgentSpeechStatusStore()
    let synthesizer = ScriptedSpeechSynthesizer()
    let announcer = AgentSpeechAnnouncer(
        synthesizer: synthesizer,
        isEnabled: true,
        statusStore: store
    )
    var outcomes: [AgentSpeechOutcome] = []
    announcer.announce("你好") { outcomes.append($0) }

    #expect(outcomes.isEmpty)
    synthesizer.finish(.finished)
    synthesizer.finish(.finished)
    #expect(outcomes == [.finished])
    #expect(store.lastErrorMessage == nil)
}

@MainActor
@Test
func speechCompletionCancelsWhenDisabledOrTextEmpty() {
    let store = AgentSpeechStatusStore()
    let synthesizer = ScriptedSpeechSynthesizer()

    var disabledOutcomes: [AgentSpeechOutcome] = []
    let disabled = AgentSpeechAnnouncer(
        synthesizer: synthesizer,
        isEnabled: false,
        statusStore: store
    )
    disabled.announce("你好") { disabledOutcomes.append($0) }
    #expect(disabledOutcomes == [.cancelled])

    var emptyOutcomes: [AgentSpeechOutcome] = []
    let enabled = AgentSpeechAnnouncer(
        synthesizer: synthesizer,
        isEnabled: true,
        statusStore: store
    )
    enabled.announce("   ") { emptyOutcomes.append($0) }
    #expect(emptyOutcomes == [.cancelled])
    #expect(synthesizer.spokenTexts.isEmpty)
    #expect(store.lastErrorMessage == nil)
}

@MainActor
@Test
func speechCompletionFailsWhenStartFails() {
    let store = AgentSpeechStatusStore()
    let synthesizer = ScriptedSpeechSynthesizer()
    synthesizer.canStart = false
    let announcer = AgentSpeechAnnouncer(
        synthesizer: synthesizer,
        isEnabled: true,
        statusStore: store
    )

    var outcomes: [AgentSpeechOutcome] = []
    announcer.announce("你好") { outcomes.append($0) }
    #expect(outcomes == [.failed])
    #expect(store.lastErrorMessage != nil)
}

@MainActor
@Test
func speechCompletionCancelsOnStop() {
    let store = AgentSpeechStatusStore()
    let synthesizer = ScriptedSpeechSynthesizer()
    let announcer = AgentSpeechAnnouncer(
        synthesizer: synthesizer,
        isEnabled: true,
        statusStore: store
    )

    var outcomes: [AgentSpeechOutcome] = []
    announcer.announce("你好") { outcomes.append($0) }
    announcer.stop()
    #expect(outcomes == [.cancelled])
    #expect(synthesizer.stopCount == 1)
    #expect(store.lastErrorMessage == nil)
}

@MainActor
@Test
func macSpeechTracksEngineIdentityAcrossStopAndNewUtterance() {
    let store = AgentSpeechStatusStore()
    let factory = VoiceFactory()
    let synthesizer = MacSpeechSynthesizer(statusStore: store, makeVoice: { factory.make() })

    var first: [AgentSpeechOutcome] = []
    let firstStarted = synthesizer.speak("旧朗读") { first.append($0) }
    #expect(firstStarted)
    synthesizer.stopSpeaking()
    #expect(first == [.cancelled])
    #expect(factory.created.count == 1)

    var second: [AgentSpeechOutcome] = []
    let secondStarted = synthesizer.speak("新朗读") { second.append($0) }
    #expect(secondStarted)
    #expect(factory.created.count == 2)

    // 旧引擎停止后迟到的 didFinish 不能给新朗读报成功。
    factory.created[0].finish(true)
    #expect(second.isEmpty)
    factory.created[1].finish(true)
    #expect(second == [.finished])
    #expect(first == [.cancelled])
    #expect(store.lastErrorMessage == nil)
}

@MainActor
@Test
func macSpeechReplacementCancelsOldUtterance() {
    let store = AgentSpeechStatusStore()
    let factory = VoiceFactory()
    let synthesizer = MacSpeechSynthesizer(statusStore: store, makeVoice: { factory.make() })

    var old: [AgentSpeechOutcome] = []
    var new: [AgentSpeechOutcome] = []
    let oldStarted = synthesizer.speak("旧朗读") { old.append($0) }
    let newStarted = synthesizer.speak("新朗读") { new.append($0) }
    #expect(oldStarted)
    #expect(newStarted)

    #expect(old == [.cancelled])
    #expect(new.isEmpty)
    // 被替换旧引擎的任何迟到事件都不能成功或失败新朗读。
    factory.created[0].finish(false)
    #expect(new.isEmpty)
    factory.created[1].finish(true)
    #expect(new == [.finished])
    #expect(old == [.cancelled])
}

@MainActor
@Test
func macSpeechCompletionFailsWhenEngineCannotStart() {
    let store = AgentSpeechStatusStore()
    let factory = VoiceFactory()
    factory.refuseStart = true
    let synthesizer = MacSpeechSynthesizer(statusStore: store, makeVoice: { factory.make() })

    var outcomes: [AgentSpeechOutcome] = []
    let started = synthesizer.speak("你好") { outcomes.append($0) }
    #expect(started == false)
    #expect(outcomes == [.failed])
    #expect(factory.created.count == 1)
}

@MainActor
@Test
func macSpeechEmptyTextCancelsWithoutCreatingEngine() {
    let store = AgentSpeechStatusStore()
    let factory = VoiceFactory()
    let synthesizer = MacSpeechSynthesizer(statusStore: store, makeVoice: { factory.make() })

    var outcomes: [AgentSpeechOutcome] = []
    let started = synthesizer.speak("   ") { outcomes.append($0) }
    #expect(started == false)
    #expect(outcomes == [.cancelled])
    #expect(factory.created.isEmpty)
    #expect(store.lastErrorMessage == nil)
}

@MainActor
@Test
func bailianCompletionFiresOnlyAfterEveryChunkPlayed() async {
    let store = AgentSpeechStatusStore()
    let loader = FakeBailianLoader()
    let audio = FakeBailianAudio()
    let speech = BailianSpeechSynthesizer(
        configuration: { BailianTTSConfiguration(apiKey: "fixture") },
        statusStore: store,
        load: { try await loader.load($0) },
        player: audio
    )
    let longText = String(repeating: "中", count: 1250)
    let chunks = BailianTTSWire.textChunks(longText)
    #expect(chunks.count >= 2)

    var outcomes: [AgentSpeechOutcome] = []
    let started = speech.speak(longText) { outcomes.append($0) }
    #expect(started)
    #expect(outcomes.isEmpty)
    for _ in 0..<1000 where speech.isSpeaking {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(outcomes == [.finished])
    #expect(audio.played.count == chunks.count)
    #expect(store.lastErrorMessage == nil)
}

@MainActor
@Test
func bailianStopDuringPlaybackCancelsExactlyOnce() async {
    let store = AgentSpeechStatusStore()
    let loader = FakeBailianLoader()
    let audio = FakeBailianAudio()
    audio.hold = true
    let speech = BailianSpeechSynthesizer(
        configuration: { BailianTTSConfiguration(apiKey: "fixture") },
        statusStore: store,
        load: { try await loader.load($0) },
        player: audio
    )

    var outcomes: [AgentSpeechOutcome] = []
    let started = speech.speak("请停止播放") { outcomes.append($0) }
    #expect(started)
    for _ in 0..<1000 where audio.played.isEmpty {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(!audio.played.isEmpty)
    speech.stopSpeaking()
    #expect(outcomes == [.cancelled])
    #expect(store.lastErrorMessage == nil)
}

@MainActor
@Test
func bailianMissingKeyFailsLocallyWithCompletion() {
    let store = AgentSpeechStatusStore()
    let loader = FakeBailianLoader()
    let speech = BailianSpeechSynthesizer(
        configuration: { BailianTTSConfiguration(apiKey: "") },
        statusStore: store,
        load: { try await loader.load($0) },
        player: FakeBailianAudio()
    )

    var outcomes: [AgentSpeechOutcome] = []
    let started = speech.speak("你好") { outcomes.append($0) }
    #expect(started == false)
    #expect(outcomes == [.failed])
    #expect(store.lastErrorMessage?.contains("密钥") == true)
    #expect(loader.requests.isEmpty)
}
