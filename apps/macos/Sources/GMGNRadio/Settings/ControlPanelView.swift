import AppKit
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import WebKit

struct ControlPanelView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.messageHandlerName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        if let indexURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "ControlPanel"
        ) {
            webView.loadFileURL(
                indexURL,
                allowingReadAccessTo: indexURL.deletingLastPathComponent()
            )
        } else {
            webView.loadHTMLString(
                "<main style='font:14px -apple-system;padding:32px'>管理页资源缺失，请重新构建应用。</main>",
                baseURL: nil
            )
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.messageHandlerName
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        static let messageHandlerName = "gmgnRadio"
        weak var webView: WKWebView?
        private let service: Result<PresenceCommandService, Error>

        override init() {
            service = Result {
                PresenceCommandService(store: try PresencePackageStore.liveStore())
            }
            super.init()
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            do {
                try handle(ControlPanelRequest(message: body))
            } catch {
                reject(id: body["id"] as? String ?? UUID().uuidString, error: error)
            }
        }

        private func handle(_ request: ControlPanelRequest) throws {
            let service = try service.get()
            switch request.command {
            case .list:
                resolve(id: request.id, value: try service.list())
            case .importLocal:
                let panel = NSOpenPanel()
                panel.title = "导入桌宠模型"
                panel.prompt = "安装"
                panel.message = "选择包含 manifest.json 的文件夹，或 .zip / .gmgnpet 模型包。"
                panel.canChooseDirectories = true
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [
                    .folder,
                    .zip,
                    UTType(filenameExtension: "gmgnpet") ?? .data,
                ]
                guard panel.runModal() == .OK, let sourceURL = panel.url else {
                    resolve(id: request.id, value: Optional<PresencePackage>.none)
                    return
                }
                resolve(id: request.id, value: try service.store.installPackage(from: sourceURL))
            case let .download(url):
                download(url: url, requestID: request.id, service: service)
            case let .activate(id):
                try service.store.activate(id: id)
                resolve(id: request.id, value: Optional<String>.none)
            case let .remove(id):
                try service.store.remove(id: id)
                resolve(id: request.id, value: Optional<String>.none)
            }
        }

        private func download(
            url: URL,
            requestID: String,
            service: PresenceCommandService
        ) {
            Task {
                do {
                    let (temporaryURL, response) = try await URLSession.shared.download(from: url)
                    guard
                        let response = response as? HTTPURLResponse,
                        (200 ... 299).contains(response.statusCode),
                        response.url?.scheme?.lowercased() == "https"
                    else {
                        throw URLError(.badServerResponse)
                    }
                    if response.expectedContentLength > 500 * 1_024 * 1_024 {
                        throw PresenceDownloadError.packageTooLarge
                    }
                    let suffix = url.pathExtension.isEmpty ? "gmgnpet" : url.pathExtension
                    let localURL = FileManager.default.temporaryDirectory
                        .appending(path: "gmgn-presence-\(UUID().uuidString).\(suffix)")
                    try FileManager.default.copyItem(at: temporaryURL, to: localURL)
                    defer { try? FileManager.default.removeItem(at: localURL) }
                    resolve(
                        id: requestID,
                        value: try service.store.installPackage(from: localURL)
                    )
                } catch {
                    reject(id: requestID, error: error)
                }
            }
        }

        private func resolve<T: Encodable>(id: String, value: T) {
            do {
                let encoded = try JSONEncoder().encode(value)
                let object = try JSONSerialization.jsonObject(
                    with: encoded,
                    options: [.fragmentsAllowed]
                )
                try send(function: "__gmgnNativeResolve", body: [
                    "id": id,
                    "result": object,
                ])
            } catch {
                reject(id: id, error: error)
            }
        }

        private func reject(id: String, error: Error) {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            try? send(function: "__gmgnNativeReject", body: [
                "id": id,
                "error": message,
            ])
        }

        private func send(function: String, body: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else {
                throw ControlPanelRequestError.malformedMessage
            }
            webView?.evaluateJavaScript("window.\(function)(\(json));")
        }
    }
}

private enum PresenceDownloadError: Error, LocalizedError {
    case packageTooLarge
    var errorDescription: String? { "模型包超过 500 MB，已停止安装。" }
}
