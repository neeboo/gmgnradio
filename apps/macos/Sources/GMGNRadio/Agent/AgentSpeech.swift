import AppKit
import AVFoundation
import Observation

// MARK: - Status

/// 轻量语音状态：只记录最近一次朗读失败，不影响聊天文字。
@MainActor
@Observable
final class AgentSpeechStatusStore {
    static let shared = AgentSpeechStatusStore()

    var lastErrorMessage: String?
    var isSpeaking = false
    @ObservationIgnored
    var onStopSpeaking: (@MainActor () -> Void)?

    func stopSpeaking() {
        onStopSpeaking?()
    }
}

// MARK: - Delivery outcome

/// 一次朗读请求的最终交付结果。App 只有在 `finished` 时才能把该轮回复记为
/// “已语音交付”；`cancelled` 与 `failed` 一律不得触发语音记忆确认。
enum AgentSpeechOutcome: Equatable, Sendable {
    /// 整段语音自然播放完毕（Bailian 为全部分段全部播完）。
    case finished
    /// 被新朗读替换、被用户停止，或从未开始（朗读被禁用 / 文本为空）。
    case cancelled
    /// 启动、网络、合成或播放失败。
    case failed
}

/// 朗读交付回调：同一次朗读请求恰好调用一次，永远在 MainActor 上触发。
typealias AgentSpeechCompletion = @MainActor (AgentSpeechOutcome) -> Void

// MARK: - Protocol

@MainActor
protocol SpeechSynthesizing: AnyObject {
    /// 开始朗读；返回是否成功启动。失败只应记录状态，不应影响聊天结果。
    @discardableResult
    func speak(_ text: String) -> Bool

    /// 带交付回调的朗读：回调恰好一次；只有整段语音自然播完才报告 `.finished`。
    @discardableResult
    func speak(_ text: String, completion: @escaping AgentSpeechCompletion) -> Bool

    func stopSpeaking()
}

// MARK: - System voice (NSSpeechSynthesizer boundary)

/// 单次朗读的真实语音引擎边界；每个 utterance 使用独立实例以可靠归属回调，
/// 停止/替换后迟到的 didFinish 只会归属旧实例，不会误报新朗读成功。
@MainActor
protocol SystemVoiceSpeaking: AnyObject {
    /// 引擎自然结束或出错时回调（finishedSpeaking: Bool），只会触发一次。
    var onFinished: (@MainActor (Bool) -> Void)? { get set }

    @discardableResult
    func startSpeaking(_ text: String) -> Bool

    func stopSpeaking()
}

/// NSSpeechSynthesizer 封装：弱 delegate + MainActor 回跳，与既有实现一致。
@MainActor
private final class MacSystemVoice: NSObject, SystemVoiceSpeaking, NSSpeechSynthesizerDelegate {
    private let synthesizer = NSSpeechSynthesizer()
    var onFinished: (@MainActor (Bool) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    @discardableResult
    func startSpeaking(_ text: String) -> Bool {
        synthesizer.startSpeaking(text)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking()
    }

    nonisolated func speechSynthesizer(
        _ sender: NSSpeechSynthesizer,
        didFinishSpeaking finishedSpeaking: Bool
    ) {
        let finished = finishedSpeaking
        Task { @MainActor [weak self] in self?.onFinished?(finished) }
    }
}

/// 基于 NSSpeechSynthesizer 的本地语音合成。每次朗读持有独立引擎实例：
/// 完成的回调只能通过“当前引擎”身份匹配，旧实例的任何迟到事件都不再有效。
@MainActor
final class MacSpeechSynthesizer: SpeechSynthesizing {
    private let statusStore: AgentSpeechStatusStore
    private let makeVoice: @MainActor () -> any SystemVoiceSpeaking
    private var voice: (any SystemVoiceSpeaking)?
    private var pendingCompletion: AgentSpeechCompletion?

