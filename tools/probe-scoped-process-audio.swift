// 验收专用：**按目标 PID 限定**的真实 App 系统输出音频采样器。
//
// 背景（见 docs/plans/2026-10-03-dsh-native-audio-hls-tap-boundary.md）：
// 生产电视的 HLS 声音不能经 `AVPlayerItem.audioMix` + `MTAudioProcessingTap` 采样
// （Apple 明确不支持清单）。本工具用 macOS 14.2+ 的 Core Audio 进程 tap 直接抓
// **指定进程**混音后的真实输出，不改播放器、不静音、不碰生产代码，也不需要独立
// AVPlayer 代替真实 App。
//
// 硬性边界：
//   1. **只 tap 指定 PID / 指定 bundle 的进程**。默认拒绝任何"全系统 / 排除式 / 无
//      tap 进程列表"的描述；报告里 `globalTap=false`、`scopedProcesses=[pid]`。
//   2. 所有可能阻塞的 CoreAudio 调用都跑在后台队列，主线程只用**有界超时**等待；
//      超时即输出结构化 JSON 并退出，绝不让验收挂死（旧探针即卡在
//      `AudioDeviceCreateIOProcIDWithBlock`）。聚合设备用最小配方（只有 tap，无主
//      子设备、无 autostart），本机实测不再挂起。
//   3. 只采**真实 App 的实时输出**。`file PCM`、`音轨存在`、`tapAttached`、
//      `hasAudio` 一律**不构成** HLS 输出通过；`--ab` 用"实际播放开/停对照"判真。
//
// 用法（先编译，见 tools/build-scoped-audio-sampler.sh）：
//   gmgn-scoped-audio --bundle-id ai.gmgn.radio.e2e --seconds 8
//   gmgn-scoped-audio --pid 12345 --seconds 8 --jsonl
//   gmgn-scoped-audio --bundle-id ai.gmgn.radio.e2e --ab \
//       --on-cmd "<启动真实 HLS 播放的宿主控制命令>" \
//       --off-cmd "<停止播放的宿主控制命令>"
//   gmgn-scoped-audio --self-test
//
// 退出码：
//   0 达到预期（audible 模式采到非静音 / ab 模式对照成立 / self-test 全过）
//   2 参数或目标进程错误
//   3 tap 初始化失败或有界超时
//   4 需要声音但没采到（或 ab 对照不成立）
//   5 权限被拒（TCC / 屏幕录制）
//   6 后端不可用（如 SCK 不可用）
//   7 self-test 失败
import AppKit
import CoreAudio
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

// MARK: - 小工具

func writeStderr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func jsonString(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}

func emit(_ object: [String: Any], exitCode: Int32) -> Never {
    print(jsonString(object))
    fflush(stdout)
    exit(exitCode)
}

/// 可跨队列传递的盒子（Swift 5 语言模式下避免 inout 捕获限制）。
final class Box<T>: @unchecked Sendable {
    var value: T?
    init(_ value: T? = nil) { self.value = value }
}

/// 在后台队列跑 `work`，主线程最多等 `seconds`。超时返回 nil，**绝不无限等待**。
func bounded<T>(_ seconds: Double, _ work: @escaping () -> T) -> T? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = Box<T>()
    DispatchQueue.global(qos: .userInitiated).async {
        box.value = work()
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
    return box.value
}

/// 把 async 工作桥接成有界同步等待（SCK 用）。
func boundedAsync<T>(_ seconds: Double, _ work: @escaping () async throws -> T) -> Result<T, Error>? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = Box<T>()
    let errorBox = Box<Error>()
    Task.detached {
        do { box.value = try await work() } catch { errorBox.value = error }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
    if let error = errorBox.value { return .failure(error) }
    guard let value = box.value else { return .failure(SamplerError.empty) }
    return .success(value)
}

enum SamplerError: Error, CustomStringConvertible {
    case empty
    case message(String)
    var description: String {
        switch self {
        case .empty: return "empty result"
        case .message(let text): return text
        }
    }
}

// MARK: - 电平计量

struct MeterSnapshot {
    var buffers: Int = 0
    var frames: Int = 0
    var peak: Float = 0
    var sumSquares: Double = 0
    var nonZeroBuffers: Int = 0
    var nonZeroSamples: Int = 0
    var sampleCount: Int = 0

    var rms: Double { sampleCount > 0 ? (sumSquares / Double(sampleCount)).squareRoot() : 0 }
    var nonSilentRatio: Double { buffers > 0 ? Double(nonZeroBuffers) / Double(buffers) : 0 }

    func delta(from previous: MeterSnapshot) -> MeterSnapshot { 
        var d = MeterSnapshot()
        d.buffers = buffers - previous.buffers
        d.frames = frames - previous.frames
        d.peak = peak
        d.sumSquares = sumSquares - previous.sumSquares
        d.nonZeroBuffers = nonZeroBuffers - previous.nonZeroBuffers
        d.nonZeroSamples = nonZeroSamples - previous.nonZeroSamples
        d.sampleCount = sampleCount - previous.sampleCount
        return d
    }

    func dictionary(tag: String) -> [String: Any] {
        [
            "tag": tag,
            "buffers": buffers,
            "frames": frames,
            "peak": Double(peak),
            "rms": rms,
            "nonZeroBuffers": nonZeroBuffers,
            "nonZeroSamples": nonZeroSamples,
            "sampleCount": sampleCount,
            "nonSilentRatio": nonSilentRatio,
        ]
    }
}

