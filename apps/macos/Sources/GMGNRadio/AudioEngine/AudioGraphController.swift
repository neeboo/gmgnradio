import AVFoundation
import Foundation
import os

enum BailianPCMCodecError: LocalizedError {
    case invalidPCM
    case unavailableAudioFormat
    case unavailableAudioBuffer
    case unavailableAudioConverter
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .invalidPCM:
            "百炼返回了无效的语音音频。"
        case .unavailableAudioFormat:
            "无法创建百炼语音播放格式。"
        case .unavailableAudioBuffer:
            "无法创建百炼语音播放缓冲区。"
        case .unavailableAudioConverter:
            "无法创建麦克风语音转换器。"
        case .audioConversionFailed:
            "麦克风音频转换失败。"
        }
    }
}

enum BailianMicrophoneCaptureError: LocalizedError {
    case noMicrophone
    case cannotAddInput
    case cannotAddOutput
    case invalidAudioBuffer

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            "没有找到可用的麦克风。"
        case .cannotAddInput:
            "无法打开当前麦克风。"
        case .cannotAddOutput:
            "无法读取麦克风音频。"
        case .invalidAudioBuffer:
            "麦克风返回了无效音频。"
        }
    }
}

enum BailianPCMCodec {
    static func playbackBuffer(
        from data: Data
    ) throws -> AVAudioPCMBuffer {
        guard !data.isEmpty, data.count.isMultiple(of: 2) else {
            throw BailianPCMCodecError.invalidPCM
        }
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: 24_000,
                channels: 1
            )
        else {
            throw BailianPCMCodecError.unavailableAudioFormat
        }
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            ),
            let target = buffer.floatChannelData?[0]
        else {
            throw BailianPCMCodecError.unavailableAudioBuffer
        }
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0 ..< samples.count {
                target[index] = Float(samples[index]) / 32_768
            }
        }
        buffer.frameLength = frameCount
        return buffer
    }

    static func audioLevel(for data: Data) -> RealtimeDJAudioLevel {
        guard !data.isEmpty, data.count.isMultiple(of: 2) else {
            return RealtimeDJAudioLevel(rms: 0, peak: 0)
        }
        var sum: Double = 0
        var peak: Double = 0
        var sampleCount = 0
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            sampleCount = samples.count
            for sample in samples {
                let normalized = Double(sample) / 32_768
                sum += normalized * normalized
                peak = max(peak, abs(normalized))
            }
        }
        guard sampleCount > 0 else {
            return RealtimeDJAudioLevel(rms: 0, peak: 0)
        }
        return RealtimeDJAudioLevel(
            rms: sqrt(sum / Double(sampleCount)),
            peak: peak
        )
    }
}

final class BailianMicrophonePCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputSampleRate: Double

    init(inputFormat: AVAudioFormat) throws {
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        else {
            throw BailianPCMCodecError.unavailableAudioFormat
        }
        guard
            let converter = AVAudioConverter(
                from: inputFormat,
                to: outputFormat
            )
        else {
            throw BailianPCMCodecError.unavailableAudioConverter
        }
        self.converter = converter
        self.outputFormat = outputFormat
        inputSampleRate = inputFormat.sampleRate
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        let ratio = outputFormat.sampleRate / inputSampleRate
        let capacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * ratio) + 32
        )
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            )
        else {
            throw BailianPCMCodecError.unavailableAudioBuffer
        }

        let inputBox = BailianConverterInputBox(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            guard !inputBox.wasSupplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputBox.wasSupplied = true
            inputStatus.pointee = .haveData
            return inputBox.buffer
        }
        guard status != .error, conversionError == nil else {
            throw conversionError
                ?? BailianPCMCodecError.audioConversionFailed
        }

        let audioBuffer = output.audioBufferList.pointee.mBuffers
        guard
            let bytes = audioBuffer.mData,
            audioBuffer.mDataByteSize > 0
        else {
            return Data()
        }
        return Data(
            bytes: bytes,
            count: Int(audioBuffer.mDataByteSize)
        )
    }
}

private final class BailianConverterInputBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasSupplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

