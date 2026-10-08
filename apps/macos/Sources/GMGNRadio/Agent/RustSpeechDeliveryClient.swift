import Foundation
import CryptoKit

/// Speech queue, replacement, generations and terminal outcomes belong to Rust.
/// This adapter only presents authority commands and submits native receipts.
@MainActor final class RustSpeechDeliveryClient {
    struct Provenance: Codable, Sendable, Equatable {
        let worldID: String?
        let residentScope: String?
        let runID: String?
    }
    struct Identity: Codable, Sendable, Equatable {
        let scopeID: String
        let hostSessionID: String
        let utteranceID: String
        let generation: UInt64
        let provenance: Provenance?
    }
    struct Ticket: Decodable, Sendable {
        let identity: Identity
        let textSHA256: String
        let textBytes: Int
    }
    struct State: Decodable, Sendable { let identity: Identity; let status: String }
    struct Stop: Decodable, Sendable { let identity: Identity; let stopRequestID: String }
    struct View: Decodable, Sendable {
        let revision: UInt64
        let states: [State]
        let ticket: Ticket?
        let stopCommands: [Stop]
    }
    struct ChatDispatch: Decodable, Sendable { let utteranceID: String; let text: String; let delivery: View }
    struct ChatReceipt: Decodable, Sendable { let duplicate: Bool; let dispatch: ChatDispatch?; let delivery: View? }
    typealias Call = @MainActor (String, Data) async throws -> Data
    private let call: Call
    let scopeID: String
    let hostSessionID: String
    init(scopeID: String, hostSessionID: String = UUID().uuidString, voiceClient: RustVoiceClient) {
        self.scopeID = scopeID; self.hostSessionID = hostSessionID
        self.call = { method, input in try await voiceClient.speechDeliveryRequest(method: method, input: input) }
    }
    init(scopeID: String, hostSessionID: String, call: @escaping Call) {
        self.scopeID = scopeID; self.hostSessionID = hostSessionID; self.call = call
    }
    private func request(_ method: String, _ p: [String: Any]) async throws -> View {
        let data = try await call(method, JSONSerialization.data(withJSONObject: p))
        let view = try JSONDecoder().decode(View.self, from: data)
        guard view.states.count <= 32, view.stopCommands.count <= 32,
              view.states.allSatisfy({ $0.identity.scopeID == scopeID && $0.identity.hostSessionID == hostSessionID }),
              view.stopCommands.allSatisfy({ $0.identity.scopeID == scopeID && $0.identity.hostSessionID == hostSessionID }),
              view.ticket.map({ $0.identity.scopeID == scopeID && $0.identity.hostSessionID == hostSessionID }) ?? true else {
            throw RustVoiceError.invalidFrame
        }
        return view
    }
    private var scope: [String: Any] { ["scopeID": scopeID, "hostSessionID": hostSessionID] }
    func enqueue(utteranceID: String, text: String, mode: String, provenance: Provenance? = nil) async throws -> View {
        var p = scope; p["utteranceID"] = utteranceID; p["text"] = text; p["mode"] = mode
        if let provenance { p["provenance"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(provenance)) }
        return try await request("speech_delivery_enqueue", p)
    }
    func wait(afterRevision: UInt64) async throws -> View {
        var p = scope; p["afterRevision"] = afterRevision; p["timeoutMS"] = 25_000
        return try await request("speech_delivery_wait", p)
    }
    func read() async throws -> View { try await request("speech_delivery_read", scope) }
    func cancel() async throws -> View { try await request("speech_delivery_cancel", scope) }
    func chatEvent(requestID: String, kind: String, source: [String: Any]? = nil, testMuted: Bool = false) async throws -> ChatReceipt {
        var p = scope; p["requestID"] = requestID; p["kind"] = kind; p["testMuted"] = testMuted
        if let source { p["source"] = source }
        let receipt = try JSONDecoder().decode(ChatReceipt.self, from: await call("chat_speech_event", JSONSerialization.data(withJSONObject: p)))
        for view in [receipt.delivery,receipt.dispatch?.delivery].compactMap({$0}) {
            guard view.states.count <= 32, view.stopCommands.count <= 32,
                  view.states.allSatisfy({$0.identity.scopeID == scopeID && $0.identity.hostSessionID == hostSessionID}),
                  view.stopCommands.allSatisfy({$0.identity.scopeID == scopeID && $0.identity.hostSessionID == hostSessionID}) else { throw RustVoiceError.invalidFrame }
        }
        return receipt
    }
    func receipt(identity: Identity, kind: String, sequence: UInt64? = nil,
                 frameCount: Int? = nil, stopRequestID: String? = nil) async throws -> View {
        guard identity.scopeID == scopeID, identity.hostSessionID == hostSessionID else { throw RustVoiceError.invalidFrame }
        var p: [String: Any] = ["identity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)), "kind": kind]
        if let sequence { p["sequence"] = sequence }; if let frameCount { p["frameCount"] = frameCount }
        if let stopRequestID { p["stopRequestID"] = stopRequestID }
        return try await request("speech_delivery_receipt", p)
    }
}

/// Executes Rust-issued tickets only. The dictionary associates caller receipts
/// with immutable input; it does not select FIFO order or replacement winners.
@MainActor final class RustSpeechDeliveryPlayback {
    typealias Start = @MainActor (String, RustVoiceConfiguration, RustSpeechDeliveryClient.Ticket) async throws -> any RustVoiceStreaming
    private struct Request {
        let text: String
        let configuration: RustVoiceConfiguration
        let completion: AgentSpeechCompletion?
    }
    private let authority: RustSpeechDeliveryClient
    private let player: any StreamingPCMPlaying
    private let start: Start
    private let onPlaybackChanged: @MainActor (AgentSpeechPlaybackState) -> Void
    private let onPendingChanged: @MainActor (Bool) -> Void
    private let onFailure: @MainActor (Error) -> Void
    private var requests: [String: Request] = [:]
    private var submission: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var active: RustSpeechDeliveryClient.Identity?
    private var stream: (any RustVoiceStreaming)?
    private var launched = Set<String>()
    private var stops = Set<String>()
    private var scheduled = Set<UInt64>()
    private var playedEarly: [UInt64: Int] = [:]
    private var nextSequence: UInt64 = 0
    init(authority: RustSpeechDeliveryClient, player: any StreamingPCMPlaying,
         start: @escaping Start,
         onPlaybackChanged: @escaping @MainActor (AgentSpeechPlaybackState) -> Void,
         onPendingChanged: @escaping @MainActor (Bool) -> Void,
         onFailure: @escaping @MainActor (Error) -> Void) {
        self.authority = authority; self.player = player; self.start = start
        self.onPlaybackChanged = onPlaybackChanged; self.onPendingChanged = onPendingChanged; self.onFailure = onFailure
    }
    func submit(text: String, configuration: RustVoiceConfiguration, mode: String,
                completion: AgentSpeechCompletion?) {
        let id = UUID().uuidString
        requests[id] = Request(text: text, configuration: configuration, completion: completion)
        onPendingChanged(true)
        let previous = submission
        submission = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let view = try await authority.enqueue(utteranceID: id, text: text, mode: mode)
                await apply(view)
                observe()
            } catch { onFailure(error); resolve(id, .failed) }
        }
    }
    func submitIssued(utteranceID: String, text: String, configuration: RustVoiceConfiguration, view: RustSpeechDeliveryClient.View) async {
        guard requests[utteranceID] == nil, !launched.contains(utteranceID),
              view.states.contains(where: { $0.identity.utteranceID == utteranceID }) else { return }
        requests[utteranceID] = Request(text: text, configuration: configuration, completion: nil)
        onPendingChanged(true)
        await apply(view)
        observe()
    }
    func applyIssued(_ view: RustSpeechDeliveryClient.View) async { await apply(view); observe() }
    func cancel() {
        let previous = submission
        submission = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { await apply(try await authority.cancel()); observe() }
            catch {
                // Native stop is still real, but unknown authority state is failure.
                stream?.cancel(); operation?.cancel(); player.stop(); active = nil
                onFailure(error)
                for id in Array(requests.keys) { resolve(id, .failed) }
            }
        }
    }
    private func observe() {
        guard observer == nil else { return }
        observer = Task { [weak self] in
            guard let self else { return }
            defer { observer = nil }
            while !Task.isCancelled && !requests.isEmpty {
                do { await apply(try await authority.wait(afterRevision: revision)) }
                catch {
                    stream?.cancel(); operation?.cancel(); player.stop(); active = nil
                    onFailure(error)
                    for id in Array(requests.keys) { resolve(id, .failed) }
                    return
                }
            }
        }
    }
    private func apply(_ view: RustSpeechDeliveryClient.View) async {
        guard view.revision >= revision else { return }
        revision = view.revision
        for command in view.stopCommands where !stops.contains(command.stopRequestID) {
            stops.insert(command.stopRequestID)
            // The new generation is an authority-issued stop lease, not a PCM identity.
            if active?.utteranceID == command.identity.utteranceID {
                stream?.cancel(); stream = nil; operation?.cancel(); operation = nil
                player.stop(); onPlaybackChanged(.idle); active = nil
                scheduled.removeAll(); playedEarly.removeAll()
            }
            do {
                await apply(try await authority.receipt(identity: command.identity, kind: "stopped", stopRequestID: command.stopRequestID))
            } catch { onFailure(error) }
        }
        guard view.revision == revision else { return }
        for state in view.states {
            switch state.status {
            case "delivered":
                if active?.utteranceID == state.identity.utteranceID {
                    player.stop(); stream?.close(); stream = nil; operation = nil; active = nil; onPlaybackChanged(.idle)
                }
                resolve(state.identity.utteranceID, .finished)
            case "cancelled", "stopped": resolve(state.identity.utteranceID, .cancelled)
            case "failed", "unknown": resolve(state.identity.utteranceID, .failed)
            default: break
            }
        }
        guard let ticket = view.ticket, active == nil, !launched.contains(ticket.identity.utteranceID),
              let request = requests[ticket.identity.utteranceID] else { return }
        guard request.text.utf8.count == ticket.textBytes,
              SHA256.hash(data: Data(request.text.utf8)).map({ String(format: "%02x", $0) }).joined() == ticket.textSHA256 else {
            onFailure(RustVoiceError.invalidFrame); resolve(ticket.identity.utteranceID, .failed); return
        }
        launched.insert(ticket.identity.utteranceID); active = ticket.identity
        nextSequence = 0
        scheduled.removeAll(); playedEarly.removeAll()
        operation = Task { [weak self] in await self?.consume(ticket, request: request) }
    }
    private func consume(_ ticket: RustSpeechDeliveryClient.Ticket, request: Request) async {
        let identity = ticket.identity
        do {
            let opened = try await start(request.text, request.configuration, ticket)
            guard active == identity else { opened.cancel(); return }
            stream = opened
            try player.begin(onPlaybackChanged: onPlaybackChanged)
            await apply(try await authority.receipt(identity: identity, kind: "device_started"))
            while active == identity && !Task.isCancelled {
                let event = try await opened.nextEvent()
                guard active == identity else { return }
                if event.type == "error" { throw RustVoiceError.rejected(event.code ?? "voice_failed") }
                guard event.delivery == identity else { throw RustVoiceError.invalidFrame }
                switch event.type {
                case "audio":
                    guard event.sampleRate == 24_000, event.channels == 1, event.encoding == "pcm16le",
                          let sequence = event.sequence, sequence == nextSequence,
                          let count = event.frameCount, (1...4096).contains(count),
                          let encoded = event.audioBase64, let pcm = Data(base64Encoded: encoded), pcm.count == count * 2 else { throw RustVoiceError.invalidFrame }
                    try player.schedulePacket(pcm, frameCount: count) { [weak self] in
                        Task { @MainActor in await self?.played(identity, sequence: sequence, count: count) }
                    }
                    nextSequence += 1
                    // ACK scheduling immediately; waiting for append/finish would deadlock Rust's window.
                    await apply(try await authority.receipt(identity: identity, kind: "scheduled", sequence: sequence, frameCount: count))
                    guard active == identity else { return }
                    scheduled.insert(sequence)
                    if let played = playedEarly.removeValue(forKey: sequence) { await self.played(identity, sequence: sequence, count: played) }
                case "input_finished": break // Provider EOF is not audible completion.
                case "delivered":
                    // Delivered is emitted only after Rust has accepted every real played ACK.
                    await apply(try await authority.read())
                    return
                case "error": throw RustVoiceError.rejected(event.code ?? "voice_failed")
                default: throw RustVoiceError.invalidFrame
                }
            }
        } catch {
            guard active == identity, !(error is CancellationError) else { return }
            onFailure(error)
            do { await apply(try await authority.receipt(identity: identity, kind: "failed")) }
            catch { stream?.cancel(); player.stop(); active = nil; resolve(identity.utteranceID, .failed) }
        }
    }
    private func played(_ identity: RustSpeechDeliveryClient.Identity, sequence: UInt64, count: Int) async {
        guard active == identity else { return }
        guard scheduled.remove(sequence) != nil else { playedEarly[sequence] = count; return }
        do { await apply(try await authority.receipt(identity: identity, kind: "played", sequence: sequence, frameCount: count)) }
        catch {
            onFailure(error)
            do { await apply(try await authority.receipt(identity: identity, kind: "failed")) }
            catch { stream?.cancel(); operation?.cancel(); player.stop(); active = nil; resolve(identity.utteranceID, .failed) }
        }
    }
    private func resolve(_ id: String, _ outcome: AgentSpeechOutcome) {
        guard let request = requests.removeValue(forKey: id) else { return }
        launched.remove(id)
        request.completion?(outcome); onPendingChanged(!requests.isEmpty)
    }
}