/// 线程安全的电平累计器；音频回调在专用队列上写，采样线程读。
final class AudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var frames = 0
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var nonZeroBuffers = 0
    private var nonZeroSamples = 0
    private var sampleCount = 0
    private var formatText = "unknown"

    func setFormat(_ text: String) { lock.withLock { formatText = text } }
    var format: String { lock.withLock { formatText } }

    func record(bufferList: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        record(buffers: abl, format: format)
    }

    func record(buffers abl: UnsafeMutableAudioBufferListPointer, format: AudioStreamBasicDescription) {
        let channelCount = max(1, Int(format.mChannelsPerFrame))
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        var localPeak: Float = 0
        var localSumSquares: Double = 0
        var localSamples = 0
        var localNonZero = 0
        var localFrames = 0
        var anyNonZero = false

        for buffer in abl {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            guard byteCount > 0 else { continue }

            func consume(_ value: Double) {
                let magnitude = abs(value)
                if magnitude.isFinite {
                    localPeak = max(localPeak, Float(magnitude))
                    localSumSquares += value * value
                }
                localSamples += 1
                if value != 0 { localNonZero += 1; anyNonZero = true }
            }

            var framesThisBuffer = 0
            if isFloat {
                let count = byteCount / MemoryLayout<Float>.size
                let pointer = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count { consume(Double(pointer[index])) }
                framesThisBuffer = nonInterleaved ? count : count / channelCount
            } else if format.mBitsPerChannel == 16 {
                let count = byteCount / MemoryLayout<Int16>.size
                let pointer = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0..<count { consume(Double(pointer[index]) / 32768.0) }
                framesThisBuffer = nonInterleaved ? count : count / channelCount
            } else {
                let count = byteCount / MemoryLayout<Int32>.size
                let pointer = data.bindMemory(to: Int32.self, capacity: count)
                for index in 0..<count { consume(Double(pointer[index]) / 2147483648.0) }
                framesThisBuffer = nonInterleaved ? count : count / channelCount
            }
            localFrames = max(localFrames, framesThisBuffer)
        }

        lock.withLock {
            buffers += 1
            frames += localFrames
            peak = max(peak, localPeak)
            sumSquares += localSumSquares
            sampleCount += localSamples
            nonZeroSamples += localNonZero
            if anyNonZero { nonZeroBuffers += 1 }
        }
    }

    func snapshot() -> MeterSnapshot {
        lock.withLock {
            var s = MeterSnapshot()
            s.buffers = buffers
            s.frames = frames
            s.peak = peak
            s.sumSquares = sumSquares
            s.nonZeroBuffers = nonZeroBuffers
            s.nonZeroSamples = nonZeroSamples
            s.sampleCount = sampleCount
            return s
        }
    }
}

// MARK: - 选项

struct Options {
    var pid: pid_t?
    var bundleID: String? = "ai.gmgn.radio.e2e"
    var backend = "coreaudio"            // coreaudio | screencapturekit | auto
    var seconds = 8.0
    var windowSeconds = 0.5
    var targetWaitSeconds = 8.0
    var setupTimeoutSeconds = 10.0
    var jsonLines = false
    var outputPath: String?
    var expect = "any"                   // any | audible | silent
    var minAudibleRms = 0.0005
    var ab = false
    var onCommand: String?
    var offCommand: String?
    var abBaselineSeconds = 3.0
    var abQuietSeconds = 3.0
    var minContrast = 4.0
    // 用测试宿主文件邮箱直接驱动真实 App 的 play_screen / stop_screen（仅测试控制面存在）。
    var hostRoot: String?
    var objectID: String?
    var hlsURL: String?
    var selfTest = false
    var selfCheck = false
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    func next(_ name: String) -> String {
        index += 1
        guard index < arguments.count else {
            writeStderr("缺少 \(name) 的值")
            exit(2)
        }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--pid": options.pid = pid_t(next(argument))
        case "--bundle-id": options.bundleID = next(argument)
        case "--backend": options.backend = next(argument)
        case "--seconds": options.seconds = Double(next(argument)) ?? options.seconds
        case "--window-ms": options.windowSeconds = (Double(next(argument)) ?? 500) / 1000.0
        case "--target-wait": options.targetWaitSeconds = Double(next(argument)) ?? options.targetWaitSeconds
        case "--setup-timeout": options.setupTimeoutSeconds = Double(next(argument)) ?? options.setupTimeoutSeconds
        case "--jsonl": options.jsonLines = true
        case "--output": options.outputPath = next(argument)
        case "--expect": options.expect = next(argument)
        case "--min-audible-rms": options.minAudibleRms = Double(next(argument)) ?? options.minAudibleRms
        case "--ab": options.ab = true
        case "--on-cmd": options.onCommand = next(argument)
        case "--off-cmd": options.offCommand = next(argument)
        case "--ab-baseline-seconds": options.abBaselineSeconds = Double(next(argument)) ?? options.abBaselineSeconds
        case "--ab-quiet-seconds": options.abQuietSeconds = Double(next(argument)) ?? options.abQuietSeconds
        case "--min-contrast": options.minContrast = Double(next(argument)) ?? options.minContrast
        case "--host-root": options.hostRoot = next(argument)
        case "--object-id": options.objectID = next(argument)
        case "--hls-url": options.hlsURL = next(argument)
        case "--self-test": options.selfTest = true
        case "--self-check": options.selfCheck = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            writeStderr("未知参数：\(argument)")
            exit(2)
        }
        index += 1
    }
    return options
}

