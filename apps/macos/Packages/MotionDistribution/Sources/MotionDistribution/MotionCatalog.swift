import Foundation

public struct MotionCatalog: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var motions: [PublishedMotion]

    public init(schemaVersion: Int, motions: [PublishedMotion]) {
        self.schemaVersion = schemaVersion
        self.motions = motions
    }
}

public struct PublishedMotion: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var format: String
    public var path: String
    public var sha256: String
    public var bytes: Int
    public var duration: Double
    public var loop: Bool
    public var avatarFormats: [String]
    public var activityIDs: [String]
    public var strideSpeed: Float?
    public var playbackRate: Float?
    public var inPlace: Bool?
    public var source: PublishedMotionSource

    public init(
        id: String,
        name: String,
        version: String,
        format: String,
        path: String,
        sha256: String,
        bytes: Int,
        duration: Double,
        loop: Bool,
        avatarFormats: [String],
        activityIDs: [String],
        strideSpeed: Float? = nil,
        playbackRate: Float? = nil,
        inPlace: Bool? = nil,
        source: PublishedMotionSource
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.format = format
        self.path = path
        self.sha256 = sha256
        self.bytes = bytes
        self.duration = duration
        self.loop = loop
        self.avatarFormats = avatarFormats
        self.activityIDs = activityIDs
        self.strideSpeed = strideSpeed
        self.playbackRate = playbackRate
        self.inPlace = inPlace
        self.source = source
    }
}

public struct PublishedMotionSource: Codable, Equatable, Sendable {
    public var prompt: String
    public var seed: Int?
    public var generator: PublishedMotionGenerator
}

public struct PublishedMotionGenerator: Codable, Equatable, Sendable {
    public var engine: String
    public var model: String
    public var revision: String
}

public enum MotionDistributionError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case duplicateMotion(String, String)
    case invalidMotionID(String)
    case invalidVersion(String)
    case unsupportedFormat(String)
    case unsafeArtifactPath(String)
    case invalidDigest
    case invalidMetadata
    case insecureURL
    case crossOriginRedirect
    case badHTTPStatus(Int)
    case responseTooLarge
    case sizeMismatch
    case hashMismatch
    case invalidVRMA
    case invalidVMD

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version): "动作目录版本不受支持：\(version)。"
        case let .duplicateMotion(id, version): "动作目录包含重复版本：\(id)@\(version)。"
        case let .invalidMotionID(id): "动作编号无效：\(id)。"
        case let .invalidVersion(version): "动作版本无效：\(version)。"
        case let .unsupportedFormat(format): "动作格式不受支持：\(format)。"
        case let .unsafeArtifactPath(path): "动作下载路径不安全：\(path)。"
        case .invalidDigest: "动作哈希无效。"
        case .invalidMetadata: "动作目录内容无效。"
        case .insecureURL: "动作目录必须使用 HTTPS；本机调试地址除外。"
        case .crossOriginRedirect: "动作下载被重定向到了其他站点。"
        case let .badHTTPStatus(status): "动作服务返回了 HTTP \(status)。"
        case .responseTooLarge: "动作文件超过 500MB 限制。"
        case .sizeMismatch: "动作文件大小与目录记录不一致。"
        case .hashMismatch: "动作文件哈希与目录记录不一致。"
        case .invalidVRMA: "下载文件不是有效的 VRMA。"
        case .invalidVMD: "下载文件不是有效的 VMD。"
        }
    }
}

public enum MotionCatalogValidator {
    public static func validate(_ catalog: MotionCatalog) throws {
        guard catalog.schemaVersion == 1 else {
            throw MotionDistributionError.unsupportedSchema(catalog.schemaVersion)
        }
        var identities = Set<String>()
        for motion in catalog.motions {
            guard motion.id.range(
                of: #"^[a-z0-9][a-z0-9._-]{2,127}$"#,
                options: .regularExpression
            ) != nil else {
                throw MotionDistributionError.invalidMotionID(motion.id)
            }
            guard motion.version.range(
                of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"#,
                options: .regularExpression
            ) != nil else {
                throw MotionDistributionError.invalidVersion(motion.version)
            }
            let identity = "\(motion.id)@\(motion.version)"
            guard identities.insert(identity).inserted else {
                throw MotionDistributionError.duplicateMotion(motion.id, motion.version)
            }
            guard motion.format == "vrma" || motion.format == "vmd" else {
                throw MotionDistributionError.unsupportedFormat(motion.format)
            }
            try validate(path: motion.path)
            guard motion.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
                throw MotionDistributionError.invalidDigest
            }
            guard
                !motion.name.isEmpty,
                motion.bytes > 0,
                motion.bytes <= 500 * 1_024 * 1_024,
                motion.duration.isFinite,
                motion.duration >= 0.1,
                motion.duration <= 300,
                motion.strideSpeed.map({ $0.isFinite && $0 > 0 }) ?? true,
                motion.playbackRate.map({
                    $0.isFinite && $0 > 0 && $0 <= 8
                }) ?? true,
                !motion.source.prompt.isEmpty,
                !motion.source.generator.engine.isEmpty,
                !motion.source.generator.model.isEmpty,
                !motion.source.generator.revision.isEmpty
            else {
                throw MotionDistributionError.invalidMetadata
            }
        }
    }

    static func validate(path: String) throws {
        let decoded = path.removingPercentEncoding ?? path
        let components = decoded
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
        guard
            !decoded.hasPrefix("/"),
            !decoded.contains("\\"),
            !components.contains(".."),
            !components.contains("."),
            !components.contains("")
        else {
            throw MotionDistributionError.unsafeArtifactPath(path)
        }
    }
}
