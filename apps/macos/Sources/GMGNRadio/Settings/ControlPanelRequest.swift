import Foundation

enum ControlPanelCommand: Equatable {
    case list
    case importLocal
    case download(url: URL)
    case activate(id: String)
    case remove(id: String)
}

enum ControlPanelRequestError: Error, Equatable, LocalizedError {
    case malformedMessage
    case unknownCommand
    case missingPayload
    case insecureDownloadURL

    var errorDescription: String? {
        switch self {
        case .malformedMessage: "控制台消息格式不正确。"
        case .unknownCommand: "控制台发送了未知操作。"
        case .missingPayload: "控制台操作缺少必要参数。"
        case .insecureDownloadURL: "模型下载地址必须使用 HTTPS。"
        }
    }
}

struct ControlPanelRequest: Equatable {
    let id: String
    let command: ControlPanelCommand

    init(message: [String: Any]) throws {
        guard
            let id = message["id"] as? String,
            !id.isEmpty,
            let commandName = message["command"] as? String,
            let payload = message["payload"] as? [String: Any]
        else {
            throw ControlPanelRequestError.malformedMessage
        }
        self.id = id
        switch commandName {
        case "presence.list":
            command = .list
        case "presence.import":
            command = .importLocal
        case "presence.download":
            guard let value = payload["url"] as? String else {
                throw ControlPanelRequestError.missingPayload
            }
            guard
                let url = URL(string: value),
                url.scheme?.lowercased() == "https",
                url.host != nil
            else {
                throw ControlPanelRequestError.insecureDownloadURL
            }
            command = .download(url: url)
        case "presence.activate":
            command = .activate(id: try Self.requiredID(in: payload))
        case "presence.remove":
            command = .remove(id: try Self.requiredID(in: payload))
        default:
            throw ControlPanelRequestError.unknownCommand
        }
    }

    private static func requiredID(in payload: [String: Any]) throws -> String {
        guard let id = payload["id"] as? String, !id.isEmpty else {
            throw ControlPanelRequestError.missingPayload
        }
        return id
    }
}