    init(
        statusStore: AgentSpeechStatusStore = .shared,
        makeVoice: @escaping @MainActor () -> any SystemVoiceSpeaking = { MacSystemVoice() }
    ) {
        self.statusStore = statusStore
        self.makeVoice = makeVoice
    }

    @discardableResult
    func speak(_ text: String) -> Bool {
        beginUtterance(text, completion: nil)
    }

    @discardableResult
    func speak(_ text: String, completion: @escaping AgentSpeechCompletion) -> Bool {
        beginUtterance(text, completion: completion)
    }

    private func beginUtterance(_ text: String, completion: AgentSpeechCompletion?) -> Bool {
        stopSpeaking()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(.cancelled)
            return false
        }
        statusStore.lastErrorMessage = nil
        let voice = makeVoice()
        self.voice = voice
        pendingCompletion = completion
        voice.onFinished = { [weak self, weak voice] finished in
            guard let self, let voice, self.voice === voice else { return }
            self.settleUtterance(
                voice,
                outcome: finished ? .finished : .failed,
                recordFailureMessage: !finished
            )
        }
        guard voice.startSpeaking(trimmed) else {
            settleUtterance(voice, outcome: .failed, recordFailureMessage: false)
            return false
        }
        return true
    }

    func stopSpeaking() {
        guard let voice else { return }
        self.voice = nil
        voice.onFinished = nil
        voice.stopSpeaking()
        if let completion = pendingCompletion {
            pendingCompletion = nil
            completion(.cancelled)
        }
    }

    private func settleUtterance(
        _ voice: any SystemVoiceSpeaking,
        outcome: AgentSpeechOutcome,
        recordFailureMessage: Bool
    ) {
        guard self.voice === voice else { return }
        self.voice = nil
        voice.onFinished = nil
        if recordFailureMessage {
            statusStore.lastErrorMessage =
                "语音朗读失败，请检查系统语音设置；文字回复不受影响。"
        }
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(outcome)
    }
}

// MARK: - Announcer

/// Agent 回复完成后的自动朗读入口；朗读失败绝不影响文字回复。
@MainActor
final class AgentSpeechAnnouncer {
    private let synthesizer: any SpeechSynthesizing
    private let statusStore: AgentSpeechStatusStore

    var isEnabled: Bool

    init(
        synthesizer: any SpeechSynthesizing,
        isEnabled: Bool = true,
        statusStore: AgentSpeechStatusStore = .shared
    ) {
        self.synthesizer = synthesizer
        self.isEnabled = isEnabled
        self.statusStore = statusStore
    }

    func announce(_ text: String) {
        performAnnounce(text, completion: nil)
    }

    /// 带交付回调的朗读入口：每次调用恰好回调一次。
    /// - `.finished`：整段语音自然播完，App 才应把该轮记为“已语音交付”。
    /// - `.cancelled`：朗读被禁用 / 文本为空 / 被新朗读替换 / 用户停止。
    /// - `.failed`：启动、网络、合成或播放失败。
    func announce(_ text: String, completion: @escaping AgentSpeechCompletion) {
        performAnnounce(text, completion: completion)
    }

    private func performAnnounce(_ text: String, completion: AgentSpeechCompletion?) {
        guard isEnabled else {
            completion?(.cancelled)
            return
        }
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            completion?(.cancelled)
            return
        }
        statusStore.lastErrorMessage = nil
        if !synthesizer.speak(trimmed, completion: { [weak self] outcome in
            guard let self else { return }
            if outcome == .failed, self.statusStore.lastErrorMessage == nil {
                self.statusStore.lastErrorMessage =
                    "语音朗读启动失败；文字回复不受影响。"
            }
            completion?(outcome)
        }), statusStore.lastErrorMessage == nil {
            statusStore.lastErrorMessage =
                "语音朗读启动失败；文字回复不受影响。"
        }
    }

    func stop() {
        synthesizer.stopSpeaking()
    }
}

// MARK: - Bailian text-to-speech (never a conversation model)