func printUsage() {
    print("""
    gmgn-scoped-audio —— 验收专用、按目标 PID 限定的系统输出音频采样器

    目标：
      --pid <pid>                 指定进程 PID（优先，最精确）
      --bundle-id <id>            指定 App bundle id（默认 ai.gmgn.radio.e2e）
    后端：
      --backend coreaudio|screencapturekit|auto   （默认 coreaudio）
    采样：
      --seconds <秒>              采样时长（默认 8）
      --window-ms <毫秒>          逐窗口统计粒度（默认 500）
      --target-wait <秒>          等待目标出现音频进程对象的上限（默认 8）
      --setup-timeout <秒>        每个可能阻塞的 CoreAudio 步骤的硬上限（默认 10）
      --jsonl                     逐窗口输出 JSON Lines（默认输出单个 JSON）
      --output <路径>             同时把报告写到文件
      --expect any|audible|silent 期望（默认 any；audible 需要非静音）
      --min-audible-rms <值>      audible 门槛（默认 0.0005）
    开停对照（验真 HLS 真实输出）：
      --ab                        播放开/停对照：先停 → baseline → 开 → playing → 停 → quiet
      --on-cmd <shell>            启动真实播放的命令
      --off-cmd <shell>           停止真实播放的命令
      --host-root <路径>          隔离测试 App 的 GMGN_E2E_DATA_ROOT（用其测试控制面邮箱驱动）
      --object-id <id>            电视物件 id（配合 --host-root）
      --hls-url <页面链接>        传给生产 play_screen 的原始页面链接（配合 --host-root）
      --ab-baseline-seconds <秒>  （默认 3）
      --ab-quiet-seconds <秒>     （默认 3）
      --min-contrast <倍>         playing/静默 的最小倍数（默认 4）
    其他：
      --self-test                 用本机 afplay 做 440Hz 与静音 WAV 的按 PID 自检
      --self-check                只打印能力/权限自检
      --help
    """)
}

// MARK: - 目标解析

struct ResolvedTarget {
    var pid: pid_t
    var bundleID: String?
    var displayName: String
}

func alive(pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
}

func resolveTarget(_ options: Options) -> ResolvedTarget? {
    if let pid = options.pid {
        guard alive(pid: pid) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return ResolvedTarget(pid: pid, bundleID: app?.bundleIdentifier,
                              displayName: app?.localizedName ?? "pid \(pid)")
    }
    guard let bundleID = options.bundleID else { return nil }
    let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard let app = candidates.first else { return nil }
    let pid = app.processIdentifier
    guard pid > 0 else { return nil }
    return ResolvedTarget(pid: pid, bundleID: bundleID, displayName: app.localizedName ?? bundleID)
}

func processObjectID(for pid: pid_t) -> AudioObjectID? {
    var pidValue = pid
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var objectID = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &objectID)
    guard status == noErr, objectID != 0 else { return nil }
    return objectID
}

/// 目标刚起播时音频进程对象才出现；有限重试，不无限等。
func waitForProcessObject(pid: pid_t, timeout: Double) -> AudioObjectID? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let objectID = processObjectID(for: pid) { return objectID }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    return nil
}

func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
    guard status == noErr, asbd.mSampleRate > 0 else { return nil }
    return asbd
}

func formatText(_ asbd: AudioStreamBasicDescription) -> String {
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    return "float:\(isFloat),bits:\(asbd.mBitsPerChannel),sr:\(Int(asbd.mSampleRate)),"
        + "ch:\(asbd.mChannelsPerFrame),nonInterleaved:\(nonInterleaved)"
}

// MARK: - 采样结果

struct SampleResult {
    var backend: String
    var targetPid: pid_t
    var targetBundleID: String?
    var scopedProcesses: [pid_t]
    var scopedBundleIDs: [String]
    var globalTap = false
    var targetPresent = false
    var buffers = 0
    var frames = 0
    var peak: Float = 0
    var rms: Double = 0
    var nonZeroBuffers = 0
    var nonSilentRatio: Double = 0
    var sampleRate: Double = 0
    var channels: Int = 0
    var format = "unknown"
    var seconds = 0.0
    var windows: [[String: Any]] = []
    var error: String?
    var permissionDenied = false
    var setupTimedOut = false
    var backendAvailable = true

    func dictionary(tag: String) -> [String: Any] {
        var dict: [String: Any] = [
            "tag": tag,
            "backend": backend,
            "targetPid": Int(targetPid),
            "targetBundleID": targetBundleID ?? "",
            "targetPresent": targetPresent,
            "scopedProcesses": scopedProcesses.map(Int.init),
            "scopedBundleIDs": scopedBundleIDs,
            "globalTap": globalTap,
            "tapBuffers": buffers,
            "tapFrames": frames,
            "peak": Double(peak),
            "rms": rms,
            "nonZeroBuffers": nonZeroBuffers,
            "nonSilentRatio": nonSilentRatio,
            "sampleRate": sampleRate,
            "channels": channels,
            "format": format,
            "seconds": seconds,
        ]
        if !windows.isEmpty { dict["windows"] = windows }
        if let error { dict["error"] = error }
        if permissionDenied { dict["permissionDenied"] = true }
        if setupTimedOut { dict["setupTimedOut"] = true }
        if !backendAvailable { dict["backendAvailable"] = false }
        return dict
    }

