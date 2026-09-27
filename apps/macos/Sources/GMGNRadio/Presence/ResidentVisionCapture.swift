import Foundation
import CoreGraphics
import ImageIO

// MARK: - 居民视觉观察·第一增量
//
// 本文件是居民视觉捕获的领域合同与纯逻辑(可离线运行生产代码):
//  1. 视角目录只登记"真实可捕获"的视角。当前第一增量只有
//     `current_observation`:全舞台(full-stage)现用固定观察相机渲染出的
//     真实画面,居民角色在场时在该画面中可见。
//     全局俯瞰 / 居民眼睛等独立离屏相机视角尚未实现,一律不登记为可用;
//     头眼(第一人称)视角绝不能用现有的第三方观察帧冒充。
//  2. 捕获服务一次只受理一个请求,只返回"请求之后新渲染"的帧;结合
//     worldID / camera / time 元数据与请求方的期望 revision 拒绝旧空间、
//     旧帧、无画面与超时。画面帧的真实世界 revision 渲染器当前不提供:
//     元数据里的 `expectedWorldRevision` 只是请求方的期望条件,绝不代表
//     画面帧已被核对到该 revision。
//  3. 画面只属于当前居民会话(按 sessionID 分目录存放),不作为任何新生成
//     授权,模型不能指定写入路径(工具合同里根本没有路径参数)。
//  4. 交付的 PNG 受传输预算约束(≤512 KiB 字节 + 合理尺寸):编码超限先自动
//     缩小,缩到下限仍超限才明确失败(image_too_large),绝不静默交付
//     超预算的图片。
//
// 本文件不 import 任何 Metal / 渲染类型;渲染器自身的帧回读通过
// `ResidentVisionSurface` 协议注入(MarbleSpatialView.swift 内的实现)。

// MARK: - 错误码(稳定接口,工具与传输层按 code 区分处理)

enum ResidentVisionErrorCode: String, Codable, Sendable, Equatable {
    case invalidParameters = "invalid_parameters"
    case perspectiveUnavailable = "perspective_unavailable"
    case captureUnavailable = "capture_unavailable"
    case noPicture = "no_picture"
    case staleWorld = "stale_world"
    case staleFrame = "stale_frame"
    case timeout = "timeout"
    case cancelled = "cancelled"
    case sessionMismatch = "session_mismatch"
    case encodingFailed = "encoding_failed"
    /// PNG 即使缩到最低尺寸仍超过传输预算,或原始画面尺寸不可接受。
    case imageTooLarge = "image_too_large"
    case fileWriteFailed = "file_write_failed"
}

// MARK: - 视角目录

/// 已真实实现的居民观察视角。未实现的视角不在这里出现,因此无法被工具登记。
enum ResidentVisionPerspective: String, Codable, CaseIterable, Sendable,
    Equatable
{
    /// 当前固定观察画面:full-stage 现用观察相机渲染出的真实空间画面,
    /// 居民角色在场时可见其自身(第三人称房间观察相机,非第一人称)。
    case currentObservation = "current_observation"
}

/// 尚未实现、因此不得登记为可用的离屏视角 ID(评估与文档用)。
enum ResidentVisionUnregisteredPerspective {
    static let globalOverview = "global_overview"
    static let residentEye = "resident_eye"
}

struct ResidentVisionPerspectiveCapability: Codable, Equatable, Sendable,
    Identifiable
{
    let id: String
    let label: String
    let summary: String
    let cameraKind: String
    let showsSpace: Bool
    let showsResidentAvatarWhenPresent: Bool
    let requiresOffscreenCamera: Bool
}

enum ResidentVisionCatalog {
    static var registeredPerspectives: [ResidentVisionPerspective] {
        ResidentVisionPerspective.allCases
    }

    static var registeredIDs: [String] {
        registeredPerspectives.map(\.rawValue)
    }

    static func isRegistered(_ id: String) -> Bool {
        registeredIDs.contains(id)
    }