enum BailianTTSVoice: String, CaseIterable, Identifiable, Sendable {
    case cherry = "Cherry", serena = "Serena", ethan = "Ethan", chelsie = "Chelsie"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cherry: "芊悦 · 明亮女声"
        case .serena: "苏瑶 · 温柔女声"
        case .ethan: "晨煦 · 活力男声"
        case .chelsie: "千雪 · 轻柔女声"
        }
    }
}

struct BailianTTSConfiguration: Sendable {
    static let model = "qwen3-tts-flash"
    let apiKey: String
    var voiceID: String = BailianTTSVoice.cherry.rawValue
}

enum BailianTTSError: LocalizedError {
    case missingKey, invalidVoice, invalidResponse, http(Int), playback
    var errorDescription: String? {
        switch self {
        case .missingKey: "请先在语音设置中填写百炼密钥；文字回复不受影响。"
        case .invalidVoice: "请选择受支持的百炼朗读音色；文字回复不受影响。"
        case .invalidResponse: "百炼未返回可用的语音；文字回复不受影响。"
        case .http(let code): "百炼朗读请求失败（\(code)）；请检查密钥与服务额度，文字回复不受影响。"
        case .playback: "语音播放失败；文字回复不受影响。"
        }
    }
}

enum BailianTTSWire {
    // Official HTTP contract and model-specific voices:
    // https://help.aliyun.com/zh/model-studio/qwen-tts-api
    // https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list
    static func request(text: String, configuration: BailianTTSConfiguration) throws -> URLRequest {
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw BailianTTSError.missingKey }
        guard BailianTTSVoice(rawValue: configuration.voiceID) != nil else { throw BailianTTSError.invalidVoice }
        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": BailianTTSConfiguration.model,
            "input": ["text": text, "voice": configuration.voiceID, "language_type": "Auto"],
        ])
        return request
    }

    static func audioURL(_ data: Data) throws -> URL {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [String: Any],
              let audio = output["audio"] as? [String: Any],
              let address = audio["url"] as? String,
              var parts = URLComponents(string: address),
              let host = parts.host?.lowercased(), host.hasSuffix(".aliyuncs.com"),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil
        else { throw BailianTTSError.invalidResponse }
        // Official responses can contain signed HTTP OSS URLs. Keep the signature
        // unchanged, but only fetch through TLS; never forward the API credential.
        parts.scheme = "https"
        guard let url = parts.url else { throw BailianTTSError.invalidResponse }
        return url
    }

    static func textChunks(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        let endings = CharacterSet(charactersIn: "。！？.!?；;\n")
        var result: [String] = [], start = 0
        while start < scalars.count {
            var end = min(start + 600, scalars.count)
            if end < scalars.count,
               let boundary = (start..<end).last(where: { endings.contains(scalars[$0]) }) {
                end = boundary + 1
            }
            result.append(String(String.UnicodeScalarView(scalars[start..<end])))
            start = end
        }
        return result
    }
}

struct AgentSpeechPlaybackState: Equatable, Sendable {
    let isPlaying: Bool
    let level: Float
    static let idle = Self(isPlaying: false, level: 0)

    init(isPlaying: Bool, level: Float) {
        self.isPlaying = isPlaying
        self.level = isPlaying && level.isFinite ? min(1, max(0, level)) : 0
    }

    static func normalizedLevel(decibels: Float) -> Float {
        guard decibels.isFinite, decibels > -60 else { return 0 }
        return pow(10, min(0, decibels) / 20)
    }
}

@MainActor protocol AgentSpeechAudioPlaying: AnyObject {
    func play(_ data: Data, onPlaybackChanged: @escaping @MainActor (AgentSpeechPlaybackState) -> Void) async throws
    func stop()
}

/// The hardware boundary; lifecycle and metering scheduling stay in the player.
@MainActor protocol AgentSpeechAudioDevice: AnyObject {
    var onFinished: (@MainActor (Bool) -> Void)? { get set }
    func start() -> Bool
    func stop()
    func measuredDecibels() -> Float
}