    static func failure(_ backend: String, target: ResolvedTarget, _ message: String,
                        permissionDenied: Bool = false, timedOut: Bool = false,
                        available: Bool = true) -> SampleResult {
        var result = SampleResult(backend: backend, targetPid: target.pid,
                                  targetBundleID: target.bundleID,
                                  scopedProcesses: [target.pid],
                                  scopedBundleIDs: target.bundleID.map { [$0] } ?? [])
        result.error = message
        result.permissionDenied = permissionDenied
        result.setupTimedOut = timedOut
        result.backendAvailable = available
        return result
    }
}

// MARK: - Core Audio 进程 tap 后端

final class CoreAudioTapBackend {
    struct Handles {
        var tapID: AudioObjectID
        var aggregateID: AudioObjectID
        var ioProcID: AudioDeviceIOProcID
    }

    /// 创建 tap + 聚合设备 + IOProc 并开始。每一步都有界；失败返回 nil 并把原因写进 `detail`。
    static func start(processObjectID: AudioObjectID, targetPid: pid_t,
                      setupTimeout: Double, meter: AudioMeter,
                      detail: inout String) -> Handles? {
        // 1) 创建进程 tap。描述**只含一个进程对象**，绝不使用全系统 / 排除式描述。
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.isPrivate = true
        description.muteBehavior = .unmuted   // 只旁路采样，不改目标音量、不静音
        description.name = "GMGN scoped acceptance tap pid=\(targetPid)"
        description.uuid = UUID()

        let tapBox = Box<AudioObjectID>()
        let tapStatus: OSStatus? = bounded(setupTimeout) {
            var tapID = AudioObjectID(0)
            let status = AudioHardwareCreateProcessTap(description, &tapID)
            tapBox.value = tapID
            return status
        }
        guard let tapStatus else { detail = "create-tap:bounded-timeout"; return nil }
        guard tapStatus == noErr, let tapID = tapBox.value, tapID != 0 else {
            detail = "create-tap:status=\(tapStatus)"
            return nil
        }
        guard let asbd = tapFormat(tapID) else {
            AudioHardwareDestroyProcessTap(tapID)
            detail = "create-tap:no-format"
            return nil
        }
        meter.setFormat(formatText(asbd))

        // 2) 最小聚合设备：只含这一个 tap，不挂任何物理子设备，不 autostart。
        //    旧探针的 recipe（空主设备 + autostart + drift compensation）在本机实测
        //    会卡在 AudioDeviceCreateIOProcIDWithBlock；这里用已验证可用的最小配方。
        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "GMGN scoped acceptance aggregate pid=\(targetPid)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: false,
                ]
            ],
        ]
        let aggregateBox = Box<AudioObjectID>()
        let aggregateStatus: OSStatus? = bounded(setupTimeout) {
            var aggregateID = AudioObjectID(0)
            let status = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary, &aggregateID)
            aggregateBox.value = aggregateID
            return status
        }
        guard let aggregateStatus else {
            AudioHardwareDestroyProcessTap(tapID)
            detail = "create-aggregate:bounded-timeout"
            return nil
        }
        guard aggregateStatus == noErr, let aggregateID = aggregateBox.value, aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(tapID)
            detail = "create-aggregate:status=\(aggregateStatus)"
            return nil
        }

        // 3) IOProc 与启动。**后台队列 + 有界超时**：旧探针正是卡在这一步。
        let queue = DispatchQueue(label: "ai.gmgn.radio.e2e.audiosampler.io")
        let ioProcBox = Box<AudioDeviceIOProcID>()
        let ioProcStatus: OSStatus? = bounded(setupTimeout) {
            var ioProcID: AudioDeviceIOProcID?
            let block: AudioDeviceIOBlock = { _, inputData, _, _, _ in
                meter.record(bufferList: inputData, format: asbd)
            }
            let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue, block)
            if let ioProcID { ioProcBox.value = ioProcID }
            return status
        }
        guard let ioProcStatus else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            detail = "create-ioproc:bounded-timeout"
            return nil
        }
        guard ioProcStatus == noErr, let ioProcID = ioProcBox.value else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            detail = "create-ioproc:status=\(ioProcStatus)"
            return nil
        }

        let startStatus: OSStatus? = bounded(setupTimeout) {
            AudioDeviceStart(aggregateID, ioProcID)
        }
        guard let startStatus else {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            detail = "start:bounded-timeout"
            return nil
        }
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            detail = "start:status=\(startStatus)"
            return nil
        }
        return Handles(tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID)
    }

    static func stop(_ handles: Handles) {
        _ = bounded(3.0) { AudioDeviceStop(handles.aggregateID, handles.ioProcID) }
        _ = bounded(3.0) { AudioDeviceDestroyIOProcID(handles.aggregateID, handles.ioProcID) }
        _ = bounded(3.0) { AudioHardwareDestroyAggregateDevice(handles.aggregateID) }
        _ = bounded(3.0) { AudioHardwareDestroyProcessTap(handles.tapID) }
    }
}