struct BailianMicrophoneDeviceOption: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
}

enum BailianMicrophoneDeviceCatalog {
    static func availableDevices() -> [BailianMicrophoneDeviceOption] {
        discoveryDevices().map {
            BailianMicrophoneDeviceOption(
                id: $0.uniqueID,
                name: $0.localizedName
            )
        }
    }

    static func defaultDeviceID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    fileprivate static func discoveryDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}

enum BailianMicrophoneDeviceSelector {
    static func preferredID(
        requestedID: String? = nil,
        defaultID: String?,
        devices: [BailianMicrophoneDeviceOption]
    ) -> String? {
        if
            let requestedID,
            devices.contains(where: { $0.id == requestedID })
        {
            return requestedID
        }
        if
            let defaultID,
            let defaultDevice = devices.first(
                where: { $0.id == defaultID }
            ),
            !isVirtual(defaultDevice)
        {
            return defaultID
        }
        if let builtIn = devices.first(where: {
            $0.id == "BuiltInMicrophoneDevice"
        }) {
            return builtIn.id
        }
        return devices.first(where: { !isVirtual($0) })?.id
            ?? defaultID
            ?? devices.first?.id
    }

    private static func isVirtual(
        _ device: BailianMicrophoneDeviceOption
    ) -> Bool {
        let value = "\(device.id) \(device.name)".lowercased()
        return [
            "blackhole",
            "loopback",
            "zoomaudiodevice",
            "larkaudiodevice",
            "byteviewaudiodevice",
            "orayvirtual",
        ].contains { value.contains($0) }
    }
}

final class BailianMicrophoneCapture:
    NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    static var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private let session = AVCaptureSession()
    private let logger = Logger(
        subsystem: ProductIdentity.bundleIdentifier,
        category: "BailianMicrophone"
    )
    private let captureQueue = DispatchQueue(
        label: "ai.gmgn.radio.bailian-microphone",
        qos: .userInitiated
    )
    private let receive:
        @Sendable (Data, RealtimeDJAudioLevel) -> Void
    private var deviceInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var sampleCount = 0

    init(
        preferredDeviceID: String? = nil,
        receive: @escaping @Sendable (
            Data,
            RealtimeDJAudioLevel
        ) -> Void
    ) throws {
        self.receive = receive
        super.init()

        let devices = BailianMicrophoneDeviceCatalog.discoveryDevices()
        let options = devices.map {
            BailianMicrophoneDeviceOption(
                id: $0.uniqueID,
                name: $0.localizedName
            )
        }
        let preferredID = BailianMicrophoneDeviceSelector.preferredID(
            requestedID: preferredDeviceID,
            defaultID: AVCaptureDevice.default(for: .audio)?.uniqueID,
            devices: options
        )
        guard
            let device = devices.first(
                where: { $0.uniqueID == preferredID }
            )
        else {
            throw BailianMicrophoneCaptureError.noMicrophone
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = Self.audioSettings
        output.setSampleBufferDelegate(self, queue: captureQueue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else {
            throw BailianMicrophoneCaptureError.cannotAddInput
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            throw BailianMicrophoneCaptureError.cannotAddOutput
        }
        session.addOutput(output)
        deviceInput = input
        audioOutput = output
        logger.info(
            "Selected microphone \(device.localizedName, privacy: .public)"
        )
    }

    func start() {
        captureQueue.async { [self] in
            session.startRunning()
            logger.info("Microphone capture started")
        }
    }

    func stop() {
        captureQueue.async { [self] in
            session.stopRunning()
            logger.info("Microphone capture stopped")
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            return
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0, length.isMultiple(of: 2) else {
            return
        }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: destination
            )
        }
        guard status == noErr else {
            return
        }
        sampleCount += 1
        if sampleCount.isMultiple(of: 25) {
            logger.info(
                "Microphone samples=\(self.sampleCount) bytes=\(data.count)"
            )
        }
        receive(
            data,
            BailianPCMCodec.audioLevel(for: data)
        )
    }
}

@MainActor
final class AudioGraphCompletionDispatcher {
    private var generation: UInt64 = 0

