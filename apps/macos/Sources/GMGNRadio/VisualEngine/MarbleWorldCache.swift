import Foundation

enum MarbleWorldCacheError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "Marble 空间资源下载失败。"
    }
}

actor MarbleWorldCache {
    private let rootURL: URL
    private let session: URLSession

    init(
        rootURL: URL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.gmgn.radio/marble", isDirectory: true),
        session: URLSession = .shared
    ) {
        self.rootURL = rootURL
        self.session = session
    }

    func localSplat(
        for world: MarbleWorld,
        asset: MarbleSplatAsset
    ) async throws -> URL {
        let worldDirectory = rootURL.appendingPathComponent(
            sanitized(world.id),
            isDirectory: true
        )
        let destination = worldDirectory.appendingPathComponent(
            "scene-\(asset.quality.rawValue).spz"
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        try FileManager.default.createDirectory(
            at: worldDirectory,
            withIntermediateDirectories: true
        )
        let (temporaryURL, response) = try await session.download(
            from: asset.url
        )
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode)
        else {
            throw MarbleWorldCacheError.invalidResponse
        }

        let stagedURL = worldDirectory.appendingPathComponent(
            ".scene-\(asset.quality.rawValue)-\(UUID().uuidString).spz"
        )
        try FileManager.default.moveItem(at: temporaryURL, to: stagedURL)
        do {
            try FileManager.default.moveItem(at: stagedURL, to: destination)
        } catch CocoaError.fileWriteFileExists {
            try? FileManager.default.removeItem(at: stagedURL)
        }
        return destination
    }

    func localCollider(for world: MarbleWorld) async throws -> URL? {
        guard let remoteURL = world.colliderURL else { return nil }
        let worldDirectory = rootURL.appendingPathComponent(
            sanitized(world.id),
            isDirectory: true
        )
        let destination = worldDirectory.appendingPathComponent("collider.glb")
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        try FileManager.default.createDirectory(
            at: worldDirectory,
            withIntermediateDirectories: true
        )
        let (temporaryURL, response) = try await session.download(from: remoteURL)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode)
        else {
            throw MarbleWorldCacheError.invalidResponse
        }
        let stagedURL = worldDirectory.appendingPathComponent(
            ".collider-\(UUID().uuidString).glb"
        )
        try FileManager.default.moveItem(at: temporaryURL, to: stagedURL)
        do {
            try FileManager.default.moveItem(at: stagedURL, to: destination)
        } catch CocoaError.fileWriteFileExists {
            try? FileManager.default.removeItem(at: stagedURL)
        }
        return destination
    }

    private func sanitized(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "-"
                ? character
                : "_"
        }.reduce(into: "") { $0.append($1) }
    }
}