func sampleCoreAudio(target: ResolvedTarget, options: Options, seconds: Double) -> SampleResult {
    var result = SampleResult(backend: "coreaudio", targetPid: target.pid,
                              targetBundleID: target.bundleID,
                              scopedProcesses: [target.pid],
                              scopedBundleIDs: target.bundleID.map { [$0] } ?? [])
    result.seconds = seconds
    let meter = AudioMeter()

    guard let processObjectID = waitForProcessObject(pid: target.pid, timeout: options.targetWaitSeconds) else {
        result.error = "no-process-object"
        result.targetPresent = false
        return result
    }
    result.targetPresent = true

    var detail = ""
    guard let handles = CoreAudioTapBackend.start(
        processObjectID: processObjectID, targetPid: target.pid,
        setupTimeout: options.setupTimeoutSeconds, meter: meter, detail: &detail) else {
        result.error = detail
        if detail.contains("bounded-timeout") { result.setupTimedOut = true }
        return result
    }
    result.sampleRate = tapFormat(handles.tapID)?.mSampleRate ?? 0
    result.channels = Int(tapFormat(handles.tapID)?.mChannelsPerFrame ?? 0)
    result.format = meter.format

    let deadline = Date().addingTimeInterval(seconds)
    var previous = meter.snapshot()
    while Date() < deadline {
        Thread.sleep(forTimeInterval: min(options.windowSeconds, max(0.05, deadline.timeIntervalSinceNow)))
        let current = meter.snapshot()
        let window = current.delta(from: previous)
        result.windows.append(window.dictionary(tag: "window"))
        previous = current
    }
    CoreAudioTapBackend.stop(handles)

    let snapshot = meter.snapshot()
    result.buffers = snapshot.buffers
    result.frames = snapshot.frames
    result.peak = snapshot.peak
    result.rms = snapshot.rms
    result.nonZeroBuffers = snapshot.nonZeroBuffers
    result.nonSilentRatio = snapshot.nonSilentRatio
    result.sampleRate = result.sampleRate > 0 ? result.sampleRate : 0
    result.channels = result.channels > 0 ? result.channels : 0
    return result
}

// MARK: - ScreenCaptureKit 后端（仅含指定 runningApplication）

final class ScreenCaptureAudioSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let meter: AudioMeter
    init(meter: AudioMeter) { self.meter = meter }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }
        let asbd = asbdPointer.pointee
        meter.setFormat(formatText(asbd))
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let list = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(list.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return }
        meter.record(buffers: list, format: asbd)
    }
}

func sampleScreenCaptureKit(target: ResolvedTarget, options: Options, seconds: Double) -> SampleResult {
    var result = SampleResult(backend: "screencapturekit", targetPid: target.pid,
                              targetBundleID: target.bundleID,
                              scopedProcesses: [target.pid],
                              scopedBundleIDs: target.bundleID.map { [$0] } ?? [])
    result.seconds = seconds
    let meter = AudioMeter()
    let sink = ScreenCaptureAudioSink(meter: meter)
    let sampleQueue = DispatchQueue(label: "ai.gmgn.radio.e2e.audiosampler.sck")

    let contentResult = boundedAsync(options.setupTimeoutSeconds) {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }
    guard let contentResult else {
        result.error = "shareable-content:bounded-timeout"
        result.setupTimedOut = true
        return result
    }
    let content: SCShareableContent
    switch contentResult {
    case .success(let value): content = value
    case .failure(let error):
        result.error = "shareable-content:\(error.localizedDescription)"
        result.permissionDenied = true
        return result
    }

    guard let application = content.applications.first(where: { application in
        Int(application.processID) == Int(target.pid)
            || (target.bundleID != nil && application.bundleIdentifier == target.bundleID)
    }) else {
        result.error = "screencapturekit:target-application-not-found"
        result.backendAvailable = false
        return result
    }
    guard let display = content.displays.first else {
        result.error = "screencapturekit:no-display"
        result.backendAvailable = false
        return result
    }

    // **只含指定 runningApplication**：filter 的 included applications 只有它一个。
    let filter = SCContentFilter(display: display,
                                 including: [application],
                                 exceptingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = 48000
    configuration.channelCount = 2
    configuration.width = 16
    configuration.height = 16
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 3
    configuration.showsCursor = false

    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    let started = boundedAsync(options.setupTimeoutSeconds) {
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
    }
    guard let started else {
        result.error = "screencapturekit:start:bounded-timeout"
        result.setupTimedOut = true
        return result
    }
    if case .failure(let error) = started {
        result.error = "screencapturekit:start:\(error.localizedDescription)"
        return result
    }

    let deadline = Date().addingTimeInterval(seconds)
    var previous = meter.snapshot()
    while Date() < deadline {
        Thread.sleep(forTimeInterval: min(options.windowSeconds, max(0.05, deadline.timeIntervalSinceNow)))
        let current = meter.snapshot()
        result.windows.append(current.delta(from: previous).dictionary(tag: "window"))
        previous = current
    }
    _ = boundedAsync(5.0) { try await stream.stopCapture() }

    let snapshot = meter.snapshot()
    result.targetPresent = true
    result.buffers = snapshot.buffers
    result.frames = snapshot.frames
    result.peak = snapshot.peak
    result.rms = snapshot.rms
    result.nonZeroBuffers = snapshot.nonZeroBuffers
    result.nonSilentRatio = snapshot.nonSilentRatio
    result.format = meter.format
    result.sampleRate = 48000
    result.channels = 2
    result.scopedBundleIDs = [application.bundleIdentifier]
    return result
}

func sample(target: ResolvedTarget, options: Options, seconds: Double) -> SampleResult {
    switch options.backend {
    case "screencapturekit":
        return sampleScreenCaptureKit(target: target, options: options, seconds: seconds)
    case "auto":
        let coreAudio = sampleCoreAudio(target: target, options: options, seconds: seconds)
        if coreAudio.buffers > 0 || coreAudio.setupTimedOut || coreAudio.permissionDenied {
            return coreAudio
        }
        let sck = sampleScreenCaptureKit(target: target, options: options, seconds: seconds)
        return sck.buffers > 0 ? sck : coreAudio
    default:
        return sampleCoreAudio(target: target, options: options, seconds: seconds)
    }
}

// MARK: - 开/停命令（不回显输出，避免签名地址/凭据泄漏）

@discardableResult
func runCommand(_ command: String, timeout: Double) -> Int32? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        _ = semaphore.wait(timeout: .now() + 2.0)
        return nil
    }
    return process.terminationStatus
}

