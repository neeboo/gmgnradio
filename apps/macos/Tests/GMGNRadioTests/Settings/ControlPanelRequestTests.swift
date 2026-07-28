import Foundation
import Testing
@testable import GMGNRadio

@Suite
struct ControlPanelRequestTests {
    @Test
    func parsesPresenceCommandsFromTheWebView() throws {
        let request = try ControlPanelRequest(message: [
            "id": "request-1",
            "command": "presence.activate",
            "payload": ["id": "mori.blue"],
        ])
        #expect(request.id == "request-1")
        #expect(request.command == .activate(id: "mori.blue"))
    }

    @Test
    func onlyAllowsSecureDownloadURLs() {
        #expect(throws: ControlPanelRequestError.insecureDownloadURL) {
            try ControlPanelRequest(message: [
                "id": "request-2",
                "command": "presence.download",
                "payload": ["url": "http://example.com/mori.zip"],
            ])
        }
    }

    @Test
    func rejectsUnknownCommands() {
        #expect(throws: ControlPanelRequestError.unknownCommand) {
            try ControlPanelRequest(message: [
                "id": "request-3",
                "command": "presence.unknown",
                "payload": [:],
            ])
        }
    }
}
