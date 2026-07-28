import Foundation

enum PresenceCommandError: Error, Equatable, LocalizedError {
    case secureDownloadRequired

    var errorDescription: String? {
        switch self {
        case .secureDownloadRequired:
            "模型下载地址必须使用 HTTPS。"
        }
    }
}

struct PresenceCommandService: Sendable {
    let store: PresencePackageStore

    func list() throws -> [PresencePackage] {
        try store.listPackages()
    }

    func validatedDownloadURL(_ value: String) throws -> URL {
        guard
            let url = URL(string: value),
            url.scheme?.lowercased() == "https",
            url.host != nil
        else {
            throw PresenceCommandError.secureDownloadRequired
        }
        return url
    }
}