// MARK: - A/B 判真

struct PhaseReport {
    var result: SampleResult
    var dict: [String: Any]
    var audible: Bool
    var rms: Double
    var peak: Double
    var buffers: Int
}

func phase(_ tag: String, result: SampleResult, minAudibleRms: Double) -> PhaseReport {
    var dict = result.dictionary(tag: tag)
    let audible = result.rms >= minAudibleRms && result.buffers > 0
    dict["audible"] = audible
    return PhaseReport(result: result, dict: dict, audible: audible,
                       rms: result.rms, peak: Double(result.peak), buffers: result.buffers)
}

func runAB(target: ResolvedTarget, options: Options) -> Never {
    let hostDriven = options.hostRoot != nil && options.objectID != nil
    guard hostDriven || options.onCommand != nil || options.offCommand != nil else {
        emit(["verdict": "USAGE_ERROR",
              "reason": "--ab 需要 --on-cmd/--off-cmd，或 --host-root + --object-id + --hls-url"],
             exitCode: 2)
    }
    if hostDriven, options.hlsURL == nil {
        emit(["verdict": "USAGE_ERROR", "reason": "--host-root 模式需要 --hls-url 才能 play_screen"],
             exitCode: 2)
    }

    // 两种驱动方式：测试宿主文件邮箱（真实 App 的 play_screen/stop_screen），或外部 shell 命令。
    func performOn() -> Int32? {
        if hostDriven, let root = options.hostRoot, let objectID = options.objectID,
           let url = options.hlsURL {
            return hostToolCall(root: root, name: "play_screen",
                                arguments: ["object_id": objectID, "url": url], timeout: 60) ? 0 : 1
        }
        return options.onCommand.flatMap { runCommand($0, timeout: 30) }
    }
    func performOff() -> Int32? {
        if hostDriven, let root = options.hostRoot, let objectID = options.objectID {
            return hostToolCall(root: root, name: "stop_screen",
                                arguments: ["object_id": objectID], timeout: 60) ? 0 : 1
        }
        return options.offCommand.flatMap { runCommand($0, timeout: 30) }
    }

    var report: [String: Any] = [
        "tool": "gmgn-scoped-process-audio",
        "schema": 1,
        "mode": "ab",
        "targetPid": Int(target.pid),
        "targetBundleID": target.bundleID ?? "",
        "backend": options.backend,
        "driver": hostDriven ? "e2e-host-mailbox" : "shell-command",
        "minAudibleRms": options.minAudibleRms,
        "minContrast": options.minContrast,
    ]

    // 先确保停止，再取 baseline。
    var offExit: Int32?
    if hostDriven || options.offCommand != nil {
        offExit = performOff()
        Thread.sleep(forTimeInterval: 1.0)
    }
    let baseline = phase("baseline", result: sample(target: target, options: options,
                                                    seconds: options.abBaselineSeconds),
                         minAudibleRms: options.minAudibleRms)

    var onExit: Int32?
    if hostDriven || options.onCommand != nil {
        onExit = performOn()
    }
    Thread.sleep(forTimeInterval: 0.5)
    let playing = phase("playing", result: sample(target: target, options: options,
                                                  seconds: options.seconds),
                        minAudibleRms: options.minAudibleRms)

    if hostDriven || options.offCommand != nil {
        offExit = performOff()
    }
    Thread.sleep(forTimeInterval: 1.0)
    let quiet = phase("quiet", result: sample(target: target, options: options,
                                              seconds: options.abQuietSeconds),
                      minAudibleRms: options.minAudibleRms)

    let floorRms = max(1e-5, baseline.rms, quiet.rms)
    let contrast = playing.rms / floorRms
    let targetScoped = !playing.result.globalTap
        && playing.result.scopedProcesses == [target.pid]
    let confirmed = playing.audible && playing.result.buffers > 0
        && contrast >= options.minContrast && targetScoped

    report["ab"] = [
        "baseline": baseline.dict,
        "playing": playing.dict,
        "quiet": quiet.dict,
        "contrast": contrast,
        "onCommandExit": onExit.map { Int($0) } ?? -1,
        "offCommandExit": offExit.map { Int($0) } ?? -1,
    ]
    report["targetScopedForSamplePid"] = targetScoped
    // 把关键结果也放到顶层，消费方（验收驱动器/主代理）不必再钻进 ab.playing。
    report["globalTap"] = playing.result.globalTap
    report["scopedProcesses"] = playing.result.scopedProcesses.map(Int.init)
    report["scopedBundleIDs"] = playing.result.scopedBundleIDs
    report["playingRms"] = playing.rms
    report["playingPeak"] = playing.peak
    report["playingBuffers"] = playing.buffers
    report["contrast"] = contrast
    report["verdict"] = confirmed ? "HLS_OUTPUT_CONFIRMED" : "HLS_OUTPUT_NOT_CONFIRMED"
    report["reason"] = confirmed
        ? "目标进程在真实 HLS 播放窗口的输出显著高于开播前/停止后（开/停对照成立）"
        : "目标进程输出未通过开/停对照（可能未在播放、被静音、或采到的是其它声音）"
    finish(report, exitCode: confirmed ? 0 : 4, outputPath: options.outputPath)
}

