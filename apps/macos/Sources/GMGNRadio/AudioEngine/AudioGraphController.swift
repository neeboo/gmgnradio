import AVFoundation
import Foundation

@MainActor
final class AudioGraphController: LocalMusicPlaybackGraph {
    private let engine: AVAudioEngine
    private let musicNode = AVAudioPlayerNode()
    private let djVoiceNode = AVAudioPlayerNode()
    private let programMixer = AVAudioMixerNode()
    private let visualBridge: PlaybackVisualFeatureBridge
    private var currentFile: AVAudioFile?
    private var completion: (@MainActor @Sendable () -> Void)?
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

    init(
        visualStore: VisualAudioFeatureStore,
        engine: AVAudioEngine = AVAudioEngine()
    ) {
        self.engine = engine
        visualBridge = PlaybackVisualFeatureBridge(store: visualStore)

        engine.attach(musicNode)
        engine.attach(djVoiceNode)
        engine.attach(programMixer)
        engine.connect(musicNode, to: programMixer, format: nil)
        engine.connect(djVoiceNode, to: programMixer, format: nil)
        engine.connect(programMixer, to: engine.mainMixerNode, format: nil)
        visualBridge.configure(
            sampleRate: Float(
                programMixer.outputFormat(forBus: 0).sampleRate
            )
        )
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
        self.completion = completion
        musicNode.scheduleFile(
            file,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                self?.completion?()
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
        musicNode.stop()
        completion = nil
        currentFile = nil
        visualBridge.reset()
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
            block: Self.makeVisualTapBlock(bridge: visualBridge)
        )
        tapInstalled = true
    }

    private nonisolated static func makeVisualTapBlock(
        bridge: PlaybackVisualFeatureBridge
    ) -> AVAudioNodeTapBlock {
        { buffer, time in
            bridge.consume(buffer, hostTime: time.hostTime)
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
