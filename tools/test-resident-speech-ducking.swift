// Actual TTS generations, App playback callback, and music ducking methods.
// Audio devices and HTTP are inert; no host, credentials, or network.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let base = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
func read(_ path: String) throws -> String { try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8) }
func declaration(_ signature: String, _ text: String) -> String {
    let start = text.range(of: signature)!.lowerBound
    let opening = text[start...].firstIndex(of: "{")!
    var depth = 0
    for i in text[opening...].indices {
        if text[i] == "{" { depth += 1 }; if text[i] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...i]) }
    }
    fatalError("Unbalanced declaration")
}
let app = try read("App/GMGNRadioApp.swift")
let graph = try read("AudioEngine/AudioGraphController.swift")
let callback = declaration("onPlaybackChanged: {", app)
let callbackBody = String(callback[callback.firstIndex(of: "{")!...])
let residentSetter = graph.contains("func setResidentSpeechPlaying(") ? declaration("func setResidentSpeechPlaying(", graph) : ""
let stopBinding = declaration("AgentSpeechStatusStore.shared.onStopSpeaking = {", app)
let closeStage = declaration("private func finishCurrentClose()", try read("VisualEngine/StageWindowController.swift"))
let program = #"""
import Foundation
@MainActor final class Mixer {
    var envelope = DuckingEnvelope(sampleRate: 100)
    func setDJSpeaking(_ value: Bool) { envelope.setDJSpeaking(value) }
    func advance() -> Float { envelope.advance(frameCount: 100) }
}
@MainActor final class Graph {
    let duckingController = Mixer()
    var djIsSpeaking = false
    var residentSpeechPlaying = false
    var musicVolume: Float = 0.72
    \#(declaration("func setDJSpeaking(", graph))
    \#(residentSetter)
}
@MainActor final class Avatar {
    var level: Float?
    func setResidentSpeechPlayback(isPlaying: Bool, level: Float) { self.level = isPlaying ? level : nil }
}
@MainActor final class App {
    let avatarRuntime = Avatar()
    let audioGraph = Graph()
    var agentSpeechAnnouncer: AgentSpeechAnnouncer!
    func configureStop() { \#(stopBinding) }
    func receive(_ state: AgentSpeechPlaybackState) {
        let callback: @MainActor (AgentSpeechPlaybackState) -> Void = \#(callbackBody)
        callback(state)
    }
}
@MainActor final class Stage {
    final class Editor { func close() {} }
    final class Camera { func captureUserCamera() {} }
    enum Owner { case fullStage }
    final class Surface {
        func setOwnerVisibility(_ visible: Bool, owner: Owner) {}
        func detach(from: Owner) {}
    }
    var didHandleCurrentClose = false
    let residentPropEditor = Editor(), cameraCoordinator = Camera(), renderSurfaceController = Surface()
    func close() { finishCurrentClose() }
    \#(closeStage)
}
@MainActor final class Player: AgentSpeechAudioPlaying {
    var waiter: CheckedContinuation<Void, Error>?
    var callbacks: [@MainActor (AgentSpeechPlaybackState) -> Void] = []
    func play(_ data: Data, onPlaybackChanged: @escaping @MainActor (AgentSpeechPlaybackState) -> Void) async throws {
        callbacks.append(onPlaybackChanged)
        onPlaybackChanged(.init(isPlaying: true, level: 0.5))
        try await withCheckedThrowingContinuation { waiter = $0 }
        onPlaybackChanged(.idle)
    }
    func stop() { waiter?.resume(throwing: CancellationError()); waiter = nil }
    func finish(_ error: Error? = nil) {
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
        waiter = nil
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { if !value { print("FAIL: " + label); exit(1) }; count += 1 }
        let app = App(), audio = Player(), status = AgentSpeechStatusStore.shared
        let speech = BailianSpeechSynthesizer(configuration: { .init(apiKey: "fixture") }, statusStore: status, load: { request in
            let body = request.httpMethod == "POST"
                ? Data(#"{"output":{"audio":{"url":"https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/fixture.wav"}}}"#.utf8)
                : Data([1])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, player: audio, onPlaybackChanged: { app.receive($0) })
        app.agentSpeechAnnouncer = AgentSpeechAnnouncer(synthesizer: speech, statusStore: status)
        app.configureStop()
        func playing() async { for _ in 0..<2000 { if audio.waiter != nil { return }; await Task.yield() }; fatalError("play did not start") }
        func ended() async { for _ in 0..<2000 { if !speech.isSpeaking { return }; await Task.yield() }; fatalError("play did not finish") }
        _ = speech.speak("第一句")
        check(app.audioGraph.duckingController.advance() == 1, "synthesis waiting does not duck music")
        await playing()
        check(app.audioGraph.duckingController.advance() <= 0.301, "actual TTS playback must duck music")
        check(app.audioGraph.musicVolume == 0.72, "ducking never changes user volume")
        app.audioGraph.musicVolume = 0.4
        app.audioGraph.setDJSpeaking(false)
        check(app.audioGraph.duckingController.advance() <= 0.301, "legacy disconnected event cannot unduck current TTS")
        let obsolete = audio.callbacks[0]
        _ = speech.speak("第二句")
        await playing()
        obsolete(.idle)
        check(app.audioGraph.duckingController.advance() <= 0.301, "old speech ending cannot restore music during new speech")
        audio.finish()
        await ended()
        check(app.audioGraph.duckingController.advance() == 1 && app.audioGraph.musicVolume == 0.4, "natural end restores gain and preserves changed user volume")
        _ = speech.speak("失败")
        await playing(); audio.finish(URLError(.cannotDecodeContentData)); await ended()
        check(app.audioGraph.duckingController.advance() == 1 && app.avatarRuntime.level == nil, "playback failure restores music and mouth")
        _ = speech.speak("停止")
        await playing(); speech.stopSpeaking(); speech.stopSpeaking()
        check(app.audioGraph.duckingController.advance() == 1 && app.avatarRuntime.level == nil, "repeated stop is harmless and restores music")
        _ = speech.speak("按钮停止")
        await playing(); status.stopSpeaking()
        check(!status.isSpeaking && app.audioGraph.duckingController.advance() == 1 && app.avatarRuntime.level == nil, "shared UI stop binding stops real TTS and restores music/mouth")
        _ = speech.speak("关闭空间")
        await playing(); let stage = Stage(); stage.close(); stage.close()
        check(!status.isSpeaking && app.audioGraph.duckingController.advance() == 1 && app.avatarRuntime.level == nil, "real close-stage cleanup restores music and mouth")
        app.audioGraph.setDJSpeaking(true)
        speech.stopSpeaking()
        check(app.audioGraph.duckingController.advance() <= 0.301, "TTS stop respects independently active legacy voice")
        app.audioGraph.setDJSpeaking(false)
        check(app.audioGraph.duckingController.advance() == 1, "last active speaker restores gain")
        print("PASS: \(count) actual TTS/music ducking checks")
    }
}
"""#
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-ducking-\(UUID())")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: folder) }
let harness = folder.appendingPathComponent("Checks.swift"), binary = folder.appendingPathComponent("checks")
try program.write(to: harness, atomically: true, encoding: .utf8)
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", base.appendingPathComponent("Agent/AgentSpeech.swift").path,
    base.appendingPathComponent("Agent/RustVoiceClient.swift").path,
    base.appendingPathComponent("Agent/StreamingPCMPlayer.swift").path,
    base.appendingPathComponent("AudioEngine/DuckingEnvelope.swift").path, harness.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit(); guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process(); test.executableURL = binary; try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