    static func capability(
        for perspective: ResidentVisionPerspective
    ) -> ResidentVisionPerspectiveCapability {
        switch perspective {
        case .currentObservation:
            ResidentVisionPerspectiveCapability(
                id: perspective.rawValue,
                label: "当前固定观察画面",
                summary:
                    "全舞台现用固定观察相机当前渲染的空间画面;居民在场时可在画面中看到自己的角色与周围环境。",
                cameraKind: "full_stage_observer",
                showsSpace: true,
                showsResidentAvatarWhenPresent: true,
                requiresOffscreenCamera: false
            )
        }
    }
}

// MARK: - 相机与帧元数据

enum ResidentVisionCameraKind: String, Codable, Sendable, Equatable {
    /// full-stage 共享观察相机(真实存在的渲染相机)。
    case fullStageObserver = "full_stage_observer"
}

struct ResidentVisionCameraStamp: Codable, Equatable, Sendable {
    let label: String
    let kind: ResidentVisionCameraKind
    /// [x, y, z],渲染器当前世界坐标(与画面同源)。
    let position: [Float]
    let yaw: Float
    let pitch: Float
    let fieldOfViewDegrees: Float?
    let coordinateSpace: String
}

/// 一帧捕获时的空间/内容标记,用于门控与元数据。
struct ResidentVisionRenderedStamp: Equatable, Sendable {
    /// 渲染档案标识(当前恒为 full_stage_drawable)。
    let surfaceProfile: String
    let frameIndex: UInt64
    let capturedAt: Date
    let worldID: String
    let residentAvatarID: String?
    let residentAvatarFrameRevision: UInt64?
    /// [x, y, z];居民角色在该帧中的位置(与画面同源)。
    let residentPosition: [Float]?
    let camera: ResidentVisionCameraStamp
}

/// 捕获请求的稳定元数据(工具返回给模型/传输层的 worldID/camera/time)。
struct ResidentVisionMetadata: Codable, Equatable, Sendable {
    let captureID: UUID
    let perspective: ResidentVisionPerspective
    let worldID: String
    /// 帧来源;恒为渲染器自身 drawable,绝不来自桌面/录屏。
    let surface: String
    let camera: ResidentVisionCameraStamp
    let capturedAt: Date
    let frameIndex: UInt64
    let residentAvatarID: String?
    let residentAvatarFrameRevision: UInt64?
    let residentPosition: [Float]?
    /// 仅回显请求方发起时的期望 revision(期望条件),绝不代表画面帧已被
    /// 核对等于该 revision。渲染器当前不提供画面帧的真实世界 revision,
    /// 因此元数据**不**包含任何可证明的 world revision(render revision:
    /// unknown);也不得用当前上下文把某个 revision 冒充为帧的 revision。
    let expectedWorldRevision: UInt64?
    /// 交付 PNG 的实际尺寸(编码时若为满足传输预算缩小过,则为缩小后的尺寸)。
    let width: Int
    let height: Int

    static func make(
        captureID: UUID = UUID(),
        renderedFrame: ResidentVisionRenderedFrame,
        perspective: ResidentVisionPerspective,
        expectedWorldRevision: UInt64?,
        deliveredWidth: Int? = nil,
        deliveredHeight: Int? = nil
    ) -> ResidentVisionMetadata {
        ResidentVisionMetadata(
            captureID: captureID,
            perspective: perspective,
            worldID: renderedFrame.stamp.worldID,
            surface: renderedFrame.stamp.surfaceProfile,
            camera: renderedFrame.stamp.camera,
            capturedAt: renderedFrame.stamp.capturedAt,
            frameIndex: renderedFrame.stamp.frameIndex,
            residentAvatarID: renderedFrame.stamp.residentAvatarID,
            residentAvatarFrameRevision: renderedFrame
                .stamp.residentAvatarFrameRevision,
            residentPosition: renderedFrame.stamp.residentPosition,
            expectedWorldRevision: expectedWorldRevision,
            width: deliveredWidth ?? renderedFrame.width,
            height: deliveredHeight ?? renderedFrame.height
        )
    }
}

