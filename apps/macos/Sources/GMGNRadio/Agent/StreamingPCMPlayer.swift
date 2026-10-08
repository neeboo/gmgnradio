import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// A per-engine route override used only by an explicitly isolated E2E run.
/// This never writes CoreAudio's global default input/output properties.
enum StreamingPCMOutputRoute {
    static func overrideUID(environment: [String: String]) throws -> String? {
        guard let root = environment["GMGN_E2E_DATA_ROOT"], !root.isEmpty else { return nil }
        guard let uid = environment["GMGN_E2E_VOICE_OUTPUT_DEVICE_UID"] else { return nil }
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RustVoiceError.rejected("invalid_e2e_voice_output_device")
        }
        return uid
    }

    static func apply(to engine: AVAudioEngine, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let uid = try overrideUID(environment: environment) else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            throw RustVoiceError.rejected("e2e_voice_output_device_unavailable")
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty else { throw RustVoiceError.rejected("e2e_voice_output_device_unavailable") }
        let status = devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { throw RustVoiceError.rejected("e2e_voice_output_device_unavailable") }
        for var device in devices {
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var deviceUID: CFString?
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &deviceUID) == noErr,
                  let deviceUID, deviceUID as String == uid else { continue }
            var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0, let unit = engine.outputNode.audioUnit else {
                throw RustVoiceError.rejected("e2e_voice_output_device_unavailable")
            }
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw RustVoiceError.rejected("e2e_voice_output_route_failed")
            }
            var activeDevice: AudioDeviceID = 0
            var activeSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                0, &activeDevice, &activeSize) == noErr, activeDevice == device else {
                throw RustVoiceError.rejected("e2e_voice_output_route_failed")
            }
            return
        }
        throw RustVoiceError.rejected("e2e_voice_output_device_not_found")
    }
}

/// PCM framing is independent of the audio device. An odd trailing byte belongs
/// to the next chunk, never padding or dropping a sample between network frames.
struct PCM16LEDecoder {
    private(set) var trailingByte: UInt8?
    mutating func decode(_ bytes: Data) -> [Float] {
        var input = [UInt8]()
        input.reserveCapacity(bytes.count + 1)
        if let trailingByte { input.append(trailingByte) }
        input.append(contentsOf: bytes)
        trailingByte = input.count.isMultiple(of: 2) ? nil : input.last
        return stride(from: 0, to: input.count - (input.count % 2), by: 2).map {
            Float(Int16(bitPattern: UInt16(input[$0]) | UInt16(input[$0 + 1]) << 8)) / 32_768
        }
    }
}

private final class PCMLevelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !pending else { return false }
        pending = true; return true
    }
    func release() { lock.lock(); pending = false; lock.unlock() }
}

@MainActor protocol StreamingPCMPlaying: AnyObject {
    func begin(onPlaybackChanged: @escaping @MainActor (AgentSpeechPlaybackState) -> Void) throws
    func append(_ pcm16LE: Data) async throws
    /// Input is over; completion waits for the device's dataPlayedBack callbacks.
    func finish() async throws
    func stop()
    /// Rust has already reserved this packet's playback window. Return once the
    /// native device scheduled it; completion reports the real dataPlayedBack.
    func schedulePacket(_ pcm16LE: Data, frameCount: Int,
                        onPlayed: @escaping @MainActor @Sendable () -> Void) throws
}

extension StreamingPCMPlaying {
    func schedulePacket(_ pcm16LE: Data, frameCount: Int,
                        onPlayed: @escaping @MainActor @Sendable () -> Void) throws {
        throw RustVoiceError.rejected("delivery_device_unavailable")
    }
}

@MainActor protocol StreamingPCMDevice: AnyObject {
    func start(onLevel: @escaping @Sendable (Float) -> Void) throws
    func schedule(_ samples: [Float], onPlayed: @escaping @Sendable () -> Void) throws
    func stop()
}

/// AVFoundation invokes these callbacks on its render threads. Explicit
/// Sendable function types prevent Swift 6 from inheriting the caller's actor.
enum StreamingPCMCallbacks {
    nonisolated static func tap(onLevel: @escaping @Sendable (Float) -> Void)
        -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var squares: Float = 0
            let count = Int(buffer.frameLength)
            for index in 0..<count { let value = channels[0][index]; squares += value * value }
            onLevel(min(1, sqrt(squares / Float(count))))
        }
    }
    nonisolated static func played(onPlayed: @escaping @Sendable () -> Void)
        -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in onPlayed() }
    }
}