@MainActor private final class AgentSpeechAVAudioDevice: NSObject, AgentSpeechAudioDevice, AVAudioPlayerDelegate {
    private let audio: AVAudioPlayer
    var onFinished: (@MainActor (Bool) -> Void)?

    init(data: Data) throws {
        audio = try AVAudioPlayer(data: data)
        super.init()
        audio.isMeteringEnabled = true
        audio.delegate = self
    }

    func start() -> Bool { audio.play() }
    func stop() { audio.stop(); audio.delegate = nil }
    func measuredDecibels() -> Float {
        guard audio.isPlaying else { return -160 }
        audio.updateMeters()
        return (0..<audio.numberOfChannels).map { audio.averagePower(forChannel: $0) }.max() ?? -160
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinished?(flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.onFinished?(false) }
    }
}

@MainActor final class AgentSpeechAudioPlayer: AgentSpeechAudioPlaying {
    private let makeDevice: @MainActor (Data) throws -> any AgentSpeechAudioDevice
    private var device: (any AgentSpeechAudioDevice)?
    private var identity: UUID?
    private var completion: CheckedContinuation<Void, Error>?
    private var playbackChanged: (@MainActor (AgentSpeechPlaybackState) -> Void)?
    private var meteringTask: Task<Void, Never>?

    init(makeDevice: @escaping @MainActor (Data) throws -> any AgentSpeechAudioDevice = { try AgentSpeechAVAudioDevice(data: $0) }) {
        self.makeDevice = makeDevice
    }

    func play(_ data: Data, onPlaybackChanged: @escaping @MainActor (AgentSpeechPlaybackState) -> Void) async throws {
        stop()
        try Task.checkCancellation()
        let next: any AgentSpeechAudioDevice
        do { next = try makeDevice(data) }
        catch { onPlaybackChanged(.idle); throw BailianTTSError.playback }
        let current = UUID()
        identity = current; device = next; playbackChanged = onPlaybackChanged
        next.onFinished = { [weak self] succeeded in
            self?.finish(current, result: succeeded ? .success(()) : .failure(BailianTTSError.playback))
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                guard next.start() else { finish(current, result: .failure(BailianTTSError.playback)); return }
                sample(current)
                meteringTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                        guard let self, self.identity == current, !Task.isCancelled else { return }
                        self.sample(current)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(current, result: .failure(CancellationError())) }
        }
    }

    func stop() {
        guard let identity else { return }
        finish(identity, result: .failure(CancellationError()))
    }

    private func sample(_ current: UUID) {
        guard identity == current, let device else { return }
        playbackChanged?(.init(isPlaying: true, level: AgentSpeechPlaybackState.normalizedLevel(decibels: device.measuredDecibels())))
    }

    private func finish(_ current: UUID, result: Result<Void, Error>) {
        guard identity == current else { return }
        identity = nil
        meteringTask?.cancel(); meteringTask = nil
        device?.onFinished = nil; device?.stop(); device = nil
        let observer = playbackChanged; playbackChanged = nil
        let callback = completion; completion = nil
        observer?(.idle)
        callback?.resume(with: result)
    }
}

private final class BailianTTSNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor final class BailianSpeechSynthesizer: SpeechSynthesizing {
    private static let session = URLSession(configuration: .ephemeral, delegate: BailianTTSNoRedirects(), delegateQueue: nil)
    private let configuration: @MainActor () -> BailianTTSConfiguration
    private let statusStore: AgentSpeechStatusStore
    private let load: @MainActor (URLRequest) async throws -> (Data, URLResponse)
    private let player: any AgentSpeechAudioPlaying
    private let onPlaybackChanged: @MainActor (AgentSpeechPlaybackState) -> Void
    private var activePlayback: UUID?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var pendingCompletion: AgentSpeechCompletion?
    private(set) var isSpeaking = false {
        didSet { statusStore.isSpeaking = isSpeaking }
    }