// MARK: - 请求 / 渲染帧 / 结果

struct ResidentVisionCaptureRequest: Equatable, Sendable {
    static let defaultMaximumAge: TimeInterval = 2.5
    static let defaultTimeout: TimeInterval = 4
    static let maximumTimeout: TimeInterval = 15

    /// 当前居民会话(决定画面归属目录与"仅当前会话"语义)。
    let sessionID: UUID
    let perspective: ResidentVisionPerspective
    /// 请求所针对的空间;必须与渲染帧及当前居民上下文一致,否则拒绝。
    let worldID: String
    /// 请求方发起请求时已知(期望)的 revision;仅为请求条件,用于"旧状态
    /// 重载"检测,不代表画面帧已核对到该 revision(帧的真实 revision 渲染
    /// 器当前不提供)。
    let expectedWorldRevision: UInt64?
    /// 画面超过该时限视为旧帧。
    let maximumAge: TimeInterval
    let timeout: TimeInterval
    let reason: String?
    /// 是否同时在会话目录落一份私有 PNG 并返回 URL。
    let includeFileURL: Bool

    init(
        sessionID: UUID,
        perspective: ResidentVisionPerspective = .currentObservation,
        worldID: String,
        expectedWorldRevision: UInt64? = nil,
        maximumAge: TimeInterval = ResidentVisionCaptureRequest
            .defaultMaximumAge,
        timeout: TimeInterval = ResidentVisionCaptureRequest.defaultTimeout,
        reason: String? = nil,
        includeFileURL: Bool = true
    ) {
        self.sessionID = sessionID
        self.perspective = perspective
        self.worldID = worldID
        self.expectedWorldRevision = expectedWorldRevision
        self.maximumAge = min(max(maximumAge, 0.1), 10)
        self.timeout = min(
            max(timeout, 0.5),
            ResidentVisionCaptureRequest.maximumTimeout
        )
        self.reason = reason
        self.includeFileURL = includeFileURL
    }
}

struct ResidentVisionRenderedFrame: Sendable {
    /// BGRA 8bit sRGB 像素,row 0 为纹理内存首行(与画面渲染一致)。
    let pixelsBGRA: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let stamp: ResidentVisionRenderedStamp
}

enum ResidentVisionSurfaceFrameResult: Sendable {
    case frame(ResidentVisionRenderedFrame)
    case failure(code: ResidentVisionErrorCode, message: String)
}

/// 渲染器帧源。协议本身不依赖 Metal,便于离线测试注入假帧源;
/// 生产实现是 MarbleSpatialView.swift 中渲染器自身的 drawable 回读。
@MainActor
protocol ResidentVisionSurface: AnyObject, Sendable {
    func captureCurrentObservation(
        request: ResidentVisionCaptureRequest,
        requestedAt: Date
    ) async -> ResidentVisionSurfaceFrameResult
}

// MARK: - 单飞 + 代次匹配(请求身份)

/// 单飞闸门:同一时刻只允许一个未完成的画面请求,并给每次请求一个独有的
/// captureID(generation)作为身份。任何"完成 / 取消"回调都必须携带它所属
/// 请求的 captureID 调用 `finish(_:)`;只有仍是当前请求的回调才会生效。
///
/// 这修复了"无请求身份"的竞争:请求 A 被取消后请求 B 进入,若 A 的旧 GPU
/// 回读完成或旧取消任务迟到,没有身份匹配就会解析/取消当前的 B。加入
/// generation 后,过期回调一律返回 false,绝不触碰 B 的进行中状态。
@MainActor
final class ResidentVisionSingleFlight {
    private(set) var activeCaptureID: UUID?