    func prepare(
        _ completion: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor @Sendable () -> Void {
        generation &+= 1
        let scheduledGeneration = generation
        return { [weak self] in
            guard self?.generation == scheduledGeneration else {
                return
            }
            completion()
        }
    }

    func invalidate() {
        generation &+= 1
    }
}

@MainActor
final class DJVoiceDrainTracker {
    private var generation: UInt64 = 0
    private var pendingBufferCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int {
        pendingBufferCount
    }

    func beginBuffer() -> UInt64 {
        pendingBufferCount += 1
        return generation
    }

    func completeBuffer(generation scheduledGeneration: UInt64) {
        guard
            scheduledGeneration == generation,
            pendingBufferCount > 0
        else {
            return
        }
        pendingBufferCount -= 1
        finishWaitersIfDrained()
    }

    func waitUntilDrained() async {
        guard pendingBufferCount > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func reset() {
        generation &+= 1
        pendingBufferCount = 0
        finishWaitersIfDrained()
    }

    private func finishWaitersIfDrained() {
        guard pendingBufferCount == 0 else {
            return
        }
        let waiters = continuations
        continuations.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }
}

enum DJVoicePCMEnhancer {
    static let gainDecibels: Float = 7
    static let linearGain = pow(10, gainDecibels / 20)
    private static let limiterScale = tanh(linearGain)

    static func enhance(_ buffer: AVAudioPCMBuffer) {
        guard
            let channels = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return
        }
        for channel in 0 ..< Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for frame in 0 ..< Int(buffer.frameLength) {
                samples[frame] = enhancedSample(samples[frame])
            }
        }
    }

    static func enhancedSample(_ sample: Float) -> Float {
        tanh(sample * linearGain) / limiterScale
    }
}

@MainActor
final class AudioGraphController: LocalMusicPlaybackGraph {
    private let logger = Logger(
        subsystem: "ai.gmgn.radio",
        category: "AudioGraph"
    )
    private let engine: AVAudioEngine
    private let musicNode = AVAudioPlayerNode()
    private let djVoiceNode = AVAudioPlayerNode()
    private let musicMixer = AVAudioMixerNode()
    private let programMixer = AVAudioMixerNode()
    private let visualBridge: PlaybackVisualFeatureBridge
    private let duckingController: MixerDuckingController
    private var djIsSpeaking = false
    private var residentSpeechPlaying = false
    private let completionDispatcher = AudioGraphCompletionDispatcher()
    private let djVoiceDrainTracker = DJVoiceDrainTracker()
    private var currentFile: AVAudioFile?
    private var tapInstalled = false
    private var microphoneCapture: BailianMicrophoneCapture?
    private var deviceMonitor: AudioDeviceMonitor?
    private var djVoiceChunkCount = 0
    private var djVoicePeakSinceLog: Double = 0

    var musicVolume: Float {
        get { musicNode.volume }
        set { musicNode.volume = min(max(newValue, 0), 1) }
    }

    var djVoiceVolume: Float {
        get { djVoiceNode.volume }
        set { djVoiceNode.volume = min(max(newValue, 0), 1) }
    }

    var isMusicPlaying: Bool {
        musicNode.isPlaying
    }

    /// `LocalMusicPlaybackGraph` 的判据：图自己说自己在不在出声。
    var isPlaying: Bool {
        musicNode.isPlaying
    }

    var playbackPosition: TimeInterval {
        guard
            let renderTime = musicNode.lastRenderTime,
            let playerTime = musicNode.playerTime(forNodeTime: renderTime),
            playerTime.sampleRate > 0
        else {
            return 0
        }
        return max(
            0,
            Double(playerTime.sampleTime) / playerTime.sampleRate
        )
    }