    init(configuration: @escaping @MainActor () -> BailianTTSConfiguration,
         statusStore: AgentSpeechStatusStore = .shared,
         load: @escaping @MainActor (URLRequest) async throws -> (Data, URLResponse) = { try await BailianSpeechSynthesizer.session.data(for: $0) },
         player: any AgentSpeechAudioPlaying = AgentSpeechAudioPlayer(),
         onPlaybackChanged: @escaping @MainActor (AgentSpeechPlaybackState) -> Void = { _ in }) {
        self.configuration = configuration; self.statusStore = statusStore
        self.load = load; self.player = player
        self.onPlaybackChanged = onPlaybackChanged
    }

    @discardableResult func speak(_ text: String) -> Bool {
        beginUtterance(text, completion: nil)
    }

    @discardableResult func speak(_ text: String, completion: @escaping AgentSpeechCompletion) -> Bool {
        beginUtterance(text, completion: completion)
    }

    private func beginUtterance(_ text: String, completion: AgentSpeechCompletion?) -> Bool {
        stopSpeaking()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            completion?(.cancelled)
            return false
        }
        statusStore.lastErrorMessage = nil
        let settings = configuration(), current = generation
        let chunks = BailianTTSWire.textChunks(text)
        do { _ = try BailianTTSWire.request(text: chunks[0], configuration: settings) }
        catch {
            statusStore.lastErrorMessage = (error as? BailianTTSError)?.errorDescription
            completion?(.failed)
            return false
        }
        pendingCompletion = completion
        isSpeaking = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == current {
                    activePlayback = nil; onPlaybackChanged(.idle)
                    isSpeaking = false; operation = nil
                }
            }
            do {
                for chunk in chunks {
                    try requireCurrent(current)
                    let request = try BailianTTSWire.request(text: chunk, configuration: settings)
                    let (responseData, response) = try await load(request)
                    try requireCurrent(current)
                    try checkHTTP(response)
                    let url = try BailianTTSWire.audioURL(responseData)
                    var download = URLRequest(url: url); download.timeoutInterval = 60
                    let (audio, audioResponse) = try await load(download)
                    try requireCurrent(current)
                    try checkHTTP(audioResponse)
                    guard !audio.isEmpty, audio.count <= 16 * 1_048_576 else { throw BailianTTSError.invalidResponse }
                    let playback = UUID()
                    activePlayback = playback
                    do {
                        try await player.play(audio, onPlaybackChanged: { [weak self] state in
                            guard let self, self.generation == current, self.activePlayback == playback else { return }
                            self.onPlaybackChanged(state)
                        })
                    }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw BailianTTSError.playback }
                    try requireCurrent(current)
                    activePlayback = nil
                    onPlaybackChanged(.idle)
                }
                resolve(current, .finished)
            } catch {
                guard generation == current, !Task.isCancelled, !(error is CancellationError) else { return }
                statusStore.lastErrorMessage = (error as? BailianTTSError)?.errorDescription
                    ?? "百炼语音连接失败，请检查网络；文字回复不受影响。"
                resolve(current, .failed)
            }
        }
        return true
    }

    func stopSpeaking() {
        generation = UUID()
        activePlayback = nil
        operation?.cancel(); operation = nil
        player.stop(); isSpeaking = false
        onPlaybackChanged(.idle)
        if let completion = pendingCompletion {
            pendingCompletion = nil
            completion(.cancelled)
        }
    }

    /// 只允许当前 generation 的朗读结算回调；迟到/旧的 operation 无法报告成功。
    private func resolve(_ current: UUID, _ outcome: AgentSpeechOutcome) {
        guard generation == current else { return }
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(outcome)
    }

    private func requireCurrent(_ current: UUID) throws {
        guard generation == current else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw BailianTTSError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw BailianTTSError.http(http.statusCode) }
    }
}