    /// 尝试开始一个新请求。空闲时登记 captureID 并返回 true;已有请求未结束
    /// (忙)时返回 false,调用方不应继续登记。
    @discardableResult
    func begin(captureID: UUID) -> Bool {
        guard activeCaptureID == nil else { return false }
        activeCaptureID = captureID
        return true
    }

    var isIdle: Bool { activeCaptureID == nil }

    /// captureID 是否仍是当前未完成的请求。
    func isCurrent(_ captureID: UUID) -> Bool {
        activeCaptureID == captureID
    }

    /// 结束 captureID 对应的请求。仅当它仍是当前请求时生效并返回 true;
    /// 过期请求的迟到回调返回 false,不改变任何状态。
    @discardableResult
    func finish(_ captureID: UUID) -> Bool {
        guard activeCaptureID == captureID else { return false }
        activeCaptureID = nil
        return true
    }
}

/// 一次成功的居民视觉捕获:PNG 数据 + 元数据 + (可选)会话私有文件 URL。
struct ResidentVisionImage: Sendable, Equatable {
    let pngData: Data
    let metadata: ResidentVisionMetadata
    let fileURL: URL?
}

enum ResidentVisionCaptureOutcome: Sendable, Equatable {
    case success(ResidentVisionImage)
    case failure(code: ResidentVisionErrorCode, message: String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - PNG 编码(纯逻辑,生产路径使用;复用渲染器 debug 导出同款 BGRA→PNG)

/// 交付图片的尺寸/字节预算(与工具传输帧对齐)。
enum ResidentVisionImagePolicy {
    /// 单张 PNG 字节预算:512 KiB，为 base64 膨胀和工具元数据留出传输余量。
    /// 编码超限先自动缩小,
    /// 缩到下限仍超限才明确失败(image_too_large)。
    static let maximumPNGBytes = 1 << 19
    /// 交付尺寸护栏:任何一边超过该值的 PNG 都先缩小到护栏内(即使字节很小),
    /// 保证"尺寸合理"。
    static let maximumDeliveredEdge = 4096
    /// 缩小下限:缩到该边长以下不再缩小;仍超预算则明确失败。
    static let minimumDownscaleEdge = 128
}

enum ResidentVisionPNG {
    enum EncodeError: Error {
        case invalidDimensions
        case dataTooShort
        case imageCreationFailed
        case destinationFinalizeFailed
        /// 缩小到下限后仍超过字节预算(编码已尽力,只能明确失败)。
        case tooLargeForBudget
    }

    /// 一次成功编码的交付物:PNG 数据 + 实际交付尺寸(可能小于原始帧)。
    struct Encoded: Equatable, Sendable {
        let data: Data
        let width: Int
        let height: Int
    }

    /// 将 BGRA8(byteOrder32Little + premultipliedFirst)像素编码为 PNG Data。
    static func encode(
        bgra8Pixels: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> Data {
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            throw EncodeError.invalidDimensions
        }
        guard bgra8Pixels.count >= bytesPerRow * height else {
            throw EncodeError.dataTooShort
        }
        guard let provider = CGDataProvider(data: bgra8Pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                      CGBitmapInfo(
                          rawValue: CGImageAlphaInfo.premultipliedFirst
                              .rawValue
                      )
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  output,
                  "public.png" as CFString,
                  1,
                  nil
              )
        else {
            throw EncodeError.imageCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw EncodeError.destinationFinalizeFailed
        }
        return output as Data
    }

    /// 极简无画面判定:PNG 头 + 至少一个可解码的最小体积。
    static func looksPlausible(_ data: Data) -> Bool {
        guard data.count > 8 else { return false }
        let header: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ]
        return data.prefix(8).elementsEqual(header)
    }

    /// 用 ImageIO 真正解码一次,验证字节确实是可解码图片(测试与健全检查)。
    static func decodedDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source, 0, nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return (width, height)
    }

