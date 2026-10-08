import Foundation

// Compiled with the production speech/client/player sources. This device never
// instantiates AVAudioEngine: callbacks are deliberately controlled by the test.
@MainActor private final class DeliveryDevice: StreamingPCMDevice {
    var callbacks: [@Sendable () -> Void] = []
    var packets = 0
    var stops = 0
    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {}
    func schedule(_ samples: [Float], onPlayed: @escaping @Sendable () -> Void) throws {
        precondition(!samples.isEmpty)
        packets += 1
        callbacks.append(onPlayed)
    }
    func stop() { stops += 1 }
    func drain() {
        let old = callbacks
        callbacks.removeAll()
        old.forEach { $0() }
    }
}

@main private struct SpeechDeliveryHTTPConsumer {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("private descriptor required") }
        let descriptor = URL(fileURLWithPath: CommandLine.arguments[1])
        let client = RustVoiceClient(root: descriptor.deletingLastPathComponent(), endpointURL: descriptor, allowsLaunching: false)
        var allowStopReceipt = false
        let authority = RustSpeechDeliveryClient(scopeID: "swift-http", hostSessionID: "swift-private-host", call: { method, data in
            let params = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if method == "speech_delivery_receipt", params?["kind"] as? String == "stopped" {
                // Delay only the actual HTTP call; no authority response is mocked.
                while !allowStopReceipt { try await Task.sleep(for: .milliseconds(5)) }
            }
            return try await client.speechDeliveryRequest(method: method, input: data)
        })
        let device = DeliveryDevice()
        var outcomes: [AgentSpeechOutcome] = []
        var failures: [String] = []
        let playback = RustSpeechDeliveryPlayback(authority: authority,
            player: StreamingPCMPlayer(makeDevice: { device }),
            start: { text, configuration, ticket in
                try await client.startDeliveryTTS(text: text, configuration: configuration, ticket: ticket)
            }, onPlaybackChanged: { _ in }, onPendingChanged: { _ in },
            onFailure: { failures.append(String(describing: $0)) })
        func wait(_ name: String, _ condition: @MainActor () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while try await !condition() {
                precondition(failures.isEmpty, failures.joined(separator: ","))
                precondition(Date() < deadline, "timeout: " + name)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let configuration = RustVoiceConfiguration(apiKey: "private-test-only")
        playback.submit(text: "first", configuration: configuration, mode: "fifo", completion: { outcomes.append($0) })
        playback.submit(text: "second", configuration: configuration, mode: "fifo", completion: { outcomes.append($0) })
        try await wait("first scheduled and provider EOF") {
            let view = try await authority.read()
            return device.packets == 1 && view.states.first?.status == "draining"
        }
        let first = try await authority.read()
        precondition(first.ticket == nil && outcomes.isEmpty && device.packets == 1)
        let firstIdentity = first.states[0].identity
        // Scheduling duplicate is a real HTTP ACK, with no revision change.
        let duplicate = try await authority.receipt(identity: firstIdentity, kind: "scheduled", sequence: 0, frameCount: 2)
        precondition(duplicate.revision == first.revision)
        device.drain()
        try await wait("FIFO second scheduled") {
            let view = try await authority.read()
            return outcomes == [.finished] && device.packets == 2 && view.states.count == 2 && view.states[1].status == "draining"
        }
        let second = try await authority.read()
        precondition(second.states[0].status == "delivered" && second.states[1].status != "delivered")
        let playedDuplicate = try await authority.receipt(identity: firstIdentity, kind: "played", sequence: 0, frameCount: 2)
        precondition(playedDuplicate.revision == second.revision)
        // Cancellation must stop the actual mock device before its authority ACK.
        playback.cancel()
        try await wait("stop lease remains gated before native ACK") {
            let view = try await authority.read()
            return view.stopCommands.count == 1 && view.states[1].status == "stopping"
        }
        let waitingForStop = try await authority.read()
        precondition(waitingForStop.ticket == nil && outcomes == [.finished])
        allowStopReceipt = true
        try await wait("native stop acknowledged") { outcomes == [.finished, .cancelled] }
        let cancelled = try await authority.read()
        precondition(cancelled.stopCommands.isEmpty && device.stops > 0)
        device.drain() // A callback from the obsolete PCM generation is harmless.
        try await Task.sleep(for: .milliseconds(50))
        let afterLateCallback = try await authority.read()
        precondition(afterLateCallback.revision == cancelled.revision)
        do {
            _ = try await authority.receipt(identity: second.states[1].identity, kind: "played", sequence: 0, frameCount: 2)
            fatalError("old generation accepted")
        } catch {}
        playback.submit(text: "third", configuration: configuration, mode: "fifo", completion: { outcomes.append($0) })
        try await wait("next generation scheduled") { device.packets == 3 }
        device.drain()
        try await wait("next generation delivered") { outcomes == [.finished, .cancelled, .finished] }
        precondition(failures.isEmpty)
        print("PASS actual private Rust HTTP/SSE/SQLite -> production Swift consumer -> mock PCM scheduled/played; EOF/FIFO/duplicate ACK/stop/late-generation")
    }
}
