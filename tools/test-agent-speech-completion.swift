// Offline completion-delivery contract for real speech playback: one utterance
// reports finished/cancelled/failed exactly once; success is reported only when
// the whole utterance (all Bailian chunks / the system voice run) truly
// finished. Stop, replacement, late callbacks and every failure mode never
// report success. Everything below the speech file is fake: no real
// NSSpeechSynthesizer, no audio device, no network, no app.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/AgentSpeech.swift")
let program = #"""
import Foundation

// MARK: - Fakes

/// Scripted SpeechSynthesizing used to test the announcer plumbing.
@MainActor final class ScriptedSynth: SpeechSynthesizing {
    var canStart = true
    var spoken: [String] = []
    var stopCount = 0
    private var pending: [AgentSpeechCompletion] = []
    var outstanding: Int { pending.count }

    func speak(_ text: String) -> Bool { start(text, completion: nil) }
    func speak(_ text: String, completion: @escaping AgentSpeechCompletion) -> Bool {
        start(text, completion: completion)
    }
    private func start(_ text: String, completion: AgentSpeechCompletion?) -> Bool {
        spoken.append(text)
        guard canStart else { completion?(.failed); return false }
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

/// Per-utterance system voice fake. A real utterance is attached through
/// onFinished only while its own engine is current.
@MainActor final class FakeVoice: SystemVoiceSpeaking {
    var onFinished: (@MainActor (Bool) -> Void)?
    var canStart = true
    var started: [String] = []
    var stopCount = 0
    func startSpeaking(_ text: String) -> Bool {
        guard canStart else { return false }
        started.append(text)
        return true
    }
    func stopSpeaking() { stopCount += 1 }
    func finish(_ ok: Bool) { onFinished?(ok) }
}

/// Records every engine a synthesizer asks for, in order.
@MainActor final class VoiceFactory {
    var created: [FakeVoice] = []
    var refuseStart = false
    func make() -> FakeVoice {
        let voice = FakeVoice()
        voice.canStart = !refuseStart
        refuseStart = false
        created.append(voice)
        return voice
    }
}

/// HTTP fake: successful synthesis/download unless a scenario turns on failure.
@MainActor final class HTTP {
    var requests: [URLRequest] = []
    var postCount = 0
    var status = 200
    var failFromPost = Int.max
    var holdFirstPost = false
    var waiter: CheckedContinuation<Void, Never>?
    func data(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let isPost = request.httpMethod == "POST"
        if isPost { postCount += 1 }
        if isPost && postCount == 1 && holdFirstPost {
            await withCheckedContinuation { waiter = $0 }
        }
        let code = isPost && postCount >= failFromPost ? 500 : status
        let body: Data
        if isPost {
            body = try JSONSerialization.data(withJSONObject: ["output": ["audio": ["url": "http://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/fixture.wav?Signature=private"]]])
        } else {
            body = Data("fixture-audio".utf8)
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

/// Playback fake: can reject or suspend at a chosen play index.
@MainActor final class Audio: AgentSpeechAudioPlaying {
    var played: [Data] = []
    var stops = 0
    var rejectAtPlay = Int.max
    var holdAtPlay = Int.max
    var waiter: CheckedContinuation<Void, Error>?
    func play(_ data: Data, onPlaybackChanged: @escaping @MainActor (AgentSpeechPlaybackState) -> Void) async throws {
        played.append(data)
        let index = played.count
        if index == rejectAtPlay { throw URLError(.cannotDecodeContentData) }
        onPlaybackChanged(.init(isPlaying: true, level: 0.3))
        defer { onPlaybackChanged(.idle) }
        if index == holdAtPlay {
            try await withCheckedThrowingContinuation { waiter = $0 }
        }
    }
    func stop() {
        stops += 1
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
    func resumePlayback() { waiter?.resume(); waiter = nil }
}

@MainActor final class Configuration { var value = BailianTTSConfiguration(apiKey: "fixture-key") }

// MARK: - Harness

@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) { guard value else { fatalError("FAIL: " + name) }; count += 1 }
        func waitFor(_ name: String, _ condition: () -> Bool) async {
            for _ in 0..<4000 { if condition() { return }; try? await Task.sleep(nanoseconds: 250_000) }
            fatalError("FAIL: " + name)
        }
        func settle(_ speech: BailianSpeechSynthesizer) async {
            for _ in 0..<4000 { if !speech.isSpeaking { return }; try? await Task.sleep(nanoseconds: 250_000) }
            fatalError("FAIL: speech did not settle")
        }

        // ---- Announcer plumbing (scripted synthesizer) ----
        let synth = ScriptedSynth()
        let store = AgentSpeechStatusStore()
        let announcer = AgentSpeechAnnouncer(synthesizer: synth, isEnabled: true, statusStore: store)
        var finishedOutcomes: [AgentSpeechOutcome] = []
        announcer.announce("你好") { finishedOutcomes.append($0) }
        check(finishedOutcomes.isEmpty, "no outcome before the voice finishes")
        synth.finish(.finished)
        check(finishedOutcomes == [.finished], "natural completion reports finished once")
        check(synth.spoken == ["你好"] && store.lastErrorMessage == nil, "finished utterance keeps no error")

        var disabledOutcomes: [AgentSpeechOutcome] = []
        let disabled = AgentSpeechAnnouncer(synthesizer: synth, isEnabled: false, statusStore: store)
        disabled.announce("你好") { disabledOutcomes.append($0) }
        check(disabledOutcomes == [.cancelled] && synth.outstanding == 0 && synth.spoken.count == 1,
            "disabled announcer cancels without speaking")

        var emptyOutcomes: [AgentSpeechOutcome] = []
        announcer.announce("   \n ") { emptyOutcomes.append($0) }
        check(emptyOutcomes == [.cancelled] && synth.spoken.count == 1, "empty text cancels without speaking")

        let startFailStore = AgentSpeechStatusStore()
        let failingSynth = ScriptedSynth(); failingSynth.canStart = false
        let failingAnnouncer = AgentSpeechAnnouncer(synthesizer: failingSynth, statusStore: startFailStore)
        var startFailOutcomes: [AgentSpeechOutcome] = []
        failingAnnouncer.announce("你好") { startFailOutcomes.append($0) }
        check(startFailOutcomes == [.failed], "start=false reports failed once")
        check(startFailStore.lastErrorMessage?.contains("启动失败") == true, "start failure keeps visible generic error")

        var stoppedOutcomes: [AgentSpeechOutcome] = []
        announcer.announce("你好") { stoppedOutcomes.append($0) }
        announcer.stop()
        check(stoppedOutcomes == [.cancelled] && synth.stopCount == 1, "stop reports cancelled exactly once")

        var onceOutcomes: [AgentSpeechOutcome] = []
        announcer.announce("你好") { onceOutcomes.append($0) }
        synth.finish(.finished)
        synth.finish(.finished)
        check(onceOutcomes == [.finished], "callback fires exactly once per announcement")

        // ---- System voice identity (per-utterance engine, no real speech) ----
        let naturalFactory = VoiceFactory()
        let macStore = AgentSpeechStatusStore()
        let mac = MacSpeechSynthesizer(statusStore: macStore, makeVoice: { naturalFactory.make() })
        var macDone: [AgentSpeechOutcome] = []
        check(mac.speak("你好", completion: { macDone.append($0) }), "system voice starts")
        check(naturalFactory.created.count == 1 && macDone.isEmpty, "no outcome before engine finishes")
        naturalFactory.created[0].finish(true)
        check(macDone == [.finished] && macStore.lastErrorMessage == nil, "system voice natural end reports finished")

        let emptyFactory = VoiceFactory()
        let emptyMac = MacSpeechSynthesizer(statusStore: AgentSpeechStatusStore(), makeVoice: { emptyFactory.make() })
        var emptyMacOutcomes: [AgentSpeechOutcome] = []
        check(emptyMac.speak("   ", completion: { emptyMacOutcomes.append($0) }) == false,
            "empty text does not start system voice")
        check(emptyMacOutcomes == [.cancelled] && emptyFactory.created.isEmpty,
            "empty text cancels and never creates an engine")

        let refuseFactory = VoiceFactory(); refuseFactory.refuseStart = true
        let refuseMac = MacSpeechSynthesizer(statusStore: AgentSpeechStatusStore(), makeVoice: { refuseFactory.make() })
        var refuseOutcomes: [AgentSpeechOutcome] = []
        check(refuseMac.speak("你好", completion: { refuseOutcomes.append($0) }) == false,
            "engine start failure returns false")
        check(refuseOutcomes == [.failed], "engine start failure reports failed exactly once")

        // stop, then a late didFinish of the old engine must never finish the new utterance
        let isolationFactory = VoiceFactory()
        let isolationMac = MacSpeechSynthesizer(statusStore: AgentSpeechStatusStore(), makeVoice: { isolationFactory.make() })
        var firstOutcomes: [AgentSpeechOutcome] = [], secondOutcomes: [AgentSpeechOutcome] = []
        check(isolationMac.speak("旧朗读", completion: { firstOutcomes.append($0) }), "first utterance starts")
        isolationMac.stopSpeaking()
        check(firstOutcomes == [.cancelled] && isolationFactory.created[0].stopCount == 1,
            "stop cancels first utterance exactly once")
        check(isolationMac.speak("新朗读", completion: { secondOutcomes.append($0) }), "second utterance starts after stop")
        isolationFactory.created[0].finish(true) // late didFinish of the OLD engine
        check(secondOutcomes.isEmpty, "late old-engine didFinish cannot report success for the new utterance")
        isolationFactory.created[1].finish(true)
        check(secondOutcomes == [.finished], "new utterance finishes only through its own engine")
        check(firstOutcomes == [.cancelled], "first utterance stays cancelled exactly once")

        // speak replacement: a new utterance cancels the previous one first
        let replacementFactory = VoiceFactory()
        let replacementMac = MacSpeechSynthesizer(statusStore: AgentSpeechStatusStore(), makeVoice: { replacementFactory.make() })
        var replacedOld: [AgentSpeechOutcome] = [], replacedNew: [AgentSpeechOutcome] = []
        check(replacementMac.speak("旧朗读", completion: { replacedOld.append($0) }), "old starts")
        check(replacementMac.speak("新朗读", completion: { replacedNew.append($0) }), "new replaces old")
        check(replacedOld == [.cancelled] && replacedNew.isEmpty, "replacement cancels old utterance")
        replacementFactory.created[0].finish(false) // stale old-engine failure after replacement
        check(replacedNew.isEmpty, "stale old-engine event cannot finish or fail the new utterance")
        replacementFactory.created[1].finish(true)
        check(replacedNew == [.finished] && replacedOld == [.cancelled], "new utterance finishes once after replacement")

        // ---- Bailian: all chunks must finish before success ----
        let config = Configuration()
        let longText = String(repeating: "中", count: 1250)
        let chunks = BailianTTSWire.textChunks(longText)
        check(chunks.count >= 2, "fixture really spans multiple text chunks")

        let multiHTTP = HTTP(), multiAudio = Audio(), multiStore = AgentSpeechStatusStore()
        multiAudio.holdAtPlay = 2
        let multiSpeech = BailianSpeechSynthesizer(configuration: { config.value }, statusStore: multiStore,
            load: { try await multiHTTP.data($0) }, player: multiAudio)
        var multiOutcomes: [AgentSpeechOutcome] = []
        check(multiSpeech.speak(longText, completion: { multiOutcomes.append($0) }), "long utterance accepted")
        check(multiOutcomes.isEmpty, "speak returning true is not success")
        await waitFor("second chunk playback holds") { multiAudio.played.count == 2 && multiAudio.waiter != nil }
        check(multiOutcomes.isEmpty, "first chunk completing is not success")
        multiAudio.resumePlayback()
        await settle(multiSpeech)
        check(multiOutcomes == [.finished], "all chunks finishing reports finished exactly once")
        check(multiAudio.played.count == chunks.count && multiStore.lastErrorMessage == nil,
            "every chunk played before finished")

        let failHTTP = HTTP(), failAudio = Audio(), failStore = AgentSpeechStatusStore()
        failHTTP.failFromPost = 2
        let failSpeech = BailianSpeechSynthesizer(configuration: { config.value }, statusStore: failStore,
            load: { try await failHTTP.data($0) }, player: failAudio)
        var failOutcomes: [AgentSpeechOutcome] = []
        check(failSpeech.speak(longText, completion: { failOutcomes.append($0) }), "long utterance accepted")
        await settle(failSpeech)
        check(failOutcomes == [.failed] && failAudio.played.count == 1, "mid-chunk network failure reports failed once")
        check(failStore.lastErrorMessage?.contains("500") == true, "network failure stays visible and specific")

        let playHTTP = HTTP(), playAudio = Audio(), playStore = AgentSpeechStatusStore()
        playAudio.rejectAtPlay = 2
        let playSpeech = BailianSpeechSynthesizer(configuration: { config.value }, statusStore: playStore,
            load: { try await playHTTP.data($0) }, player: playAudio)
        var playOutcomes: [AgentSpeechOutcome] = []
        check(playSpeech.speak(longText, completion: { playOutcomes.append($0) }), "long utterance accepted")
        await settle(playSpeech)
        check(playOutcomes == [.failed] && playAudio.played.count == 2, "mid-chunk playback failure reports failed once")
        check(playStore.lastErrorMessage?.contains("播放") == true, "playback failure stays visible")

        let cancelSynthHTTP = HTTP(), cancelSynthAudio = Audio(), cancelSynthStore = AgentSpeechStatusStore()
        cancelSynthHTTP.holdFirstPost = true
        let cancelSynthSpeech = BailianSpeechSynthesizer(configuration: { config.value }, statusStore: cancelSynthStore,
            load: { try await cancelSynthHTTP.data($0) }, player: cancelSynthAudio)
        var cancelSynthOutcomes: [AgentSpeechOutcome] = []
        check(cancelSynthSpeech.speak("请停止合成", completion: { cancelSynthOutcomes.append($0) }), "utterance accepted")
        await waitFor("synthesis request holds") { cancelSynthHTTP.waiter != nil }
        cancelSynthSpeech.stopSpeaking()
        check(cancelSynthOutcomes == [.cancelled] && cancelSynthStore.lastErrorMessage == nil,
            "user stop cancels pending synthesis")
        cancelSynthHTTP.waiter?.resume(); cancelSynthHTTP.waiter = nil
        for _ in 0..<200 { try? await Task.sleep(nanoseconds: 250_000) }
        check(cancelSynthOutcomes == [.cancelled] && cancelSynthAudio.played.isEmpty
            && cancelSynthStore.lastErrorMessage == nil, "late resume after stop never plays nor reports again")

        let cancelPlayHTTP = HTTP(), cancelPlayAudio = Audio(), cancelPlayStore = AgentSpeechStatusStore()
        cancelPlayAudio.holdAtPlay = 1
        let cancelPlaySpeech = BailianSpeechSynthesizer(configuration: { config.value }, statusStore: cancelPlayStore,
            load: { try await cancelPlayHTTP.data($0) }, player: cancelPlayAudio)
        var cancelPlayOutcomes: [AgentSpeechOutcome] = []
        check(cancelPlaySpeech.speak("请停止播放", completion: { cancelPlayOutcomes.append($0) }), "utterance accepted")
        await waitFor("playback holds") { cancelPlayAudio.played.count == 1 && cancelPlayAudio.waiter != nil }
        cancelPlaySpeech.stopSpeaking()
        await settle(cancelPlaySpeech)
        check(cancelPlayOutcomes == [.cancelled] && cancelPlayStore.lastErrorMessage == nil,
            "user stop cancels active playback")

        // replacement isolation for Bailian: old cancelled once, new finishes, late old resume changes nothing
        let replaceHTTP = HTTP(), replaceAudio = Audio(), replaceStore = AgentSpeechStatusStore()
        replaceHTTP.holdFirstPost = true
        let replaceSpeech = BailianSpeechSynthesizer(configuration: { config.value }, statusStore: replaceStore,
            load: { try await replaceHTTP.data($0) }, player: replaceAudio)
        var oldBailian: [AgentSpeechOutcome] = [], newBailian: [AgentSpeechOutcome] = []
        check(replaceSpeech.speak("旧回答", completion: { oldBailian.append($0) }), "old utterance accepted")
        await waitFor("old utterance request holds") { replaceHTTP.waiter != nil }
        replaceHTTP.holdFirstPost = false
        check(replaceSpeech.speak("新回答", completion: { newBailian.append($0) }), "new utterance replaces old")
        check(oldBailian == [.cancelled] && newBailian.isEmpty, "Bailian replacement cancels old utterance once")
        await settle(replaceSpeech)
        check(newBailian == [.finished] && oldBailian == [.cancelled], "Bailian new utterance finishes once")
        let requestsBeforeLateResume = replaceHTTP.requests.count
        replaceHTTP.waiter?.resume(); replaceHTTP.waiter = nil
        for _ in 0..<200 { try? await Task.sleep(nanoseconds: 250_000) }
        check(oldBailian == [.cancelled] && newBailian == [.finished], "late old Bailian resume reports nothing extra")
        check(replaceHTTP.requests.count == requestsBeforeLateResume, "late old resume never synthesizes audio")

        // Bailian empty text and local validation (no network)
        let emptySpeech = BailianSpeechSynthesizer(configuration: { config.value }, statusStore: AgentSpeechStatusStore(),
            load: { _ in throw URLError(.badURL) }, player: Audio())
        var emptyBailian: [AgentSpeechOutcome] = []
        check(emptySpeech.speak("   ", completion: { emptyBailian.append($0) }) == false,
            "empty Bailian text refuses start")
        check(emptyBailian == [.cancelled], "empty Bailian text cancels exactly once")

        let keyStore = AgentSpeechStatusStore(), keyHTTP = HTTP()
        let noKey = BailianSpeechSynthesizer(configuration: { .init(apiKey: "") }, statusStore: keyStore,
            load: { try await keyHTTP.data($0) }, player: Audio())
        var keyOutcomes: [AgentSpeechOutcome] = []
        check(noKey.speak("你好", completion: { keyOutcomes.append($0) }) == false, "missing key refuses start")
        check(keyOutcomes == [.failed] && keyStore.lastErrorMessage?.contains("密钥") == true
            && keyHTTP.requests.isEmpty, "missing key fails locally without network")

        // plain announce keeps legacy speak/status semantics
        let legacyStore = AgentSpeechStatusStore(), legacyHTTP = HTTP(), legacyAudio = Audio()
        let legacySpeech = BailianSpeechSynthesizer(configuration: { config.value }, statusStore: legacyStore,
            load: { try await legacyHTTP.data($0) }, player: legacyAudio)
        let legacyAnnouncer = AgentSpeechAnnouncer(synthesizer: legacySpeech, statusStore: legacyStore)
        legacyAnnouncer.announce("旧式调用")
        await settle(legacySpeech)
        check(legacyStore.lastErrorMessage == nil && legacyAudio.played.count == 1,
            "plain announce still speaks and keeps no error")

        print("PASS: \(count) speech delivery completion checks")
    }
}
"""#
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-completion-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let main = folder.appendingPathComponent("Checks.swift"), binary = folder.appendingPathComponent("checks")
try program.write(to: main, atomically: true, encoding: .utf8)
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-disable-sandbox", "-j1", "-swift-version", "6", "-parse-as-library", source.path,
    source.deletingLastPathComponent().appendingPathComponent("RustVoiceClient.swift").path,
    source.deletingLastPathComponent().appendingPathComponent("../Presence/TaskdHTTPTransport.swift").path,
    source.deletingLastPathComponent().appendingPathComponent("StreamingPCMPlayer.swift").path,
    main.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit(); guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let run = Process(); run.executableURL = binary; try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
