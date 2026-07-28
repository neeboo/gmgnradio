import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class PresenceSettingsModel {
    var packages: [PresencePackage] = []
    var downloadURL = ""
    var message: String?
    var hasError = false
    var isWorking = false

    private let service: PresenceCommandService?
    private let startupError: Error?

    init() {
        do {
            service = PresenceCommandService(store: try PresencePackageStore.liveStore())
            startupError = nil
        } catch {
            service = nil
            startupError = error
        }
    }

    var activePackage: PresencePackage? {
        packages.first(where: \.isActive)
    }

    func load() {
        guard let service else {
            show(error: startupError)
            return
        }
        do {
            packages = try service.list()
        } catch {
            show(error: error)
        }
    }

    func importLocal() {
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
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        install(from: sourceURL)
    }

    func downloadAndInstall() async {
        guard let service else {
            show(error: startupError)
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            let url = try service.validatedDownloadURL(downloadURL)
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

            _ = try service.store.installPackage(from: localURL)
            packages = try service.list()
            downloadURL = ""
            show(message: "模型已安装。")
        } catch {
            show(error: error)
        }
    }

    func activate(_ package: PresencePackage) {
        guard package.rendererAvailable else { return }
        do {
            try requireService().store.activate(id: package.manifest.id)
            packages = try requireService().list()
            show(message: "已切换为 \(package.manifest.name)。")
        } catch {
            show(error: error)
        }
    }

    func remove(_ package: PresencePackage) {
        do {
            try requireService().store.remove(id: package.manifest.id)
            packages = try requireService().list()
            show(message: "已移除 \(package.manifest.name)。")
        } catch {
            show(error: error)
        }
    }

    private func install(from sourceURL: URL) {
        isWorking = true
        defer { isWorking = false }
        do {
            let service = try requireService()
            _ = try service.store.installPackage(from: sourceURL)
            packages = try service.list()
            show(message: "模型已安装。")
        } catch {
            show(error: error)
        }
    }

    private func requireService() throws -> PresenceCommandService {
        if let service {
            return service
        }
        throw startupError ?? PresenceSettingsError.storeUnavailable
    }

    private func show(message: String) {
        self.message = message
        hasError = false
    }

    private func show(error: Error?) {
        message = (error as? LocalizedError)?.errorDescription
            ?? error?.localizedDescription
            ?? "无法打开桌宠目录。"
        hasError = true
    }
}

private enum PresenceDownloadError: Error, LocalizedError {
    case packageTooLarge

    var errorDescription: String? {
        "模型包超过 500 MB，已停止安装。"
    }
}

private enum PresenceSettingsError: Error, LocalizedError {
    case storeUnavailable

    var errorDescription: String? {
        "无法打开桌宠目录。"
    }
}
