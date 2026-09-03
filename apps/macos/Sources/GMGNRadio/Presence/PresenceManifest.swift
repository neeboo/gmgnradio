import Foundation

enum PresenceEngine: String, Codable, Sendable {
    case orb
    case live2D = "live2d"
    case vrm
    case pmx
}

struct PresenceManifest: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let engine: PresenceEngine
    let entry: String
    let thumbnail: String?
    let author: String?
    let license: String?

    init(
        id: String,
        name: String,
        version: String,
        engine: PresenceEngine,
        entry: String,
        thumbnail: String? = nil,
        author: String? = nil,
        license: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.engine = engine
        self.entry = entry
        self.thumbnail = thumbnail
        self.author = author
        self.license = license
    }
}

struct PresencePackage: Codable, Equatable, Sendable {
    let manifest: PresenceManifest
    let installPath: String?
    let thumbnailPath: String?
    let isActive: Bool
    let isBuiltIn: Bool
    let rendererAvailable: Bool
}

enum PresencePackageError: Error, Equatable, LocalizedError {
    case packageNotFound
    case manifestMissing
    case invalidManifest
    case invalidIdentifier
    case invalidEntryPath
    case modelFileMissing
    case modelReferenceMissing
    case invalidVRM
    case invalidPMX
    case missingPMXTexture(String)
    case unsafeArchiveEntry(String)
    case unsupportedPackage
    case alreadyInstalled
    case cannotRemoveBuiltIn

    var errorDescription: String? {
        switch self {
        case .packageNotFound:
            "找不到这个桌宠。"
        case .manifestMissing:
            "包内缺少 manifest.json。"
        case .invalidManifest:
            "manifest.json 格式不正确。"
        case .invalidIdentifier:
            "桌宠 ID 只能包含字母、数字、点、横线和下划线。"
        case .invalidEntryPath:
            "模型入口路径不安全或格式不正确。"
        case .modelFileMissing:
            "找不到模型入口文件。"
        case .modelReferenceMissing:
            "模型引用的核心文件不存在。"
        case .invalidVRM:
            "文件不是有效的 VRM 0.x 或 VRM 1.0 模型。"
        case .invalidPMX:
            "文件不是有效的 PMX 2.0 或 PMX 2.1 模型。"
        case let .missingPMXTexture(path):
            "PMX 引用的纹理不存在：\(path)"
        case let .unsafeArchiveEntry(path):
            "压缩包包含不安全的路径：\(path)"
        case .unsupportedPackage:
            "目前支持 Live2D 模型包、VRM 文件，以及 PMX 目录或 ZIP。"
        case .alreadyInstalled:
            "这个桌宠已经安装。"
        case .cannotRemoveBuiltIn:
            "内置呼吸球不能删除。"
        }
    }
}
