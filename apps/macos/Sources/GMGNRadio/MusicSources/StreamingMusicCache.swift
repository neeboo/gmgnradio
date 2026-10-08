import Foundation
import CryptoKit
import Darwin

protocol MusicAssetCaching: Sendable {
    func store(
        _ asset: MusicPlaybackAsset,
        trackID: String
    ) async throws -> URL
}

actor StreamingMusicCache: MusicAssetCaching {
    private let authority: RustMusicCacheClient
    private let transport: any MusicProviderHTTPTransport

    init(
        authority: RustMusicCacheClient,
        transport: any MusicProviderHTTPTransport =
            URLSessionMusicProviderHTTPTransport()
    ) {
        self.authority = authority
        self.transport = transport
    }

    func store(
        _ asset: MusicPlaybackAsset,
        trackID: String
    ) async throws -> URL {
        let fileExtension = asset.url.pathExtension.isEmpty
            ? "m4a"
            : asset.url.pathExtension.lowercased()
        let initial = try await authority.prepare(trackID: trackID, fileExtension: fileExtension,
            requestID: UUID().uuidString)
        if initial.state == "ready" { return try await confirmedURL(initial) }
        guard initial.state == "pending", let actionID = initial.actionID else {
            throw MusicProviderClientError.playbackUnavailable
        }
        // A lost claim reply is deliberately not retried: the durable slot may already be claimed.
        let claimed = try await authority.claim(actionID: actionID)
        guard claimed.state == "claimed", let stagePath = claimed.stagePath else {
            throw MusicProviderClientError.playbackUnavailable
        }
        let stage = try await privateURL(stagePath)
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
            // The awaited native transport has ended; this download produced no usable payload.
            _ = try? await authority.failed(actionID: actionID)
            throw error
        }
        let valid = StreamingAudioPayloadValidator.isAudio(data, mimeType: response.mimeType)
        guard valid, data.count <= 256 * 1024 * 1024 else {
            _ = try? await authority.failed(actionID: actionID)
            throw MusicProviderClientError.invalidAudioPayload
        }
        let hash = try await Task.detached {
            let manager = FileManager.default
            try manager.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard !manager.fileExists(atPath: stage.path) else { throw MusicProviderClientError.invalidAudioPayload }
            try data.write(to: stage, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.path)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.value
        let completed: RustMusicCacheClient.View
        do {
            completed = try await authority.receipt(actionID: actionID, sha256: hash,
                bytes: UInt64(data.count), audioValid: valid)
        } catch {
            // Recover only the existing durable action; never repeat the HTTP download.
            let recovered = try await authority.read(actionID: actionID)
            guard recovered.state == "ready" else { throw error }
            return try await confirmedURL(recovered)
        }
        return try await confirmedURL(completed)
    }

    private func privateURL(_ path: String) async throws -> URL {
        let root = authority.directory
        let url = URL(fileURLWithPath: path)
        guard let actualParent = realpath(root.path, nil) else {
            throw MusicProviderClientError.invalidAudioPayload
        }
        defer { free(actualParent) }
        let canonicalParent = String(cString: actualParent)
        guard canonicalParent == root.path,
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".", url.lastPathComponent != "..",
              path == canonicalParent + "/" + url.lastPathComponent else {
            throw MusicProviderClientError.invalidAudioPayload
        }
        var facts = stat()
        if lstat(path, &facts) == 0 {
            guard facts.st_mode & S_IFMT == S_IFREG else { throw MusicProviderClientError.invalidAudioPayload }
        } else if errno != ENOENT {
            throw MusicProviderClientError.invalidAudioPayload
        }
        return url
    }
    private func confirmedURL(_ view: RustMusicCacheClient.View) async throws -> URL {
        guard view.state == "ready", let path = view.finalPath else {
            throw MusicProviderClientError.playbackUnavailable
        }
        return try await privateURL(path)
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
