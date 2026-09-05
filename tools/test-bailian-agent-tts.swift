import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/AgentSpeech.swift")
let program = #"""
import Foundation
@MainActor final class Audio: AgentSpeechAudioPlaying {
    var played: [Data] = []
    var stops = 0
    var reject = false
    var hold = false
    var waiter: CheckedContinuation<Void, Error>?
    func play(_ data: Data) async throws {
        if reject { throw URLError(.cannotDecodeContentData) }
        played.append(data)
        if hold { try await withCheckedThrowingContinuation { waiter = $0 } }
    }
    func stop() { stops += 1; waiter?.resume(throwing: CancellationError()); waiter = nil }
}
@MainActor final class Configuration { var value = BailianTTSConfiguration(apiKey: "fixture-key") }
@MainActor final class HTTP {
    var requests: [URLRequest] = []
    var status = 200
    var badJSON = false
    var hold = false
    var waiter: CheckedContinuation<Void, Never>?
    var cancellationObserved = false
    func data(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if hold {
            hold = false
            await withCheckedContinuation { waiter = $0 }
            cancellationObserved = Task.isCancelled
        }
        let body: Data
        if request.httpMethod == "POST" {
            body = badJSON ? Data("private-service-message".utf8) : try JSONSerialization.data(withJSONObject: ["output": ["audio": ["url": "http://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/fixture.wav?Signature=private"]]])
        } else { body = Data("fixture-audio".utf8) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) { guard value else { fatalError("FAIL: " + name) }; count += 1 }
        func settle(_ speech: BailianSpeechSynthesizer) async { for _ in 0..<2000 { if !speech.isSpeaking { return }; await Task.yield() }; fatalError("speech did not settle") }
        let http = HTTP(), audio = Audio(), status = AgentSpeechStatusStore()
        let config = Configuration()
        let speech = BailianSpeechSynthesizer(configuration: { config.value }, statusStore: status, load: { try await http.data($0) }, player: audio)
        let announcer = AgentSpeechAnnouncer(synthesizer: speech, statusStore: status)
        check(Set(BailianTTSVoice.allCases.map(\.rawValue)) == ["Cherry", "Serena", "Ethan", "Chelsie"], "TTS-specific official voice catalog")
        announcer.announce("你好，我已走到点唱机旁边。")
        check(status.isSpeaking, "observable speech status includes synthesis time")
        await settle(speech)
        check(!status.isSpeaking, "observable speech status clears after completion")
        check(audio.played.count == 1 && status.lastErrorMessage == nil, "agent text synthesizes and plays")
        let request = http.requests[0]
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let input = body["input"] as! [String: Any]
        check(body["model"] as? String == "qwen3-tts-flash" && Set(body.keys) == ["model", "input"], "HTTP synthesis only, no conversation")
        check(input["text"] as? String == "你好，我已走到点唱机旁边。" && input["voice"] as? String == "Cherry" && Set(input.keys) == ["text", "voice", "language_type"], "only supplied reply and synthesis parameters")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "API key on synthesis request")
        check(http.requests[1].value(forHTTPHeaderField: "Authorization") == nil && http.requests[1].url?.scheme == "https", "audio download has no bearer and uses TLS")
        config.value = .init(apiKey: "new-fixture", voiceID: "Serena")
        announcer.announce("换个音色。")
        await settle(speech)
        let changed = try JSONSerialization.jsonObject(with: http.requests[2].httpBody!) as! [String: Any]
        check((changed["input"] as? [String: Any])?["voice"] as? String == "Serena" && http.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer new-fixture", "settings are read for every utterance")
        config.value = .init(apiKey: "")
        announcer.announce("仍保留文字")
        await settle(speech)
        check(status.lastErrorMessage?.contains("密钥") == true && http.requests.count == 4, "missing key explicitly fails without system fallback")
        config.value = .init(apiKey: "fixture", voiceID: "Theo Calm")
        announcer.announce("不能复用 Omni 音色")
        await settle(speech)
        check(status.lastErrorMessage?.contains("音色") == true && http.requests.count == 4, "invalid legacy voice is rejected locally")
        config.value = .init(apiKey: "fixture")
        http.status = 401
        announcer.announce("失败保留文字")
        await settle(speech)
        check(status.lastErrorMessage?.contains("401") == true && !status.lastErrorMessage!.contains("private"), "HTTP error is explicit and sanitized")
        http.status = 200; http.badJSON = true
        announcer.announce("坏响应")
        await settle(speech)
        check(status.lastErrorMessage != nil && !status.lastErrorMessage!.contains("private"), "invalid response is sanitized")
        http.badJSON = false
        audio.reject = true
        announcer.announce("播放失败")
        await settle(speech)
        check(status.lastErrorMessage?.contains("播放") == true, "playback failure is visible")
        audio.reject = false
        http.hold = true
        announcer.announce("旧回答")
        for _ in 0..<500 { if http.waiter != nil { break }; await Task.yield() }
        check(http.waiter != nil, "fixture holds actual request boundary")
        let oldWaiter = http.waiter; http.waiter = nil
        announcer.announce("新回答")
        await settle(speech)
        let playedBeforeLate = audio.played.count
        oldWaiter?.resume()
        for _ in 0..<500 { await Task.yield() }
        check(http.cancellationObserved && audio.played.count == playedBeforeLate && status.lastErrorMessage == nil, "cancelled old HTTP cannot play or overwrite new success")
        http.hold = true
        announcer.announce("主动停止")
        for _ in 0..<500 { if http.waiter != nil { break }; await Task.yield() }
        announcer.stop(); http.waiter?.resume(); http.waiter = nil
        check(!status.isSpeaking, "stop clears observable speech status immediately")
        for _ in 0..<500 { await Task.yield() }
        check(!speech.isSpeaking && audio.played.count == playedBeforeLate && status.lastErrorMessage == nil, "stop cancels pending speech without false failure")
        let longText = String(repeating: "中", count: 1250)
        let chunks = BailianTTSWire.textChunks(longText)
        check(chunks.joined() == longText && chunks.allSatisfy { $0.unicodeScalars.count <= 600 }, "long replies preserve all text within API limit")
        let sentences = String(repeating: "中", count: 400) + "。" + String(repeating: "文", count: 400)
        check(BailianTTSWire.textChunks(sentences).first?.last == "。", "chunking prefers sentence boundaries")
        let start = http.requests.count
        announcer.announce(longText)
        await settle(speech)
        let synthesized = try http.requests.dropFirst(start).filter { $0.httpMethod == "POST" }.map {
            ((try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any])["input"] as! [String: Any])["text"] as! String
        }
        check(synthesized == chunks && http.requests.count - start == 6, "all long reply chunks synthesize and play in order")
        audio.hold = true
        let beforePlaybackCancel = http.requests.count
        announcer.announce(longText)
        for _ in 0..<500 { if audio.waiter != nil { break }; await Task.yield() }
        check(audio.waiter != nil, "fixture holds actual audio playback boundary")
        announcer.stop()
        for _ in 0..<500 { await Task.yield() }
        check(audio.waiter == nil && http.requests.count == beforePlaybackCancel + 2 && status.lastErrorMessage == nil, "stop ends playback and discards unsynthesized remaining chunks")
        audio.hold = false
        for url in ["file:///etc/passwd", "http://127.0.0.1/audio", "https://evil.example/audio", "https://aliyuncs.com.evil.example/audio"] {
            let bytes = try JSONSerialization.data(withJSONObject: ["output": ["audio": ["url": url]]])
            do { _ = try BailianTTSWire.audioURL(bytes); fatalError("unsafe audio URL accepted") } catch { check(true, "untrusted audio URL refused") }
        }
        print("PASS: \(count) Bailian Agent TTS checks")
    }
}
"""#
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-tts-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let main = folder.appendingPathComponent("Checks.swift"), binary = folder.appendingPathComponent("checks")
try program.write(to: main, atomically: true, encoding: .utf8)
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-parse-as-library", source.path, main.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit(); guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let run = Process(); run.executableURL = binary; try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