@MainActor private final class StreamingPCMAVDevice: StreamingPCMDevice {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var tapInstalled = false

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }
    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        try StreamingPCMOutputRoute.apply(to: engine)
        let mixer = engine.mainMixerNode
        if ProcessInfo.processInfo.environment["GMGN_UNITY_TEST_MUTED"] == "1" { mixer.outputVolume = 0 }
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil,
                         block: StreamingPCMCallbacks.tap(onLevel: onLevel))
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }
    func schedule(_ samples: [Float], onPlayed: @escaping @Sendable () -> Void) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw RustVoiceError.invalidFrame }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack,
                            completionHandler: StreamingPCMCallbacks.played(onPlayed: onPlayed))
        if !node.isPlaying { node.play() } // first block starts, not whole utterance
    }
    func stop() {
        node.stop()
        if tapInstalled { engine.mainMixerNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
    }
}

@MainActor final class StreamingPCMPlayer: StreamingPCMPlaying {
    static let maximumQueuedFrames = 12_000 // 0.5 seconds at 24 kHz
    private let makeDevice: @MainActor () -> any StreamingPCMDevice
    private var device: (any StreamingPCMDevice)?
    private var generation: UUID?
    private var decoder = PCM16LEDecoder()
    private var queuedFrames = 0
    private var receivedFrames = 0
    private var observer: (@MainActor (AgentSpeechPlaybackState) -> Void)?
    private(set) var peakQueuedFrames = 0

    init(makeDevice: @escaping @MainActor () -> any StreamingPCMDevice = { StreamingPCMAVDevice() }) {
        self.makeDevice = makeDevice
    }
    func begin(onPlaybackChanged: @escaping @MainActor (AgentSpeechPlaybackState) -> Void) throws {
        stop()
        let identity = UUID(); generation = identity
        decoder = PCM16LEDecoder(); queuedFrames = 0; receivedFrames = 0; peakQueuedFrames = 0
        observer = onPlaybackChanged
        let next = makeDevice(); device = next
        let levelGate = PCMLevelGate()
        do {
            try next.start { [weak self] level in
                guard levelGate.acquire() else { return }
                Task { @MainActor in
                    defer { levelGate.release() }
                    guard let self, self.generation == identity, self.queuedFrames > 0 else { return }
                    self.observer?(.init(isPlaying: true, level: level))
                }
            }
        } catch { stop(); throw error }
    }
    func append(_ pcm16LE: Data) async throws {
        guard let identity = generation, let device else { throw CancellationError() }
        guard pcm16LE.count <= 32_768 else { throw RustVoiceError.invalidFrame }
        let samples = decoder.decode(pcm16LE)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 4096, samples.count), count = end - offset
            while queuedFrames + count > Self.maximumQueuedFrames {
                try await Task.sleep(for: .milliseconds(10))
                try requireCurrent(identity)
            }
            try requireCurrent(identity)
            queuedFrames += count; receivedFrames += count
            peakQueuedFrames = max(peakQueuedFrames, queuedFrames)
            do {
                try device.schedule(Array(samples[offset..<end])) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == identity else { return }
                        self.queuedFrames -= count
                        if self.queuedFrames == 0 { self.observer?(.idle) }
                    }
                }
            } catch { queuedFrames -= count; throw error }
            offset = end
        }
    }
    func schedulePacket(_ pcm16LE: Data, frameCount: Int,
                        onPlayed: @escaping @MainActor @Sendable () -> Void) throws {
        guard let identity = generation, let device else { throw CancellationError() }
        guard (1...4096).contains(frameCount), pcm16LE.count == frameCount * 2 else { throw RustVoiceError.invalidFrame }
        let samples = decoder.decode(pcm16LE)
        guard samples.count == frameCount, decoder.trailingByte == nil else { throw RustVoiceError.invalidFrame }
        queuedFrames += frameCount; receivedFrames += frameCount
        peakQueuedFrames = max(peakQueuedFrames, queuedFrames)
        do {
            try device.schedule(samples) { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == identity else { return }
                    self.queuedFrames -= frameCount
                    if self.queuedFrames == 0 { self.observer?(.idle) }
                    onPlayed()
                }
            }
        } catch { queuedFrames -= frameCount; throw error }
    }
    func finish() async throws {
        guard let identity = generation else { throw CancellationError() }
        guard decoder.trailingByte == nil, receivedFrames > 0 else { throw RustVoiceError.invalidFrame }
        while queuedFrames > 0 {
            try await Task.sleep(for: .milliseconds(10))
            try requireCurrent(identity)
        }
        try requireCurrent(identity)
        stop()
    }
    func stop() {
        generation = nil
        device?.stop(); device = nil
        queuedFrames = 0; decoder = PCM16LEDecoder()
        let previous = observer; observer = nil; previous?(.idle)
    }
    private func requireCurrent(_ identity: UUID) throws {
        try Task.checkCancellation()
        guard generation == identity else { throw CancellationError() }
    }
}
