import AVFoundation
import Foundation
import os

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
final class AudioGraphController: LocalMusicPlaybackGraph {
    private let engine: AVAudioEngine
    private let musicNode = AVAudioPlayerNode()
    private let djVoiceNode = AVAudioPlayerNode()
    private let musicMixer = AVAudioMixerNode()
    private let programMixer = AVAudioMixerNode()
    private let visualBridge: PlaybackVisualFeatureBridge
    private let duckingController: SampleTimedDuckingController
    private let completionDispatcher = AudioGraphCompletionDispatcher()
    private var currentFile: AVAudioFile?
    private var tapInstalled = false
    private var deviceMonitor: AudioDeviceMonitor?

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
        duckingController = SampleTimedDuckingController(
            mixer: musicMixer
        )

        engine.attach(musicNode)
        engine.attach(djVoiceNode)
        engine.attach(musicMixer)
        engine.attach(programMixer)
        engine.connect(musicNode, to: musicMixer, format: nil)
        engine.connect(musicMixer, to: programMixer, format: nil)
        engine.connect(djVoiceNode, to: programMixer, format: nil)
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
        stop()

        let file = try AVAudioFile(forReading: url)
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

        return LocalTrack(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            duration: Double(file.length) / file.processingFormat.sampleRate
        )
    }

    func play() throws {
        guard currentFile != nil else {
            return
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        musicNode.play()
    }

    func pause() {
        musicNode.pause()
    }

    func stop() {
        completionDispatcher.invalidate()
        musicNode.stop()
        currentFile = nil
        visualBridge.reset()
        duckingController.reset()
    }

    func setDJSpeaking(_ speaking: Bool) {
        duckingController.setDJSpeaking(speaking)
    }

    func stopDJVoice() {
        djVoiceNode.stop()
    }

    func scheduleDJVoice(_ buffer: AVAudioPCMBuffer) throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        djVoiceNode.scheduleBuffer(buffer)
        djVoiceNode.play()
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
                visualBridge: visualBridge,
                duckingController: duckingController
            )
        )
        tapInstalled = true
    }

    private nonisolated static func makeProgramTapBlock(
        visualBridge: PlaybackVisualFeatureBridge,
        duckingController: SampleTimedDuckingController
    ) -> AVAudioNodeTapBlock {
        { buffer, time in
            duckingController.advance(frameCount: Int(buffer.frameLength))
            visualBridge.consume(buffer, hostTime: time.hostTime)
        }
    }

    private func recoverAfterDeviceChange() {
        guard currentFile != nil else {
            return
        }
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
            engine.prepare()
            try engine.start()
            if shouldResume {
                musicNode.play()
            }
        } catch {
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
        store.update(frame.visualFeatures)
    }

    func reset() {
        store.update(.silent)
    }
}

private final class SampleTimedDuckingController: @unchecked Sendable {
    private let mixer: AVAudioMixerNode
    private let scheduleParameter: AUScheduleParameterBlock
    private let outputGainAddress: AUParameterAddress?
    private let envelope = OSAllocatedUnfairLock(
        initialState: DuckingEnvelope(sampleRate: 48_000)
    )

    init(mixer: AVAudioMixerNode) {
        self.mixer = mixer
        scheduleParameter = mixer.auAudioUnit.scheduleParameterBlock
        outputGainAddress = mixer.auAudioUnit.parameterTree?
            .allParameters
            .first(where: { $0.keyPath == "output.0" })?
            .address
    }

    func configure(sampleRate: Double) {
        envelope.withLock { state in
            state = DuckingEnvelope(sampleRate: sampleRate)
        }
        apply(gain: 1)
    }

    func setDJSpeaking(_ speaking: Bool) {
        envelope.withLock { state in
            state.setDJSpeaking(speaking)
        }
    }

    func advance(frameCount: Int) {
        let gain = envelope.withLock { state in
            state.advance(frameCount: frameCount)
        }
        apply(gain: gain)
    }

    func reset() {
        envelope.withLock { state in
            state = DuckingEnvelope(sampleRate: 48_000)
        }
        apply(gain: 1)
    }

    private func apply(gain: Float) {
        guard let outputGainAddress else {
            return
        }
        scheduleParameter(
            AUEventSampleTimeImmediate,
            0,
            outputGainAddress,
            gain
        )
    }
}
