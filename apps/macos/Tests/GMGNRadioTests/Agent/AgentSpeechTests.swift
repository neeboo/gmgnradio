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

    func stopSpeaking() {}
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
