import Foundation

enum PresenceEngine: String, Codable, Sendable {
    case orb
    case live2D = "live2d"
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
            "找不到 Live2D 模型入口文件。"
        case .modelReferenceMissing:
            "Live2D 模型引用的核心文件不存在。"
        case .unsupportedPackage:
            "目前支持文件夹、.zip 和 .gmgnpet 包。"
        case .alreadyInstalled:
            "这个桌宠已经安装。"
        case .cannotRemoveBuiltIn:
            "内置呼吸球不能删除。"
        }
    }
}