    /// 受预算约束的编码(生产交付路径):
    ///  1. 尺寸护栏:任何一边超过 `maximumDeliveredEdge` 先缩到护栏内;
    ///  2. 字节预算:PNG 超过 `maximumBytes` 就按 2×2 平均逐级缩小重编码,
    ///     直到 ≤ 预算或到达 `minimumDownscaleEdge`;
    ///  3. 缩到下限仍超预算 → 明确抛 `tooLargeForBudget`(服务层返回
    ///     image_too_large),绝不静默交付超预算图片。
    /// 返回实际交付尺寸(可能小于原始帧),调用方应写入元数据。
    static func encodeBounded(
        bgra8Pixels: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        maximumBytes: Int = ResidentVisionImagePolicy.maximumPNGBytes
    ) throws -> Encoded {
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            throw EncodeError.invalidDimensions
        }
        guard bgra8Pixels.count >= bytesPerRow * height else {
            throw EncodeError.dataTooShort
        }
        var w = width
        var h = height
        var currentBytesPerRow = bytesPerRow
        var pixels = bgra8Pixels
        // 尺寸护栏:先保证交付尺寸"合理",再谈字节预算。
        while w > ResidentVisionImagePolicy.maximumDeliveredEdge
            || h > ResidentVisionImagePolicy.maximumDeliveredEdge
        {
            let half = try downscaleHalf(
                pixels: pixels, width: w, height: h,
                bytesPerRow: currentBytesPerRow
            )
            pixels = half.pixels
            w = half.width
            h = half.height
            currentBytesPerRow = half.bytesPerRow
        }
        while true {
            let data = try encode(
                bgra8Pixels: pixels,
                width: w,
                height: h,
                bytesPerRow: currentBytesPerRow
            )
            if data.count <= maximumBytes {
                return Encoded(data: data, width: w, height: h)
            }
            if w <= ResidentVisionImagePolicy.minimumDownscaleEdge
                || h <= ResidentVisionImagePolicy.minimumDownscaleEdge
            {
                throw EncodeError.tooLargeForBudget
            }
            let half = try downscaleHalf(
                pixels: pixels, width: w, height: h,
                bytesPerRow: currentBytesPerRow
            )
            pixels = half.pixels
            w = half.width
            h = half.height
            currentBytesPerRow = half.bytesPerRow
        }
    }

    /// 2×2 box-average 半尺寸降采样(BGRA8 premultiplied,逐行取均值)。
    /// 输出为紧密行(宽×4)。对奇数宽高取 floor。
    private static func downscaleHalf(
        pixels: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> (pixels: Data, width: Int, height: Int, bytesPerRow: Int) {
        let outWidth = width / 2
        let outHeight = height / 2
        guard outWidth > 0, outHeight > 0,
              bytesPerRow >= width * 4,
              pixels.count >= bytesPerRow * height
        else {
            throw EncodeError.invalidDimensions
        }
        let outBytesPerRow = outWidth * 4
        var output = Data(count: outBytesPerRow * outHeight)
        pixels.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let src = source.bindMemory(to: UInt8.self).baseAddress,
                      let dst = destination.bindMemory(to: UInt8.self).baseAddress
                else { return }
                for y in 0..<outHeight {
                    let row0 = y * 2
                    let row1 = y * 2 + 1
                    for x in 0..<outWidth {
                        let x0 = x * 2
                        let x1 = x * 2 + 1
                        for channel in 0..<4 {
                            let sum =
                                Int(src[row0 * bytesPerRow + x0 * 4 + channel])
                                + Int(src[row0 * bytesPerRow + x1 * 4 + channel])
                                + Int(src[row1 * bytesPerRow + x0 * 4 + channel])
                                + Int(src[row1 * bytesPerRow + x1 * 4 + channel])
                            dst[y * outBytesPerRow + x * 4 + channel] = UInt8(
                                (sum + 2) >> 2
                            )
                        }
                    }
                }
            }
        }
        return (output, outWidth, outHeight, outBytesPerRow)
    }
}

// MARK: - 会话私有文件策略