// MARK: - 测试宿主文件邮箱（只存在于 GMGN_E2E_DATA_ROOT 显式启用的隔离 App）

/// 直接给隔离测试 App 的 `control/inbox` 投一条 `tool_call`，有界等待 `control/outbox`。
/// 不读凭据、不打印签名地址；只回传是否成功。
func hostToolCall(root: String, name: String, arguments: [String: Any], timeout: Double) -> Bool {
    let control = URL(fileURLWithPath: root).appendingPathComponent("control")
    let inbox = control.appendingPathComponent("inbox")
    let outbox = control.appendingPathComponent("outbox")
    let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let request: [String: Any] = [
        "id": requestID,
        "command": "tool_call",
        "params": ["name": name, "arguments": arguments],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else {
        return false
    }
    let temporary = inbox.appendingPathComponent("\(requestID).json.tmp")
    let destination = inbox.appendingPathComponent("\(requestID).json")
    do {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        try data.write(to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
    } catch {
        writeStderr("host-mailbox: 写入请求失败：\(error.localizedDescription)")
        return false
    }
    let responseURL = outbox.appendingPathComponent("\(requestID).json")
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let responseData = try? Data(contentsOf: responseURL),
           let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            try? FileManager.default.removeItem(at: responseURL)
            let ok = (response["ok"] as? Bool) ?? false
            let result = response["result"] as? [String: Any]
            let toolOK = (result?["ok"] as? Bool) ?? true
            let isError = (result?["isError"] as? Bool) ?? false
            if !ok {
                writeStderr("host-mailbox: \(name) 被拒：\(response["error"] ?? "unknown")")
            }
            return ok && toolOK && !isError
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    writeStderr("host-mailbox: \(name) 有界超时（\(Int(timeout))s）")
    return false
}

// MARK: - 单次采样

func runSingle(target: ResolvedTarget, options: Options) -> Never {
    let result = sample(target: target, options: options, seconds: options.seconds)
    var report: [String: Any] = [
        "tool": "gmgn-scoped-process-audio",
        "schema": 1,
        "mode": "sample",
        "backend": result.backend,
        "targetPid": Int(target.pid),
        "targetBundleID": target.bundleID ?? "",
        "expect": options.expect,
        "minAudibleRms": options.minAudibleRms,
    ]
    report.merge(result.dictionary(tag: "sample")) { _, new in new }
    if options.jsonLines {
        for window in result.windows {
            print(jsonString(["tool": "gmgn-scoped-process-audio", "type": "window",
                              "targetPid": Int(target.pid), "backend": result.backend,
                              "window": window]))
        }
    }

    let audible = result.rms >= options.minAudibleRms && result.buffers > 0
    let verdict: String
    let exitCode: Int32
    switch options.expect {
    case "audible":
        verdict = audible ? "AUDIBLE_CONFIRMED" : "NO_SIGNAL"
        exitCode = audible ? 0 : 4
    case "silent":
        verdict = audible ? "UNEXPECTED_SIGNAL" : "SILENT_CONFIRMED"
        exitCode = audible ? 4 : 0
    default:
        verdict = audible ? "AUDIBLE" : (result.buffers > 0 ? "SILENT" : "NO_DATA")
        exitCode = 0
    }
    report["audible"] = audible
    report["verdict"] = verdict

    if result.permissionDenied {
        report["verdict"] = "PERMISSION_DENIED"
        report["remediation"] = "在系统设置 → 隐私与安全性 → 麦克风/音频录制 中授权采样器；"
            + "或使用 tools/build-scoped-audio-sampler.sh --app 生成带 NSAudioCaptureUsageDescription 的 .app 后授权。"
        finish(report, exitCode: 5, outputPath: options.outputPath)
    }
    if !result.backendAvailable {
        finish(report, exitCode: 6, outputPath: options.outputPath)
    }
    if result.setupTimedOut {
        // 有界超时是工具级失败，永远非 0；绝不让验收把挂起当通过。
        report["verdict"] = "SETUP_TIMEOUT"
        finish(report, exitCode: 3, outputPath: options.outputPath)
    }
    finish(report, exitCode: exitCode, outputPath: options.outputPath)
}

func finish(_ report: [String: Any], exitCode: Int32, outputPath: String?) -> Never {
    if let outputPath {
        let text = jsonString(report)
        try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
    emit(report, exitCode: exitCode)
}

// MARK: - 自检 / 端到端自测

func selfCheck() -> Never {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let coreAudioAvailable = version.majorVersion > 14
        || (version.majorVersion == 14 && version.minorVersion >= 2)
    var report: [String: Any] = [
        "tool": "gmgn-scoped-process-audio",
        "schema": 1,
        "mode": "self-check",
        "osVersion": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
        "coreAudioProcessTapAvailable": coreAudioAvailable,
        "screenCaptureKitAvailable": true,
        "defaultTargetBundleID": "ai.gmgn.radio.e2e",
        "globalTapRefused": true,
    ]
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.gmgn.radio.e2e")
    report["targetRunningInstances"] = running.map { Int($0.processIdentifier) }
    let contentResult = boundedAsync(8.0) {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }
    switch contentResult {
    case .success(let content):
        report["screenRecordingPermission"] = "granted"
        report["shareableApplications"] = content.applications.count
    case .failure(let error):
        report["screenRecordingPermission"] = "denied-or-unavailable:\(error.localizedDescription)"
    case nil:
        report["screenRecordingPermission"] = "bounded-timeout"
    }
    // 探测目标进程对象（若在跑）。
    if let app = running.first {
        let pid = app.processIdentifier
        report["targetProcessObject"] = processObjectID(for: pid).map { Int($0) } ?? 0
    }
    emit(report, exitCode: 0)
}

func writeWAV(path: String, seconds: Double, frequency: Double, amplitude: Double, sampleRate: Int = 48000) {
    var data = Data()
    let frameCount = Int(Double(sampleRate) * seconds)
    data.append(contentsOf: Array("RIFF".utf8))
    func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    appendUInt32(UInt32(36 + frameCount * 2))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    appendUInt32(16)
    appendUInt16(1)                 // PCM
    appendUInt16(1)                 // mono
    appendUInt32(UInt32(sampleRate))
    appendUInt32(UInt32(sampleRate * 2))
    appendUInt16(2)
    appendUInt16(16)
    data.append(contentsOf: Array("data".utf8))
    appendUInt32(UInt32(frameCount * 2))
    for index in 0..<frameCount {
        let value = Int16(max(-1.0, min(1.0, amplitude * sin(2.0 * Double.pi * frequency * Double(index) / Double(sampleRate)))) * 32767.0)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    try? data.write(to: URL(fileURLWithPath: path))
}

func spawnPlayer(_ path: String) -> pid_t? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    process.arguments = [path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    return process.processIdentifier
}

func runSelfTest() -> Never {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-scoped-audio-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let tonePath = temporary.appendingPathComponent("tone.wav").path
    let silencePath = temporary.appendingPathComponent("silence.wav").path
    writeWAV(path: tonePath, seconds: 20, frequency: 440, amplitude: 0.4)
    writeWAV(path: silencePath, seconds: 20, frequency: 440, amplitude: 0.0)

    var options = Options()
    options.seconds = 2.5
    options.windowSeconds = 0.25
    options.targetWaitSeconds = 8
    options.setupTimeoutSeconds = 10
    options.backend = "coreaudio"

    var failures = 0
    func check(_ condition: Bool, _ message: String, details: String = "") {
        print(condition ? "PASS \(message)" : "FAIL \(message) \(details)")
        if !condition { failures += 1 }
    }

    // 1) 440 Hz 目标：必须采到非静音，且只绑定该 PID。
    if let pid = spawnPlayer(tonePath) {
        Thread.sleep(forTimeInterval: 1.0)
        let target = ResolvedTarget(pid: pid, bundleID: nil, displayName: "afplay tone")
        let result = sampleCoreAudio(target: target, options: options, seconds: options.seconds)
        check(result.buffers > 0, "440Hz：采到音频缓冲",
              details: "buffers=\(result.buffers) error=\(result.error ?? "")")
        check(result.peak > 0.05, "440Hz：采到非静音峰值", details: "peak=\(result.peak)")
        check(result.rms > 0.01, "440Hz：RMS 显著大于 0", details: "rms=\(result.rms)")
        check(result.scopedProcesses == [pid], "440Hz：只绑定目标 PID",
              details: "scoped=\(result.scopedProcesses)")
        check(result.globalTap == false, "440Hz：没有创建全系统 tap")
        check(result.targetPresent, "440Hz：目标进程对象存在")
        kill(pid, SIGTERM)
    } else {
        check(false, "440Hz：无法启动 afplay")
    }

    // 2) 静音目标：要有缓冲但峰值接近 0（证明确实按 PID 采，而不是系统里别的声音）。
    if let pid = spawnPlayer(silencePath) {
        Thread.sleep(forTimeInterval: 1.0)
        let target = ResolvedTarget(pid: pid, bundleID: nil, displayName: "afplay silence")
        let result = sampleCoreAudio(target: target, options: options, seconds: options.seconds)
        check(result.buffers > 0, "静音：采到音频缓冲",
              details: "buffers=\(result.buffers) error=\(result.error ?? "")")
        check(result.peak < 0.01, "静音：峰值接近 0", details: "peak=\(result.peak)")
        check(result.scopedProcesses == [pid], "静音：只绑定目标 PID")
        kill(pid, SIGTERM)
    } else {
        check(false, "静音：无法启动 afplay")
    }

    print(failures == 0 ? "SELF-TEST PASS" : "SELF-TEST FAIL (\(failures))")
    exit(failures == 0 ? 0 : 7)
}

// MARK: - main

@main
struct ScopedProcessAudioProbe {
    static func main() {
        let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
        if options.selfCheck { selfCheck() }
        if options.selfTest { runSelfTest() }

        guard let target = resolveTarget(options) else {
            emit([
                "tool": "gmgn-scoped-process-audio",
                "verdict": "TARGET_NOT_FOUND",
                "reason": options.pid != nil
                    ? "指定 PID 不存在：\(options.pid!)"
                    : "没有正在运行的 \(options.bundleID ?? "(未指定 bundle id)")；用 --pid 指定精确进程",
            ], exitCode: 2)
        }

        // 安全闸：绝不接受全系统 / 排除式后端参数。
        if !["coreaudio", "screencapturekit", "auto"].contains(options.backend) {
            emit(["verdict": "USAGE_ERROR", "reason": "未知 backend：\(options.backend)"], exitCode: 2)
        }

        if options.ab { runAB(target: target, options: options) }
        runSingle(target: target, options: options)
    }
}
