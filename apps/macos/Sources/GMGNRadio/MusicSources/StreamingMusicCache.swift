import Foundation

protocol MusicAssetCaching: Sendable {
    func store(
        _ asset: MusicPlaybackAsset,
        trackID: String
    ) async throws -> URL
}

actor StreamingMusicCache: MusicAssetCaching {
    private let rootURL: URL
    private let transport: any MusicProviderHTTPTransport
    private let fileManager: FileManager

    init(
        rootURL: URL? = nil,
        transport: any MusicProviderHTTPTransport =
            URLSessionMusicProviderHTTPTransport(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appending(path: "ai.gmgn.radio/StreamingMusic", directoryHint: .isDirectory)
        self.transport = transport
        self.fileManager = fileManager
    }

    func store(
        _ asset: MusicPlaybackAsset,
        trackID: String
    ) async throws -> URL {
        var request = URLRequest(url: asset.url)
        request.timeoutInterval = 45
        for (name, value) in asset.requestHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let response = try await transport.send(request)
        let data = try checkedProviderResponse(response)

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let fileExtension = asset.url.pathExtension.isEmpty
            ? "m4a"
            : asset.url.pathExtension.lowercased()
        let safeID = String(
            trackID.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        )
        let destination = rootURL.appending(
            path: "\(safeID).\(fileExtension)"
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }
}
