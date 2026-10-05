#!/usr/bin/env python3
"""Compile production reply-routing slices with device-free test boundaries."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
settings = (repo / "apps/macos/UnityHost/UnityProductSettings.swift").read_text()
host = (repo / "apps/macos/UnityHost/UnityMediaHost.swift").read_text()
methods = settings.split("    var autoSpeakReplies:", 1)[1].split("    func close()", 1)[0]
save = settings.split('        case "agent.save":', 1)[1].split('        case "agent.backend"', 1)[0]
language = settings.split('        case "app.language":', 1)[1].split('        case "settings.load"', 1)[0]
route = host.split('        if let events = conversation["events"]', 1)[1].split('        conversation["capabilities"]', 1)[0]
send_cancel = host.split('            case "chat.send":', 1)[1].split('            default: return false', 1)[0]
program = r'''
import Foundation
@MainActor protocol SpeechSynthesizing: AnyObject { func speak(_ text: String); func stopSpeaking() }
@MainActor final class AgentSpeechStatusStore { var isSpeaking = false; var lastErrorMessage: String? }
struct Config {}
struct Preferences { func configuration(for: String, includesEnvironment: Bool) -> Config { Config() } }
struct ResidentPreferences { init(defaults: UserDefaults) {}; func savePersona(_ persona: String) {} }
@MainActor final class RustSpeechSynthesizer: SpeechSynthesizing {
    static var spoken: [String] = []; static var stops = 0
    init(configuration: () -> Config, statusStore: AgentSpeechStatusStore, client: Int) {}
    func speak(_ text: String) { Self.spoken.append(text) }
    func stopSpeaking() { Self.stops += 1 }
}
@MainActor final class Settings {
    static let autoSpeakKey = "unity.agent.autoSpeakReplies"
    static let localeKey = "unity.ui.locale"
    let defaults: UserDefaults
    let speech = Preferences(), client = 0
    let replyStatus = AgentSpeechStatusStore()
    var replySpeech: (any SpeechSynthesizing)?, preview: RustSpeechSynthesizer?
    init(_ defaults: UserDefaults) { self.defaults = defaults }
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
    func send(requestID: UInt64,text: String) -> Bool { accepts }
    func cancel(requestID: UInt64) -> Bool { false }
}
@MainActor final class Host {
    let productSettings: Settings, chat = Chat()
    var replySpeechRequestID: UInt64?
    var announcedReplyRequestID: UInt64?
    init(_ settings: Settings) {productSettings = settings}
    func command(_ value: [String:Any]) -> Bool {
        guard let op = value["op"] as? String else {return false}
        switch op { case "chat.send": ''' + send_cancel + r'''
        default: return false }
    }
    func poll(_ conversation: [String:Any]) {
        if let events = conversation["events"]''' + route + r'''
    }
}
@main struct Test {
    @MainActor static func main() {
        let suite = "gmgn-unity-speech-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let settings = Settings(defaults), host = Host(settings)
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
        precondition(host.command(["op":"chat.send","requestID":NSNumber(value:1),"text":"hi"]))
        func event(_ id: UInt64, _ kind: String, _ text: String = "") -> [String:Any] { ["events":[["requestID":NSNumber(value:id),"kind":kind,"text":text]]] }
        host.poll(event(1,"delta","partial")); precondition(RustSpeechSynthesizer.spoken.isEmpty)
        host.poll(event(1,"reply","final")); host.poll(event(1,"reply","duplicate"))
        precondition(RustSpeechSynthesizer.spoken == ["final"])
        precondition(host.command(["op":"chat.cancel","requestID":NSNumber(value:1)]))
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
        print("PASS persisted auto-speak, final-only once, stale/cancel/failure/disabled suppression; no device/service requests")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="gmgn-unity-speech-") as directory:
    source = Path(directory) / "test.swift"
    source.write_text(program)
    executable = Path(directory) / "test"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