    init(
        visualStore: VisualAudioFeatureStore,
        engine: AVAudioEngine = AVAudioEngine()
    ) {
        self.engine = engine
        visualBridge = PlaybackVisualFeatureBridge(store: visualStore)
        duckingController = MixerDuckingController(
            mixer: musicMixer
        )

        engine.attach(musicNode)
        engine.attach(djVoiceNode)
        engine.attach(musicMixer)
        engine.attach(programMixer)
        engine.connect(musicNode, to: musicMixer, format: nil)
        engine.connect(musicMixer, to: programMixer, format: nil)
        let djVoiceFormat = AVAudioFormat(
            standardFormatWithSampleRate: 24_000,
            channels: 1
        )
        engine.connect(
            djVoiceNode,
            to: programMixer,
            format: djVoiceFormat
        )
        engine.connect(programMixer, to: engine.mainMixerNode, format: nil)
        let outputSampleRate = programMixer.outputFormat(forBus: 0).sampleRate
        visualBridge.configure(
            sampleRate: Float(outputSampleRate)
        )
        duckingController.configure(sampleRate: outputSampleRate)
        musicNode.volume = 0.92
        djVoiceNode.volume = 1

        installVisualTap()
        deviceMonitor = AudioDeviceMonitor(engine: engine) { [weak self] in
            self?.recoverAfterDeviceChange()
        }
    }

    func load(
        _ url: URL,
        completion: @escaping @MainActor @Sendable () -> Void
    ) throws -> LocalTrack {
        logger.info(
            "AudioGraph load：url=\(url.path, privacy: .public)，engineRunning=\(self.engine.isRunning)，musicPlaying=\(self.musicNode.isPlaying)"
        )
        stopMusic(resetDucking: false)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            logger.error(
                "AVAudioFile 打开失败：url=\(url.path, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        currentFile = file
        let scheduledCompletion = completionDispatcher.prepare(completion)
        musicNode.scheduleFile(
            file,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard self != nil else {
                    return
                }
                scheduledCompletion()
            }
        }

        let track = LocalTrack(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            duration: Double(file.length) / file.processingFormat.sampleRate
        )
        logger.info(
            "AudioGraph load 完成：frames=\(file.length)，sampleRate=\(file.processingFormat.sampleRate, format: .fixed(precision: 0))，duration=\(track.duration, format: .fixed(precision: 2))"
        )
        return track
    }