/// 画面文件只写入当前居民会话的私有子目录:
///   <root>/<sessionID>/<captureID>.png (目录 0700,文件 0600,原子写)
/// 工具合同不存在路径参数,模型永远无法指定写入位置。
enum ResidentVisionFilePolicy {
    static let directoryName = "ResidentVision"

    static func defaultRoot() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("gmgn radio/\(directoryName)", isDirectory: true)
    }

    static func sessionDirectory(root: URL, sessionID: UUID) -> URL {
        root.appendingPathComponent(
            sessionID.uuidString,
            isDirectory: true
        )
    }

    static func scopedFileURL(
        root: URL,
        sessionID: UUID,
        captureID: UUID
    ) -> URL {
        sessionDirectory(root: root, sessionID: sessionID)
            .appendingPathComponent("\(captureID.uuidString).png")
    }

    static func isScoped(_ url: URL, root: URL) -> Bool {
        guard url.pathExtension.lowercased() == "png",
              isScopedSessionDirectory(
                  url.deletingLastPathComponent(), root: root)
        else {
            return false
        }
        return true
    }

    static func isScopedSessionDirectory(_ url: URL, root: URL) -> Bool {
        let standardizedRoot = root.standardizedFileURL.path
        let standardizedURL = url.standardizedFileURL.path
        guard standardizedURL.hasPrefix(standardizedRoot + "/") else {
            return false
        }
        let components = String(
            standardizedURL.dropFirst(standardizedRoot.count + 1)
        )
        .split(separator: "/", omittingEmptySubsequences: true)
        return components.count == 1
            && UUID(uuidString: String(components[0])) != nil
    }

    static func prepareSessionDirectory(
        root: URL,
        sessionID: UUID
    ) throws {
        let directory = sessionDirectory(root: root, sessionID: sessionID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    @discardableResult
    static func write(
        pngData: Data,
        root: URL,
        sessionID: UUID,
        captureID: UUID
    ) throws -> URL {
        try prepareSessionDirectory(root: root, sessionID: sessionID)
        let url = scopedFileURL(
            root: root,
            sessionID: sessionID,
            captureID: captureID
        )
        try pngData.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    /// 只允许清理本策略名下、root 内的会话目录。
    static func purgeSessionDirectory(root: URL, sessionID: UUID) throws {
        let directory = sessionDirectory(root: root, sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        guard isScopedSessionDirectory(directory, root: root) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: directory)
    }
}

// MARK: - 新鲜度门控(纯逻辑;生产捕获与工具共用)

enum ResidentVisionGate {
    /// 居民世界侧(工具侧)当前快照;由接线方注入。
    struct ContextSnapshot: Equatable, Sendable {
        let worldID: String
        let worldRevision: UInt64?
    }

    enum Verdict: Equatable, Sendable {
        case accept
        case reject(code: ResidentVisionErrorCode, message: String)
    }

    static func verdict(
        request: ResidentVisionCaptureRequest,
        requestedAt: Date,
        frame: ResidentVisionRenderedFrame,
        context: ContextSnapshot?,
        now: Date
    ) -> Verdict {
        let stamp = frame.stamp

        // 旧空间:渲染帧不属于请求的空间。
        if stamp.worldID != request.worldID {
            return .reject(
                code: .staleWorld,
                message:
                    "画面属于另一个空间(请求 \(request.worldID),实际 \(stamp.worldID));空间已切换,请重新请求。"
            )
        }
        // 旧空间:当前居民上下文与帧/请求不一致(捕获中途切走)。
        if let context, context.worldID != stamp.worldID {
            return .reject(
                code: .staleWorld,
                message: "当前居民空间已切换,画面不再属于当前空间。"
            )
        }
        // 旧空间:请求的空间已经不是居民当前所在空间。
        if let context, context.worldID != request.worldID {
            return .reject(
                code: .staleWorld,
                message: "当前居民空间已切换,本次请求已失效。"
            )
        }
        // 旧帧:画面渲染早于请求发起时间(只应来自缓存/预渲染)。
        if stamp.capturedAt < requestedAt {
            return .reject(
                code: .staleFrame,
                message: "画面早于请求时间(旧帧),未返回。"
            )
        }
        // 旧帧:画面超过最大时限。
        let age = now.timeIntervalSince(stamp.capturedAt)
        if age > request.maximumAge {
            return .reject(
                code: .staleFrame,
                message:
                    "画面已超过最大时限 \(request.maximumAge) 秒(实际 \(age) 秒),未返回。"
            )
        }
        // 旧帧:请求方期望(请求条件)的 revision 高于当前世界上下文 → 世界被
        // 重载/重置,画面不可能是请求时刻的状态。这只是请求条件的核对,
        // 不代表画面帧的 revision 已被证明。
        if let expected = request.expectedWorldRevision,
           let context,
           let contextRevision = context.worldRevision,
           contextRevision < expected
        {
            return .reject(
                code: .staleFrame,
                message:
                    "世界状态已重载(期望 revision \(expected),当前 \(contextRevision));画面不是请求时的状态。"
            )
        }
        // 无画面:帧本身为空。
        if frame.width <= 0 || frame.height <= 0
            || frame.pixelsBGRA.isEmpty
        {
            return .reject(
                code: .noPicture,
                message: "画面为空,未返回。"
            )
        }
        return .accept
    }
}

// MARK: - 捕获服务(生产编排;一次一帧,只在请求之后渲染)

@MainActor
final class ResidentVisionCaptureService {
    typealias ContextProvider = @MainActor () -> ResidentVisionGate
        .ContextSnapshot?

    let surface: (any ResidentVisionSurface)?
    let fileRoot: URL?
    private let context: ContextProvider
    private let now: @MainActor () -> Date
    private let pngMaximumBytes: Int

    init(
        surface: (any ResidentVisionSurface)? = nil,
        fileRoot: URL? = ResidentVisionFilePolicy.defaultRoot(),
        context: @escaping ContextProvider = { nil },
        now: @escaping @MainActor () -> Date = { Date() },
        pngMaximumBytes: Int = ResidentVisionImagePolicy.maximumPNGBytes
    ) {
        self.surface = surface
        self.fileRoot = fileRoot
        self.context = context
        self.now = now
        self.pngMaximumBytes = pngMaximumBytes
    }

    /// 完成一次"请求当前空间照片"。返回的帧保证在请求之后新渲染,
    /// 且已通过 旧空间/旧帧/无画面 门控;超时返回 .timeout;调用方取消返回
    /// .cancelled(取消竞争的迟到帧不会解析成其他结果)。
    func capture(
        _ request: ResidentVisionCaptureRequest
    ) async -> ResidentVisionCaptureOutcome {
        guard !Task.isCancelled else {
            return .failure(
                code: .cancelled,
                message: "画面请求已取消。"
            )
        }
        let worldID = request.worldID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !worldID.isEmpty else {
            return .failure(
                code: .invalidParameters,
                message: "worldID 不能为空。"
            )
        }
        guard ResidentVisionCatalog.isRegistered(
            request.perspective.rawValue
        ) else {
            return .failure(
                code: .perspectiveUnavailable,
                message: "视角 \(request.perspective.rawValue) 尚未实现,不可用。"
            )
        }
        guard request.timeout <= ResidentVisionCaptureRequest.maximumTimeout,
              request.maximumAge >= 0.1
        else {
            return .failure(
                code: .invalidParameters,
                message: "请求参数不合法(超时或最大时限越界)。"
            )
        }
        guard let surface else {
            return .failure(
                code: .captureUnavailable,
                message: "没有可用的舞台渲染画面源(全舞台渲染器未接入)。"
            )
        }

        let requestedAt = now()
        let sourceResult = await awaitSurfaceFrame(
            surface: surface,
            request: request,
            requestedAt: requestedAt
        )

        guard case let .frame(frame) = sourceResult else {
            if case let .failure(code, message) = sourceResult {
                return .failure(code: code, message: message)
            }
            return .failure(
                code: .noPicture,
                message: "没有可用的画面。"
            )
        }

        // 生产门控:旧空间/旧帧/无画面在此统一拒绝。
        let gate = ResidentVisionGate.verdict(
            request: request,
            requestedAt: requestedAt,
            frame: frame,
            context: context(),
            now: now()
        )
        if case let .reject(code, message) = gate {
            return .failure(code: code, message: message)
        }

        // 受预算约束编码:超限先自动缩小;缩到下限仍超限 → image_too_large。
        let encoded: ResidentVisionPNG.Encoded
        do {
            encoded = try ResidentVisionPNG.encodeBounded(
                bgra8Pixels: frame.pixelsBGRA,
                width: frame.width,
                height: frame.height,
                bytesPerRow: frame.bytesPerRow,
                maximumBytes: pngMaximumBytes
            )
        } catch ResidentVisionPNG.EncodeError.tooLargeForBudget {
            return .failure(
                code: .imageTooLarge,
                message:
                    "画面缩到最低尺寸后仍超过传输预算(\(pngMaximumBytes) 字节),未返回。"
            )
        } catch {
            return .failure(
                code: .encodingFailed,
                message: "画面编码失败:\(error.localizedDescription)"
            )
        }
        let pngData = encoded.data
        guard ResidentVisionPNG.looksPlausible(pngData) else {
            return .failure(
                code: .encodingFailed,
                message: "画面编码结果异常。"
            )
        }

        let metadata = ResidentVisionMetadata.make(
            renderedFrame: frame,
            perspective: request.perspective,
            expectedWorldRevision: request.expectedWorldRevision,
            deliveredWidth: encoded.width,
            deliveredHeight: encoded.height
        )

        let fileURL: URL?
        if request.includeFileURL, let fileRoot {
            do {
                fileURL = try ResidentVisionFilePolicy.write(
                    pngData: pngData,
                    root: fileRoot,
                    sessionID: request.sessionID,
                    captureID: metadata.captureID
                )
            } catch {
                return .failure(
                    code: .fileWriteFailed,
                    message: "画面无法写入会话目录:\(error.localizedDescription)"
                )
            }
        } else {
            fileURL = nil
        }

        return .success(
            ResidentVisionImage(
                pngData: pngData,
                metadata: metadata,
                fileURL: fileURL
            )
        )
    }

    /// 在 timeout 内等待帧源;先到的胜出,另一方被取消。
    private func awaitSurfaceFrame(
        surface: any ResidentVisionSurface,
        request: ResidentVisionCaptureRequest,
        requestedAt: Date
    ) async -> ResidentVisionSurfaceFrameResult {
        await withTaskGroup(
            of: ResidentVisionSurfaceFrameResult.self
        ) { group in
            group.addTask {
                await surface.captureCurrentObservation(
                    request: request,
                    requestedAt: requestedAt
                )
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(request.timeout))
                } catch {
                    // 本任务被取消(通常是请求已超时/调用方已取消):如实返回
                    // cancelled,而不是把"取消"误报成 timeout。
                    return .failure(
                        code: .cancelled,
                        message: "等待画面已取消。"
                    )
                }
                return .failure(
                    code: .timeout,
                    message:
                        "等待画面超时(\(request.timeout) 秒),请稍后重试。"
                )
            }
            defer { group.cancelAll() }
            guard let first = await group.next() else {
                return .failure(
                    code: .timeout,
                    message: "等待画面超时,请稍后重试。"
                )
            }
            // 调用方已取消:无论先到的是迟到帧还是超时,都如实返回 cancelled,
            // 避免"取消竞争的迟到完成"解析成成功或其它结果。
            if Task.isCancelled {
                return .failure(
                    code: .cancelled,
                    message: "画面请求已取消。"
                )
            }
            return first
        }
    }
}
