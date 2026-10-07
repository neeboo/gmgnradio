import AVFoundation
import Foundation

/// Device capture is shared with the native app; ASR protocols remain in Rust.
@MainActor final class UnityPushToTalkBridge {
    private let client: RustVoiceClient
    private let configuration: () -> RustVoiceConfiguration
    private let preferredDeviceID: () -> String?
    private let submit: (String) -> Void
    private let authorization = MicrophoneAuthorizationGate(status: {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }, requestAccess: { await AVCaptureDevice.requestAccess(for: .audio) })
    private var lease: UUID?
    private var capture: PushToTalkAudioCapture?
    private var session: RustVoiceSession?
    private var startTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: AsyncStream<Data>.Continuation?
    private var committed = false
    private var bytes = 0
    private var closed = false
    private var state = "idle"
    private var errorCode: String?
    private var transcript = ""
    private var transcriptRevision: UInt64 = 0
    var snapshot: [String: Any] { ["state": state, "errorCode": errorCode as Any? ?? NSNull(),
                                  "transcript": transcript, "transcriptRevision": transcriptRevision] }

    init(root: URL, configuration: @escaping () -> RustVoiceConfiguration,
         preferredDeviceID: @escaping () -> String? = { nil }, submitTranscript: @escaping (String) -> Void) {
        client = RustVoiceClient(root: root.appendingPathComponent("gmgn radio/TaskService"), allowsLaunching: false)
        self.configuration = configuration; self.preferredDeviceID = preferredDeviceID; submit = submitTranscript
    }
    func command(_ value: [String: Any]) -> Bool {
        guard !closed, let op = value["op"] as? String else { return false }
        switch op {
        case "voice.press": press()
        case "voice.release": release()
        case "voice.cancel": cancel()
        default: return false
        }
        return true
    }
    func close() { closed = true; cancel() }
    func cancel() {
        lease = nil; startTask?.cancel(); sendTask?.cancel(); eventTask?.cancel(); commitTask?.cancel(); timeoutTask?.cancel()
        startTask = nil; sendTask = nil; eventTask = nil; commitTask = nil; timeoutTask = nil
        continuation?.finish(); continuation = nil
        let oldCapture = capture; capture = nil; Task { await oldCapture?.cancel() }
        session?.cancel(); session = nil; committed = false; bytes = 0; transcript = ""; errorCode = nil; state = "idle"
    }
    private func fail(_ code: String, _ id: UUID) {
        guard lease == id else { return }; NSLog("[UnityASR] failure code=%@ state=%@", code, state); cancel(); errorCode = code; state = "error"
    }
    static func failureCode(_ error: Error) -> String {
        guard let error = error as? RustVoiceError else { return "asr_connect_failed" }
        switch error {
        case .unavailable: return "asr_service_unavailable"
        case .invalidFrame: return "asr_protocol_failed"
        case .rejected(let code):
            switch code {
            case "missing_key": return "asr_configuration_missing"
            case "voice_protocol_error": return "asr_protocol_failed"
            case "voice_transport_error": return "asr_connect_failed"
            case "voice_timeout": return "asr_timeout"
            case "voice_provider_error": return "asr_provider_failed"
            default: return "asr_failed"
            }
        }
    }
    private func press() {
        guard lease == nil else { return }
        let id = UUID(); lease = id; errorCode = nil; transcript = ""; state = "connecting"
        startTask = Task { [weak self] in
            guard let self else { return }
            var phase = "authorization"
            do {
                try await authorization.resolveOrFail(deadline: .seconds(20))
                guard lease == id, !Task.isCancelled else { return }
                phase = "asr_handshake"
                let active = try await client.startASR(configuration: configuration())
                guard lease == id, !Task.isCancelled else { active.cancel(); return }
                NSLog("[UnityASR] phase=asr_handshake ready=1")
                session = active
                let audio = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(8))
                continuation = audio.continuation
                sendTask = Task { [weak self] in
                    do {
                        for await pcm in audio.stream {
                            guard let self, lease == id, !Task.isCancelled else { return }
                            try await active.sendAudio(pcm)
                            guard lease == id else { return }; bytes += pcm.count
                        }
                    } catch { self?.fail("asr_send_failed", id) }
                }
                eventTask = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let event = try await active.nextEvent()
                            guard let self, lease == id else { return }
                            if event.type == "error" { fail(Self.failureCode(RustVoiceError.rejected(event.code ?? "voice_provider_error")), id); return }
                            if event.type == "final", committed {
                                let text = (event.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                cancel()
                                if text.isEmpty { state = "error"; errorCode = "asr_empty" }
                                else { transcript = text; transcriptRevision &+= 1; submit(text) }
                                return
                            }
                            if event.type == "finished" { fail("asr_empty", id); return }
                        }
                    } catch { self?.fail(Self.failureCode(error), id) }
                }
                phase = "capture"
                let device = try PushToTalkAudioCapture(preferredDeviceID: preferredDeviceID(), receive: { pcm, _ in
                    if case .dropped = audio.continuation.yield(pcm) {
                        audio.continuation.finish()
                        Task { @MainActor [weak self] in self?.fail("capture_backpressure", id) }
                    }
                }, onFailure: { _ in Task { @MainActor [weak self] in self?.fail("capture_failed", id) } })
                capture = device
                try await device.start()
                guard lease == id, !Task.isCancelled else { await device.cancel(); return }
                startTask = nil; state = "listening"
            } catch RealtimeVoiceSetupError.microphoneDenied {
                fail("microphone_permission", id)
            } catch RealtimeVoiceSetupError.microphoneAuthorizationPending {
                fail("microphone_permission_pending", id)
            } catch {
                let code = phase == "capture" ? "capture_failed" : Self.failureCode(error)
                NSLog("[UnityASR] phase=%@ failure=%@", phase, code)
                fail(code, id)
            }
        }
    }
    private func release() {
        guard let id = lease else { return }
        guard startTask == nil, let device = capture, let active = session else { cancel(); return }
        guard commitTask == nil else { return }
        state = "transcribing"
        commitTask = Task { [weak self] in
            await device.stop()
            guard let self, lease == id, !Task.isCancelled else { return }
            capture = nil; continuation?.finish(); await sendTask?.value
            guard lease == id, !Task.isCancelled else { return }
            guard bytes > 0 else { fail("capture_empty", id); return }
            do {
                committed = true; try await active.commit()
                guard lease == id else { return }
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.fail("asr_timeout", id)
                }
            } catch { fail("asr_commit_failed", id) }
        }
    }
}
