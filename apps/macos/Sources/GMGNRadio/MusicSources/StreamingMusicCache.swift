import Foundation
import os

protocol MusicAssetCaching: Sendable {
    func store(
        _ asset: MusicPlaybackAsset,
        trackID: String
    ) async throws -> URL
}

actor StreamingMusicCache: MusicAssetCaching {
    private let logger = Logger(
        subsystem: "ai.gmgn.radio",
        category: "StreamingMusicCache"
    )
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
        let fileExtension = asset.url.pathExtension.isEmpty
            ? "m4a"
            : asset.url.pathExtension.lowercased()
        let safeID = String(
            trackID.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        )
        let destination = rootURL.appending(
            path: "\(safeID).\(fileExtension)"
        )
        if
            fileManager.fileExists(atPath: destination.path),
            let attributes = try? fileManager.attributesOfItem(
                atPath: destination.path
            ),
            let size = attributes[.size] as? NSNumber,
            size.int64Value > 0,
            let cachedData = try? Data(contentsOf: destination),
            StreamingAudioPayloadValidator.isAudio(cachedData)
        {
            logger.info(
                "命中音频缓存：track=\(trackID, privacy: .public)，file=\(destination.path, privacy: .public)，bytes=\(size.int64Value)"
            )
            return destination
        }
        if fileManager.fileExists(atPath: destination.path) {
            let existingData = try? Data(contentsOf: destination)
            logger.error(
                "清理无效音频缓存：track=\(trackID, privacy: .public)，file=\(destination.path, privacy: .public)，bytes=\(existingData?.count ?? 0)，magic=\(StreamingAudioPayloadValidator.magicDescription(existingData ?? Data()), privacy: .public)"
            )
            try? fileManager.removeItem(at: destination)
        }

        logger.info(
            "开始下载音频：track=\(trackID, privacy: .public)，host=\(asset.url.host ?? "nil", privacy: .public)，file=\(destination.path, privacy: .public)，headerNames=\(asset.requestHeaders.keys.sorted().joined(separator: ","), privacy: .public)"
        )
        var request = URLRequest(url: asset.url)
        request.timeoutInterval = 45
        for (name, value) in asset.requestHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let response: MusicProviderHTTPResponse
        let data: Data
        do {
            response = try await transport.send(request)
            data = try checkedProviderResponse(response)
        } catch {
            logger.error(
                "音频下载失败：track=\(trackID, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        logger.info(
            "音频下载响应：track=\(trackID, privacy: .public)，status=\(response.statusCode)，mime=\(response.mimeType ?? "nil", privacy: .public)，finalHost=\(response.responseURL?.host ?? "nil", privacy: .public)，finalPath=\(response.responseURL?.path ?? "nil", privacy: .public)，bytes=\(data.count)，magic=\(StreamingAudioPayloadValidator.magicDescription(data), privacy: .public)"
        )
        guard StreamingAudioPayloadValidator.isAudio(
            data,
            mimeType: response.mimeType
        ) else {
            logger.error(
                "拒绝非音频响应：track=\(trackID, privacy: .public)，mime=\(response.mimeType ?? "nil", privacy: .public)，magic=\(StreamingAudioPayloadValidator.magicDescription(data), privacy: .public)"
            )
            throw MusicProviderClientError.invalidAudioPayload
        }

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        logger.info(
            "音频缓存完成：track=\(trackID, privacy: .public)，bytes=\(data.count)，file=\(destination.path, privacy: .public)"
        )
        return destination
    }
}

enum StreamingAudioPayloadValidator {
    static func isAudio(
        _ data: Data,
        mimeType: String? = nil
    ) -> Bool {
        let normalizedMIME = mimeType?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if
            normalizedMIME?.hasPrefix("text/") == true
                || normalizedMIME == "application/json"
                || normalizedMIME == "application/xml"
        {
            return false
        }
        if hasPrefix(data, [0x49, 0x44, 0x33]) {
            return true
        }
        if data.count >= 2 {
            let first = data[data.startIndex]
            let second = data[data.index(after: data.startIndex)]
            if first == 0xFF, second & 0xE0 == 0xE0 {
                return true
            }
        }
        if hasPrefix(data, Array("fLaC".utf8)) {
            return true
        }
        if hasPrefix(data, Array("OggS".utf8)) {
            return true
        }
        if hasPrefix(data, Array("RIFF".utf8)),
            containsASCII(data, "WAVE", at: 8)
        {
            return true
        }
        if hasPrefix(data, Array("FORM".utf8)),
            containsASCII(data, "AIFF", at: 8)
                || containsASCII(data, "AIFC", at: 8)
        {
            return true
        }
        if containsASCII(data, "ftyp", at: 4) {
            return true
        }
        return normalizedMIME?.hasPrefix("audio/") == true
            && !looksLikeDocument(data)
    }

    static func magicDescription(_ data: Data) -> String {
        guard !data.isEmpty else {
            return "empty"
        }
        return data.prefix(12)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    private static func looksLikeDocument(_ data: Data) -> Bool {
        let prefix = String(
            decoding: data.prefix(64),
            as: UTF8.self
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        return prefix.hasPrefix("<!doctype")
            || prefix.hasPrefix("<html")
            || prefix.hasPrefix("<?xml")
            || prefix.hasPrefix("{")
            || prefix.hasPrefix("[")
    }

    private static func hasPrefix(
        _ data: Data,
        _ bytes: [UInt8]
    ) -> Bool {
        data.count >= bytes.count
            && Array(data.prefix(bytes.count)) == bytes
    }

    private static func containsASCII(
        _ data: Data,
        _ value: String,
        at offset: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard data.count >= offset + bytes.count else {
            return false
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: bytes.count)
        return Array(data[start ..< end]) == bytes
    }
}
