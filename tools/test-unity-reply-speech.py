#!/usr/bin/env python3
"""Compile production reply-routing slices with device-free test boundaries."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
settings = (repo / "apps/macos/UnityHost/UnityProductSettings.swift").read_text()
assert 'RustVoiceClient(root: root.appendingPathComponent("gmgn radio/TaskService", isDirectory: true), allowsLaunching: false)' in settings
host = (repo / "apps/macos/UnityHost/UnityMediaHost.swift").read_text()
assert 'productSettings.onSpeechPlaybackChanged = { [weak graph] playing in' in host
assert 'graph?.setResidentSpeechPlaying(playing)' in host
audio_graph = (repo / "apps/macos/Sources/GMGNRadio/AudioEngine/AudioGraphController.swift").read_text()
resident_setter = '    func setResidentSpeechPlaying(' + audio_graph.split('    func setResidentSpeechPlaying(',1)[1].split('\n    func stopDJVoice()',1)[0]
ducking_envelope = (repo / "apps/macos/Sources/GMGNRadio/AudioEngine/DuckingEnvelope.swift").read_text()
methods = settings.split("    var autoSpeakReplies:", 1)[1].split("    func close()", 1)[0]
resolver = "    private static func resolveVoiceConfiguration" + settings.split("    private static func resolveVoiceConfiguration",1)[1].split("    var autoSpeakReplies:",1)[0]
preferences = (repo / "apps/macos/Sources/GMGNRadio/Settings/AgentSettingsModel.swift").read_text().split("final class RustSpeechPreferences",1)[1].split("struct BailianRealtimeModelOption",1)[0]
save = settings.split('        case "agent.save":', 1)[1].split('        case "agent.backend"', 1)[0]
language = settings.split('        case "app.language":', 1)[1].split('        case "settings.load"', 1)[0]
route = host.split('        if let events = conversation["events"]', 1)[1].split('        conversation["capabilities"]', 1)[0]
# Keep the complete send/cancel/pause/resume cases. World editing has its own
# authority/checkpoint harness and is deliberately outside this speech boundary.
send_cancel = host.split('            case "chat.send":', 1)[1].split('            case "resident.autonomy.editing":', 1)[0]
assert 'case "chat.cancel":' in send_cancel and 'return cancelled' in send_cancel
playback_state = "struct AgentSpeechPlaybackState" + (repo / "apps/macos/Sources/GMGNRadio/Agent/AgentSpeech.swift").read_text().split("struct AgentSpeechPlaybackState", 1)[1].split("\n}", 1)[0] + "\n}"
program = ducking_envelope + r'''
import Foundation
@MainActor final class Mixer {
    var envelope = DuckingEnvelope(sampleRate:100)
    func setDJSpeaking(_ value:Bool) { envelope.setDJSpeaking(value) }
    func gain() -> Float { envelope.advance(frameCount:100) }
}
@MainActor final class Graph {
    let duckingController = Mixer()
    var djIsSpeaking = false, residentSpeechPlaying = false
    var musicVolume:Float = 0.72
''' + resident_setter + r'''
}
enum AgentSpeechOutcome { case finished, cancelled, failed }
typealias AgentSpeechCompletion = @MainActor (AgentSpeechOutcome) -> Void
@MainActor protocol SpeechSynthesizing: AnyObject { func speak(_ text: String, completion: @escaping AgentSpeechCompletion); func stopSpeaking() }
@MainActor final class AgentSpeechStatusStore { var isSpeaking = false; var lastErrorMessage: String? }
enum RustVoiceProvider: String { case bailian, elevenlabs, fish }
struct RustVoiceConfiguration {let provider: RustVoiceProvider; let apiKey: String; let voiceID: String; let model: String?}
enum E2ERuntime {static var defaults: UserDefaults {.standard}}
enum RealtimeVoicePreferences {static let replyVoiceIDKey = "replyVoice"}
final class RustSpeechPreferences''' + preferences + playback_state + r'''
struct ResidentPreferences { init(defaults: UserDefaults) {}; func savePersona(_ persona: String) {}; func saveBackgroundTurnsPerHour(_ value: Int) {} }
@MainActor final class RustSpeechSynthesizer: SpeechSynthesizing {
    static var spoken: [String] = []; static var stops = 0
    static var latest: RustSpeechSynthesizer?
    var completion: AgentSpeechCompletion?
    let onPlaybackChanged: @MainActor (AgentSpeechPlaybackState) -> Void
    init(configuration: () -> RustVoiceConfiguration, statusStore: AgentSpeechStatusStore, client: Int,
         onPlaybackChanged: @escaping @MainActor (AgentSpeechPlaybackState) -> Void = { _ in }) {
        self.onPlaybackChanged = onPlaybackChanged
    }
    func speak(_ text: String) { Self.spoken.append(text); Self.latest = self }
    func speak(_ text: String, completion: @escaping AgentSpeechCompletion) { self.completion = completion; speak(text) }
    func complete() { let callback = completion; completion = nil; callback?(.finished) }
    func stopSpeaking() { Self.stops += 1; onPlaybackChanged(.idle) }
    func emitPlayback(_ state: AgentSpeechPlaybackState) { onPlaybackChanged(state) }
}
@MainActor final class Settings {
    static let autoSpeakKey = "unity.agent.autoSpeakReplies"
    static let localeKey = "unity.ui.locale"
    let defaults: UserDefaults
    let speech: RustSpeechPreferences, client = 0
    let productSpeech: RustSpeechPreferences?
    let productVoiceDefaults: UserDefaults?
    let replyStatus = AgentSpeechStatusStore()
    var replyPlayback = AgentSpeechPlaybackState.idle
    var previewPlayback = AgentSpeechPlaybackState.idle
    var replySpeechGeneration:UInt64 = 0
    var onSpeechPlaybackChanged:((Bool)->Void)?
    var replySpeech: (any SpeechSynthesizing)?, preview: RustSpeechSynthesizer?
    var pendingReplySpeech: [String] = []
    init(_ defaults: UserDefaults, product: UserDefaults? = nil) {
        self.defaults = defaults; speech = RustSpeechPreferences(defaults:defaults)
        productVoiceDefaults = product; productSpeech = product.map {RustSpeechPreferences(defaults:$0)}
    }
''' + resolver + r'''
    var autoSpeakReplies: ''' + methods + r'''
    func command(_ value: [String:Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        switch op { case "app.language": ''' + language + r'''
        case "agent.save": ''' + save + r'''
        default: return false }
        return true
    }
}
@MainActor final class Chat {
    var accepts = true
    var cancels = false
    func send(
        requestID: UInt64,
        submission: ResidentChatSubmission,
        authorizeImages: (@MainActor (UUID, @escaping @MainActor () -> Bool) throws -> Void)? = nil
    ) -> Bool { accepts && submission.canSend }
    func cancel(requestID: UInt64) -> Bool { cancels }
}
struct ResidentImageAttachment: Equatable {}
struct ResidentChatSubmission: Equatable {
    let id = UUID()
    let text: String
    let attachments: [ResidentImageAttachment]
    var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
enum ChatImageFixtureError: Error { case invalidDraft }
@MainActor final class ChatImages {
    func snapshot() -> [String:Any] { ["generation": UInt64(0)] }
    func takeSubmission(text: String, attachmentIDs: [String], generation: UInt64) throws -> ResidentChatSubmission {
        guard attachmentIDs.isEmpty, generation == 0 else { throw ChatImageFixtureError.invalidDraft }
        let submission = ResidentChatSubmission(text: text, attachments: [])
        guard submission.canSend else { throw ChatImageFixtureError.invalidDraft }
        return submission
    }
    func restoreSubmission(_ submission: ResidentChatSubmission) -> Bool { true }
    func finishSubmission(id: UUID) {}
}
@MainActor final class WorldSession {
    func authorizeHumanImages(
        runID: UUID,
        conversationID: String,
        attachments: [ResidentImageAttachment],
        isCurrent: @MainActor () -> Bool
    ) throws {}
}
@MainActor final class PushToTalk {
    var cancelled = 0
    func cancel() { cancelled += 1 }
    func command(_ value:[String:Any]) -> Bool { true }
}
@MainActor final class AutonomyBoundary {
    var begins = 0, finishes = 0, pauses = 0, resumes = 0
    var editing = false
    func humanTurnWillBegin() { begins += 1 }
    func humanTurnDidFinish() { finishes += 1 }
    func pauseByUser() { pauses += 1 }
    func resumeByUser() { resumes += 1 }
    func setEditing(_ value:Bool) { editing = value }
}
@MainActor final class Host {
    let productSettings: Settings, chat = Chat()
    let chatImages = ChatImages()
    let pushToTalk = PushToTalk()
    let humanImageConversationID = "speech-fixture"
    var chatImageSubmissions: [UInt64:ResidentChatSubmission] = [:]
    var residentAutonomy: AutonomyBoundary? = AutonomyBoundary()
    var worldSession: WorldSession? = WorldSession()
    var closed = false
    var replySpeechRequestID: UInt64?
    var announcedReplyRequestID: UInt64?
    init(_ settings: Settings) {productSettings = settings}
    func command(_ value: [String:Any]) -> Bool {
        guard let op = value["op"] as? String else {return false}
        do {
            switch op { case "chat.send": ''' + send_cancel + r'''
            default: return false }
        } catch { return false }
    }
    func poll(_ conversation: [String:Any]) {
        if let events = conversation["events"]''' + route + r'''
    }
}
@main struct Test {
    @MainActor static func main() async {
        let suite = "gmgn-unity-speech-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let settings = Settings(defaults), host = Host(settings)
        let productSuite = suite + ".product"
        let product = UserDefaults(suiteName:productSuite)!
        defer {product.removePersistentDomain(forName:productSuite)}
        product.set("bailian",forKey:"speech.rust.tts.provider")
        product.set("synthetic-test-key",forKey:"voice.bailian.apiKey")
        product.set(false,forKey:"agentConversation.autoSpeakReplies")
        let aligned = Settings(defaults,product:product)
        precondition(aligned.voiceConfiguration(for:"tts").apiKey == "synthetic-test-key")
        precondition(!aligned.autoSpeakReplies)
        precondition(defaults.object(forKey:"voice.bailian.apiKey") == nil)
        precondition(settings.voiceConfiguration(for:"tts").apiKey.isEmpty) // isolated source remains isolated
        defaults.set("elevenlabs",forKey:"speech.rust.tts.provider")
        precondition(aligned.voiceConfiguration(for:"tts").provider == .elevenlabs)
        precondition(aligned.voiceConfiguration(for:"tts").apiKey.isEmpty) // never cross-provider fallback
        defaults.removeObject(forKey:"speech.rust.tts.provider")
        defaults.set("",forKey:"speech.rust.bailian.apiKey")
        precondition(aligned.voiceConfiguration(for:"tts").apiKey.isEmpty) // explicit revocation wins
        defaults.removeObject(forKey:"speech.rust.bailian.apiKey")
        precondition(settings.locale == "zh-CN")
        for language in ["en", "ja", "zh-CN"] {
            precondition(settings.command(["op":"app.language","locale":language]))
            precondition(Settings(defaults).locale == language)
        }
        precondition(!settings.command(["op":"app.language","locale":"invalid"]))
        precondition(settings.locale == "zh-CN")
        precondition(settings.autoSpeakReplies)
        precondition(settings.command(["op":"agent.save","autoSpeak":false]))
        precondition(!Settings(defaults).autoSpeakReplies)
        precondition(!settings.command(["op":"agent.save","autoSpeak":"false"]))
        precondition(!settings.command(["op":"agent.save","autoSpeak":true,"unsupported":1]))
        precondition(!settings.autoSpeakReplies)
        precondition(settings.command(["op":"agent.save","autoSpeak":true]))
        let autonomy = host.residentAutonomy!
        precondition(!host.command(["op":"chat.send","requestID":"99","text":"invalid ID"]))
        precondition(!host.command(["op":"chat.send","requestID":true,"text":"bool ID"]))
        precondition(!host.command(["op":"chat.send","requestID":NSNumber(value:99)]))
        precondition(!host.command(["op":"chat.cancel","requestID":"99"]))
        precondition(!host.command(["op":"chat.cancel","requestID":NSNumber(value:99)]))
        precondition(!host.command(["op":"chat.send","requestID":NSNumber(value:99),"text":"  "]))
        precondition(autonomy.begins == 0 && autonomy.finishes == 0)
        host.chat.accepts = false
        precondition(!host.command(["op":"chat.send","requestID":NSNumber(value:99),"text":"rejected"]))
        precondition(autonomy.begins == 1 && autonomy.finishes == 1)
        precondition(host.pushToTalk.cancelled == 0)
        host.chat.accepts = true
        precondition(host.command(["op":"chat.send","requestID":NSNumber(value:1),"text":"hi"]))
        precondition(autonomy.begins == 2 && autonomy.finishes == 1)
        precondition(host.pushToTalk.cancelled == 1)
        func event(_ id: UInt64, _ kind: String, _ text: String = "") -> [String:Any] { ["events":[["requestID":NSNumber(value:id),"kind":kind,"text":text]]] }
        host.poll(event(1,"delta","partial")); precondition(RustSpeechSynthesizer.spoken.isEmpty)
        precondition(autonomy.finishes == 1)
        host.poll(event(1,"reply","final")); host.poll(event(1,"reply","duplicate"))
        precondition(autonomy.finishes == 3)
        precondition(RustSpeechSynthesizer.spoken == ["final"])
        // Requested synthesis is not evidence of audible playback. Drive the
        // production settings callback through the device-free audio boundary.
        let graph = Graph()
        settings.onSpeechPlaybackChanged = { graph.setResidentSpeechPlaying($0) }
        precondition(settings.replyPlaybackSnapshot["isPlaying"] as? Bool == false)
        precondition(graph.duckingController.gain() == 1)
        let firstSpeech = RustSpeechSynthesizer.latest!
        firstSpeech.emitPlayback(.init(isPlaying:true, level:0.42))
        precondition(graph.duckingController.gain() <= 0.301)
        precondition(graph.musicVolume == 0.72)
        precondition(settings.replyPlaybackSnapshot["isPlaying"] as? Bool == true)
        precondition(settings.replyPlaybackSnapshot["level"] as? Float == 0.42)
        firstSpeech.emitPlayback(.init(isPlaying:true, level:2))
        precondition(settings.replyPlaybackSnapshot["level"] as? Float == 1)
        firstSpeech.emitPlayback(.init(isPlaying:false, level:0.42))
        precondition(graph.duckingController.gain() >= 0.999)
        precondition(settings.replyPlaybackSnapshot["isPlaying"] as? Bool == false)
        precondition(settings.replyPlaybackSnapshot["level"] as? Float == 0)
        firstSpeech.emitPlayback(.init(isPlaying:true, level:0.5))
        precondition(host.command(["op":"resident.autonomy.pause"]))
        precondition(host.command(["op":"resident.autonomy.resume"]))
        precondition(autonomy.pauses == 1 && autonomy.resumes == 1)
        precondition(host.command(["op":"chat.cancel","requestID":NSNumber(value:1)]))
        precondition(graph.duckingController.gain() >= 0.999)
        firstSpeech.emitPlayback(.init(isPlaying:true,level:0.6))
        precondition(graph.duckingController.gain() >= 0.999)
        precondition(graph.musicVolume == 0.72)
        precondition(settings.replyPlaybackSnapshot["isPlaying"] as? Bool == false)
        precondition(settings.replyPlaybackSnapshot["level"] as? Float == 0)
        precondition(host.command(["op":"chat.send","requestID":NSNumber(value:2),"text":"next"]))
        precondition(RustSpeechSynthesizer.stops > 0)
        host.poll(event(1,"reply","late")); precondition(RustSpeechSynthesizer.spoken == ["final"])
        precondition(host.command(["op":"chat.cancel","requestID":NSNumber(value:2)]))
        host.poll(event(2,"reply","cancelled")); precondition(RustSpeechSynthesizer.spoken == ["final"])
        precondition(host.command(["op":"chat.send","requestID":NSNumber(value:3),"text":"disabled"]))
        precondition(settings.command(["op":"agent.save","autoSpeak":false]))
        host.poll(event(3,"reply","disabled")); precondition(RustSpeechSynthesizer.spoken == ["final"])
        precondition(host.command(["op":"chat.send","requestID":NSNumber(value:4),"text":"failure"]))
        host.poll(event(4,"failure")); host.poll(event(4,"reply","afterfail"))
        precondition(RustSpeechSynthesizer.spoken == ["final"])
        precondition(settings.command(["op":"agent.save","autoSpeak":true]))
        precondition(host.command(["op":"chat.send","requestID":NSNumber(value:5),"text":"speak again"]))
        host.poll(event(5,"reply","second final"))
        precondition(RustSpeechSynthesizer.spoken == ["final", "second final"])
        RustSpeechSynthesizer.latest!.emitPlayback(.init(isPlaying:true, level:0.25))
        precondition(graph.duckingController.gain() <= 0.301)
        precondition(settings.replyPlaybackSnapshot["isPlaying"] as? Bool == true)
        precondition(host.command(["op":"chat.send","requestID":NSNumber(value:6),"text":"interrupt playback"]))
        precondition(graph.duckingController.gain() >= 0.999 && graph.musicVolume == 0.72)
        precondition(settings.replyPlaybackSnapshot["isPlaying"] as? Bool == false)
        precondition(settings.replyPlaybackSnapshot["level"] as? Float == 0)
        host.poll(event(5,"reply","superseded"))
        precondition(RustSpeechSynthesizer.spoken == ["final", "second final"])
        settings.speakReply("full first reply")
        let queuedFirst = RustSpeechSynthesizer.latest!
        let stopsBeforeQueue = RustSpeechSynthesizer.stops
        settings.speakReply("autonomous second reply")
        precondition(RustSpeechSynthesizer.spoken.last == "full first reply")
        precondition(RustSpeechSynthesizer.stops == stopsBeforeQueue)
        queuedFirst.complete()
        for _ in 0..<20 { await Task.yield() }
        precondition(RustSpeechSynthesizer.spoken.suffix(2) == ["full first reply", "autonomous second reply"])
        settings.speakReply("queued then cancelled")
        let queueCount = RustSpeechSynthesizer.spoken.count
        let activeBeforeStop = RustSpeechSynthesizer.latest!
        settings.stopReplySpeech()
        activeBeforeStop.complete()
        for _ in 0..<20 { await Task.yield() }
        precondition(RustSpeechSynthesizer.spoken.count == queueCount)
        print("PASS read-only configuration, persisted auto-speak, final-only once, playback callback/state/level and cancellation reset, original 0.3 music ducking with user volume preserved, release and stale callback suppression, complete chat.send/chat.cancel and human pause/resume routing; no device/service requests or audible-output validation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="gmgn-unity-speech-") as directory:
    source = Path(directory) / "test.swift"
    source.write_text(program)
    executable = Path(directory) / "test"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
