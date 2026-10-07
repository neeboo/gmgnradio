#!/usr/bin/env python3
"""Execute production bridge with injected device/network boundaries; no real audio claim."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
bridge = (root / 'apps/macos/UnityHost/UnityPushToTalkBridge.swift').read_text().replace('import AVFoundation\n', '')
gate = (root / 'apps/macos/Sources/GMGNRadio/AudioEngine/MicrophoneAuthorizationGate.swift').read_text()
stubs = r'''
import Foundation
enum Auth { case authorized, notDetermined, denied }
enum Media { case audio }
enum AVCaptureDevice {
    static func authorizationStatus(for: Media) -> Auth { .authorized }
    static func requestAccess(for: Media) async -> Bool { true }
}
struct RustVoiceConfiguration {}
enum RustVoiceError: Error { case unavailable, invalidFrame, rejected(String) }
struct RustVoiceEvent: Sendable { let type: String; let text: String?; var code:String? { nil } }
struct Level: Sendable {}
@MainActor enum Mock {
    static var failStart = false
    static var delayStart = false
    static var session: RustVoiceSession?
    static var ready: CheckedContinuation<Void,Never>?
}
@MainActor final class RustVoiceClient {
    init(root: URL, allowsLaunching: Bool) {}
    func startASR(configuration: RustVoiceConfiguration) async throws -> RustVoiceSession {
        if Mock.delayStart { await withCheckedContinuation { Mock.ready = $0 } }
        if Mock.failStart { throw CancellationError() }
        let s = RustVoiceSession(); Mock.session = s; return s
    }
}
@MainActor final class RustVoiceSession {
    let events = AsyncStream<RustVoiceEvent>.makeStream()
    var iterator: AsyncStream<RustVoiceEvent>.Iterator
    var commitCount = 0
    var cancelled = false
    init() { iterator = events.stream.makeAsyncIterator() }
    func nextEvent() async throws -> RustVoiceEvent {
        // AsyncStream iterator is a value; avoid holding inout actor property across await.
        var current = iterator
        let e = await current.next(); iterator = current
        guard let e else { throw CancellationError() }; return e
    }
    func sendAudio(_ pcm: Data) async throws {}
    func commit() async throws { commitCount += 1 }
    func cancel() { cancelled = true; events.continuation.finish() }
}
final class PushToTalkAudioCapture: @unchecked Sendable {
    let receive: @Sendable (Data,Level)->Void
    init(preferredDeviceID: String? = nil, receive: @escaping @Sendable (Data,Level)->Void, onFailure: @escaping @Sendable (Error)->Void) throws { self.receive = receive }
    func start() async throws { receive(Data([1,2]),Level()) }
    func stop() async {}
    func cancel() async {}
}
'''
harness = r'''
@main struct Tests {
    @MainActor static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<1000 { if predicate() { return }; await Task.yield() }
        fatalError("timed out")
    }
    @MainActor static func main() async {
        var sent: [String] = []
        let b = UnityPushToTalkBridge(root: URL(fileURLWithPath:"/tmp"), configuration: { RustVoiceConfiguration() }, submitTranscript: { sent.append($0) })
        assert(b.command(["op":"voice.press"]))
        await wait { b.snapshot["state"] as? String == "listening" }
        let first = Mock.session!
        assert(b.command(["op":"voice.release"]))
        await wait { first.commitCount == 1 }
        first.events.continuation.yield(RustVoiceEvent(type:"final",text:"hello"))
        await wait { sent == ["hello"] }
        assert(b.snapshot["transcript"] as? String == "hello")
        assert(b.snapshot["transcriptRevision"] as? UInt64 == 1)
        assert(b.command(["op":"voice.release"]))
        assert(first.commitCount == 1)
        Mock.delayStart = true
        assert(b.command(["op":"voice.press"]))
        await wait { Mock.ready != nil }
        assert(b.command(["op":"voice.release"]))
        Mock.ready!.resume(); Mock.ready = nil
        for _ in 0..<50 { await Task.yield() }
        assert(b.snapshot["state"] as? String == "idle")
        assert(sent == ["hello"])
        assert(UnityPushToTalkBridge.failureCode(RustVoiceError.rejected("missing_key")) == "asr_configuration_missing")
        assert(UnityPushToTalkBridge.failureCode(RustVoiceError.rejected("voice_protocol_error")) == "asr_protocol_failed")
        assert(UnityPushToTalkBridge.failureCode(RustVoiceError.rejected("voice_provider_error")) == "asr_provider_failed")
        assert(UnityPushToTalkBridge.failureCode(RustVoiceError.unavailable) == "asr_service_unavailable")
        assert(UnityPushToTalkBridge.failureCode(RustVoiceError.rejected("unexpected private error")) == "asr_failed")
        Mock.delayStart = false
        assert(b.command(["op":"voice.press"]))
        await wait { b.snapshot["state"] as? String == "listening" }
        let second = Mock.session!
        assert(b.command(["op":"voice.cancel"]))
        second.events.continuation.yield(RustVoiceEvent(type:"final",text:"late"))
        for _ in 0..<50 { await Task.yield() }
        assert(sent == ["hello"] && second.commitCount == 0)
        Mock.failStart = true
        assert(b.command(["op":"voice.press"]))
        await wait { b.snapshot["state"] as? String == "error" }
        assert(sent == ["hello"])
        b.close(); assert(!b.command(["op":"voice.press"]))
        print("PASS: Unity PTT press/release, one commit, early release, cancel/late final, errors, close")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='gmgn-unity-ptt-') as tmp:
    src = Path(tmp) / 'Tests.swift'
    src.write_text(stubs + gate + bridge + harness)
    binary = Path(tmp) / 'test'
    subprocess.run(['swiftc', '-parse-as-library', str(src), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