    func play() throws {
        // 没有音轨就**报错**，不再静默 return：静默 return 让上层把"什么都没播"
        // 记成"正在播放"，这正是真机上"操作被接受却不出声"的第一种形态。
        guard currentFile != nil else {
            logger.error("AudioGraph play 失败：currentFile 为空")
            throw LocalMusicPlaybackError.trackNotLoaded
        }
        logger.info(
            "AudioGraph play：engineRunning=\(self.engine.isRunning)，musicPlaying=\(self.musicNode.isPlaying)"
        )
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                logger.error(
                    "AVAudioEngine 启动失败：\(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }
        musicNode.play()
        guard musicNode.isPlaying else {
            logger.error(
                "AudioGraph play 失败：musicNode.play() 之后 isPlaying 仍为 false，引擎没有在渲染"
            )
            throw LocalMusicPlaybackError.graphNotPlaying
        }
        logger.info(
            "AudioGraph play 完成：engineRunning=\(self.engine.isRunning)，musicPlaying=\(self.musicNode.isPlaying)"
        )
    }

    func pause() {
        logger.info(
            "AudioGraph pause：musicPlaying=\(self.musicNode.isPlaying)"
        )
        musicNode.pause()
    }

    func stop() {
        stopMusic(resetDucking: true)
    }

    private func stopMusic(resetDucking: Bool) {
        logger.info(
            "AudioGraph stop：engineRunning=\(self.engine.isRunning)，musicPlaying=\(self.musicNode.isPlaying)"
        )
        completionDispatcher.invalidate()
        musicNode.stop()
        currentFile = nil
        visualBridge.reset()
        if resetDucking {
            duckingController.reset()
            duckingController.setDJSpeaking(djIsSpeaking || residentSpeechPlaying)
        }
    }

    func setDJSpeaking(_ speaking: Bool) {
        djIsSpeaking = speaking
        duckingController.setDJSpeaking(djIsSpeaking || residentSpeechPlaying)
    }

    func setResidentSpeechPlaying(_ playing: Bool) {
        guard residentSpeechPlaying != playing else { return }
        residentSpeechPlaying = playing
        duckingController.setDJSpeaking(djIsSpeaking || residentSpeechPlaying)
    }

    func stopDJVoice() {
        djVoiceNode.stop()
        djVoiceDrainTracker.reset()
        djVoiceChunkCount = 0
        djVoicePeakSinceLog = 0
        logger.info("DJ 口播已中止，清空本地音频缓冲")
    }

    func scheduleDJVoice(_ buffer: AVAudioPCMBuffer) throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        let generation = djVoiceDrainTracker.beginBuffer()
        if djVoiceDrainTracker.pendingCount == 1 {
            logger.info("DJ 口播开始进入本地播放缓冲")
        }
        djVoiceNode.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.djVoiceDrainTracker.completeBuffer(
                    generation: generation
                )
                if self.djVoiceDrainTracker.pendingCount == 0 {
                    self.logger.info("DJ 本地口播音频已经播放完")
                }
            }
        }
        djVoiceNode.play()
    }

    func waitForDJVoiceDrain() async {
        let pending = djVoiceDrainTracker.pendingCount
        guard pending > 0 else {
            logger.info("DJ 口播完成：本地没有待播缓冲")
            return
        }
        logger.info("等待 DJ 本地口播播完：pendingBuffers=\(pending)")
        await djVoiceDrainTracker.waitUntilDrained()
        logger.info("DJ 口播完成：本地缓冲已清空")
    }

    func playBailianVoicePCM(_ data: Data) throws {
        let level = BailianPCMCodec.audioLevel(for: data)
        djVoiceChunkCount += 1
        djVoicePeakSinceLog = max(djVoicePeakSinceLog, level.peak)
        if djVoiceChunkCount == 1 || djVoiceChunkCount.isMultiple(of: 50) {
            logger.info(
                "DJ 口播源音量：chunks=\(self.djVoiceChunkCount)，peak=\(self.djVoicePeakSinceLog, format: .fixed(precision: 3))，channelGainDB=\(DJVoicePCMEnhancer.gainDecibels, format: .fixed(precision: 1))"
            )
            djVoicePeakSinceLog = 0
        }
        let buffer = try BailianPCMCodec.playbackBuffer(from: data)
        DJVoicePCMEnhancer.enhance(buffer)
        try scheduleDJVoice(buffer)
    }

    func startBailianMicrophoneCapture(
        preferredDeviceID: String? = nil,
        _ receive: @escaping @Sendable (
            Data,
            RealtimeDJAudioLevel
        ) -> Void
    ) throws {
        guard microphoneCapture == nil else {
            return
        }
        let capture = try BailianMicrophoneCapture(
            preferredDeviceID: preferredDeviceID,
            receive: receive
        )
        microphoneCapture = capture
        capture.start()
    }

    func stopBailianMicrophoneCapture() {
        microphoneCapture?.stop()
        microphoneCapture = nil
    }

    private func installVisualTap() {
        guard !tapInstalled else {
            return
        }
        programMixer.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: nil,
            block: Self.makeProgramTapBlock(
                visualBridge: visualBridge
            )
        )
        tapInstalled = true
    }

    private nonisolated static func makeProgramTapBlock(
        visualBridge: PlaybackVisualFeatureBridge
    ) -> AVAudioNodeTapBlock {
        { buffer, time in
            visualBridge.consume(buffer, hostTime: time.hostTime)
        }
    }

    private func recoverAfterDeviceChange() {
        guard currentFile != nil else {
            logger.info("音频设备变化：没有已加载歌曲，跳过恢复")
            return
        }
        logger.info(
            "音频设备变化：开始恢复，shouldResume=\(self.musicNode.isPlaying)"
        )
        let shouldResume = musicNode.isPlaying
        engine.stop()
        do {
            visualBridge.configure(
                sampleRate: Float(
                    programMixer.outputFormat(forBus: 0).sampleRate
                )
            )
            duckingController.configure(
                sampleRate: programMixer.outputFormat(forBus: 0).sampleRate
            )
            duckingController.setDJSpeaking(djIsSpeaking || residentSpeechPlaying)
            engine.prepare()
            try engine.start()
            if shouldResume {
                musicNode.play()
            }
        } catch {
            logger.error(
                "音频设备恢复失败：\(error.localizedDescription, privacy: .public)"
            )
            visualBridge.reset()
        }
    }
}

extension AudioGraphController: DJInterruptionAudioControlling {}

private final class PlaybackVisualFeatureBridge: @unchecked Sendable {
    private let store: VisualAudioFeatureStore
    private var analyzer: AudioAnalyzer?
    private var configuredSampleRate: Float = 0

    init(store: VisualAudioFeatureStore) {
        self.store = store
    }

    func configure(sampleRate: Float) {
        guard sampleRate > 0 else {
            analyzer = nil
            configuredSampleRate = 0
            return
        }
        analyzer = AudioAnalyzer(
            sampleRate: sampleRate,
            frameSize: 2_048
        )
        configuredSampleRate = sampleRate
    }

    func consume(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard
            buffer.format.commonFormat == .pcmFormatFloat32,
            let samples = buffer.floatChannelData?[0],
            buffer.frameLength > 0
        else {
            return
        }

        let sampleRate = Float(buffer.format.sampleRate)
        guard
            configuredSampleRate == sampleRate,
            let analyzer
        else {
            return
        }

        let sampleBuffer = UnsafeBufferPointer(
            start: samples,
            count: min(Int(buffer.frameLength), analyzer.frameSize)
        )
        let frame = analyzer.analyze(sampleBuffer, hostTime: hostTime)
        var features = frame.visualFeatures
        features.waveform = WaveformEnvelopeSampler.sample(sampleBuffer)
        store.update(features)
    }

    func reset() {
        store.update(.silent)
    }
}

@MainActor
private final class MixerDuckingController {
    private let logger = Logger(
        subsystem: "ai.gmgn.radio",
        category: "Ducking"
    )
    private let mixer: AVAudioMixerNode
    private var envelope = DuckingEnvelope(sampleRate: 48_000)
    private var automationTask: Task<Void, Never>?
    private var sampleRate = 48_000.0
    private var isSpeaking = false

    init(mixer: AVAudioMixerNode) {
        self.mixer = mixer
    }

    func configure(sampleRate: Double) {
        automationTask?.cancel()
        self.sampleRate = max(sampleRate, 1)
        envelope = DuckingEnvelope(sampleRate: self.sampleRate)
        apply(gain: 1)
        isSpeaking = false
        logger.info(
            "压低控制已配置：sampleRate=\(sampleRate, format: .fixed(precision: 0))，target=0.30"
        )
    }

    func setDJSpeaking(_ speaking: Bool) {
        isSpeaking = speaking
        envelope.setDJSpeaking(speaking)
        automationTask?.cancel()
        logger.info(
            "DJ 发声状态：speaking=\(speaking)，currentMixerGain=\(self.mixer.outputVolume, format: .fixed(precision: 3))"
        )
        automationTask = Task { [weak self] in
            await self?.runAutomation(towardDuckedState: speaking)
        }
    }

    private func runAutomation(
        towardDuckedState: Bool
    ) async {
        let framesPerStep = max(Int(sampleRate / 60), 1)
        while !Task.isCancelled, isSpeaking == towardDuckedState {
            let gain = envelope.advance(frameCount: framesPerStep)
            apply(gain: gain)
            if towardDuckedState, gain <= 0.301 {
                logger.info(
                    "音乐已压低：gain=\(gain, format: .fixed(precision: 3))"
                )
                return
            }
            if !towardDuckedState, gain >= 0.999 {
                logger.info(
                    "音乐音量已恢复：gain=\(gain, format: .fixed(precision: 3))"
                )
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
        }
    }

    func reset() {
        automationTask?.cancel()
        envelope = DuckingEnvelope(sampleRate: sampleRate)
        isSpeaking = false
        apply(gain: 1)
        logger.info("压低控制已重置：gain=1.000")
    }

    private func apply(gain: Float) {
        mixer.outputVolume = gain
    }
}
