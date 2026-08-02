import Foundation
import CommonCrypto
import CryptoKit
import os
import Security

struct NeteaseMusicProviderClient: AccountMusicProviderClient {
    private static let logger = Logger(
        subsystem: "ai.gmgn.radio",
        category: "NeteasePlayback"
    )
    private let transport: any MusicProviderHTTPTransport
    private let baseURL: URL
    private let detailRequestConcurrency: Int

    init(
        transport: any MusicProviderHTTPTransport =
            URLSessionMusicProviderHTTPTransport(),
        baseURL: URL = URL(string: "https://music.163.com")!,
        detailRequestConcurrency: Int = 6
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.detailRequestConcurrency = max(1, detailRequestConcurrency)
    }

    func capabilities(
        session: MusicProviderSession
    ) async throws -> MusicAccountCapabilities {
        _ = try session.cookieHeader()
        return MusicAccountCapabilities(
            canSearchCatalog: true,
            canReadLibrary: true,
            canReadPlaylists: true,
            canReadRecentPlays: false,
            canPlay: true
        )
    }

    func search(
        _ request: MusicSearchRequest,
        session: MusicProviderSession
    ) async throws -> [MusicProviderTrack] {
        let term = searchTerm(for: request)
        guard !term.isEmpty else {
            return []
        }

        var urlRequest = providerRequest(
            path: "/api/search/get/web",
            cookie: try session.cookieHeader()
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        urlRequest.httpBody = formData([
            URLQueryItem(name: "s", value: term),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(
                name: "limit",
                value: String(max(1, min(request.limit, 50)))
            ),
            URLQueryItem(name: "offset", value: "0"),
        ])

        let data = try checkedProviderResponse(
            await transport.send(urlRequest)
        )
        let response = try JSONDecoder().decode(
            NeteaseSearchResponse.self,
            from: data
        )
        let tracks = (response.result?.songs ?? []).map {
            $0.providerTrack(matchScore: 0.86, userAffinity: 0.45)
        }
        return await backfillMissingArtwork(
            in: tracks,
            cookie: try session.cookieHeader()
        )
    }

    func fetchUserLibrary(
        session: MusicProviderSession
    ) async throws -> MusicProviderLibrary {
        let cookie = try session.cookieHeader()
        let userID = try await fetchUserID(cookie: cookie)

        var components = URLComponents(
            url: baseURL.appending(path: "/api/user/playlist"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "uid", value: String(userID)),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "offset", value: "0"),
        ]
        let playlistsData = try checkedProviderResponse(
            await transport.send(
                providerRequest(url: components.url!, cookie: cookie)
            )
        )
        let playlistsResponse = try JSONDecoder().decode(
            NeteasePlaylistsResponse.self,
            from: playlistsData
        )
        let playlists = Array((playlistsResponse.playlist ?? []).prefix(50))
        let mappedPlaylists = playlists.map {
            $0.providerPlaylist(tracks: [])
        }

        return MusicProviderLibrary(
            savedTracks: [],
            playlists: mappedPlaylists,
            recentlyPlayedTrackIDs: []
        )
    }

    func fetchPlaylistPage(
        playlistID: String,
        offset: Int,
        limit: Int,
        session: MusicProviderSession
    ) async throws -> MusicProviderPlaylistPage {
        let cookie = try session.cookieHeader()
        let detail = try await playlistDetail(
            playlistID: playlistID,
            cookie: cookie
        )
        let embeddedTracks = detail.playlist?.tracks ?? []
        let embeddedByID = Dictionary(
            uniqueKeysWithValues: embeddedTracks.map { ($0.id, $0) }
        )
        let orderedIDs = detail.playlist?.trackIds?.map(\.id)
            ?? embeddedTracks.map(\.id)
        let totalTrackCount = max(
            detail.playlist?.trackCount ?? 0,
            orderedIDs.count
        )
        let safeOffset = min(max(0, offset), orderedIDs.count)
        let pageIDs = Array(
            orderedIDs.dropFirst(safeOffset).prefix(max(1, limit))
        )
        // 歌单详情里的内嵌歌曲经常省略专辑封面。分页时始终读取
        // 当前 20 首的完整歌曲详情，保证每首歌都带自己的封面。
        let hydrated = try await songDetails(
            ids: pageIDs,
            cookie: cookie
        )
        let hydratedByID = Dictionary(
            uniqueKeysWithValues: hydrated.map { ($0.id, $0) }
        )
        let tracks = pageIDs.compactMap { id in
            hydratedByID[id] ?? embeddedByID[id]
        }.map {
            $0.providerTrack(matchScore: 0.72, userAffinity: 1)
        }
        return MusicProviderPlaylistPage(
            playlistID: playlistID,
            tracks: tracks,
            offset: safeOffset,
            totalTrackCount: totalTrackCount
        )
    }

    private func playlistDetail(
        playlistID: String,
        cookie: String
    ) async throws -> NeteasePlaylistDetailResponse {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/v6/playlist/detail"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: playlistID),
            URLQueryItem(name: "n", value: "1000"),
            URLQueryItem(name: "s", value: "0"),
        ]
        let data = try checkedProviderResponse(
            await transport.send(
                providerRequest(url: components.url!, cookie: cookie)
            )
        )
        return try JSONDecoder().decode(
            NeteasePlaylistDetailResponse.self,
            from: data
        )
    }

    private func songDetails(
        ids: [Int64],
        cookie: String
    ) async throws -> [NeteaseTrackDTO] {
        guard !ids.isEmpty else {
            return []
        }
        var components = URLComponents(
            url: baseURL.appending(path: "/api/song/detail/"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "ids",
                value: "[\(ids.map(String.init).joined(separator: ","))]"
            ),
        ]
        let data = try checkedProviderResponse(
            await transport.send(
                providerRequest(url: components.url!, cookie: cookie)
            )
        )
        return try JSONDecoder().decode(
            NeteaseSongDetailResponse.self,
            from: data
        ).songs
    }

    private func fetchUserID(cookie: String) async throws -> Int64 {
        if
            let request = try? NeteaseWeAPIRequestEncoder
                .accountStatusRequest(cookie: cookie, baseURL: baseURL),
            let response = try? await transport.send(request),
            let data = try? checkedProviderResponse(response),
            let status = try? JSONDecoder().decode(
                NeteaseAccountResponse.self,
                from: data
            )
        {
            if let userID = status.resolvedProfile?.userId {
                return userID
            }
            Self.logger.warning(
                "网易云新登录状态没有用户资料：code=\(status.code ?? -1)，message=\(status.message ?? "nil", privacy: .public)"
            )
        }

        let legacyData = try checkedProviderResponse(
            await transport.send(
                providerRequest(path: "/api/nuser/account/get", cookie: cookie)
            )
        )
        let legacyStatus = try JSONDecoder().decode(
            NeteaseAccountResponse.self,
            from: legacyData
        )
        guard let userID = legacyStatus.resolvedProfile?.userId else {
            Self.logger.error(
                "网易云登录态已失效：code=\(legacyStatus.code ?? -1)，message=\(legacyStatus.message ?? "nil", privacy: .public)"
            )
            throw MusicProviderClientError.accountUnavailable
        }
        return userID
    }

    private func fetchPlaylistDetails(
        _ playlists: [NeteasePlaylistsResponse.Playlist],
        cookie: String
    ) async -> [MusicProviderPlaylist] {
        guard !playlists.isEmpty else {
            return []
        }
        var results = Array<MusicProviderPlaylist?>(
            repeating: nil,
            count: playlists.count
        )
        await withTaskGroup(of: (Int, MusicProviderPlaylist).self) { group in
            var nextIndex = 0
            let initialCount = min(detailRequestConcurrency, playlists.count)
            for index in 0 ..< initialCount {
                group.addTask { [self] in
                    (
                        index,
                        await fetchPlaylistDetail(
                            playlists[index],
                            cookie: cookie
                        )
                    )
                }
                nextIndex += 1
            }
            while let (index, playlist) = await group.next() {
                results[index] = playlist
                guard nextIndex < playlists.count else {
                    continue
                }
                let pendingIndex = nextIndex
                group.addTask { [self] in
                    (
                        pendingIndex,
                        await fetchPlaylistDetail(
                            playlists[pendingIndex],
                            cookie: cookie
                        )
                    )
                }
                nextIndex += 1
            }
        }
        return results.enumerated().map { index, result in
            result ?? playlists[index].providerPlaylist(tracks: [])
        }
    }

    private func fetchPlaylistDetail(
        _ playlist: NeteasePlaylistsResponse.Playlist,
        cookie: String
    ) async -> MusicProviderPlaylist {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/v6/playlist/detail"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(playlist.id)),
            URLQueryItem(name: "n", value: "1000"),
            URLQueryItem(name: "s", value: "0"),
        ]
        guard
            let response = try? await transport.send(
                providerRequest(url: components.url!, cookie: cookie)
            ),
            let data = try? checkedProviderResponse(response),
            let detail = try? JSONDecoder().decode(
                NeteasePlaylistDetailResponse.self,
                from: data
            )
        else {
            return playlist.providerPlaylist(tracks: [])
        }
        let tracks = (detail.playlist?.tracks ?? []).map {
            $0.providerTrack(matchScore: 0.72, userAffinity: 1)
        }
        return playlist.providerPlaylist(tracks: tracks)
    }

    func playbackAsset(
        for trackID: String,
        session: MusicProviderSession
    ) async throws -> MusicPlaybackAsset {
        let cookie = try session.cookieHeader()
        for level in ["exhigh", "standard"] {
            do {
                let request = try NeteaseEAPIRequestEncoder.playbackRequest(
                    trackID: trackID,
                    level: level,
                    cookie: cookie
                )
                let response = try await playbackResponse(for: request)
                if let url = response.playableURL {
                    Self.logger.info(
                        "网易云 v1 播放地址成功：track=\(trackID, privacy: .public)，level=\(level, privacy: .public)，host=\(url.host ?? "nil", privacy: .public)"
                    )
                    return playbackAsset(url: url, cookie: cookie)
                }
                Self.logger.error(
                    "网易云 v1 没有播放地址：track=\(trackID, privacy: .public)，level=\(level, privacy: .public)，code=\(response.firstCode ?? -1)"
                )
            } catch {
                Self.logger.error(
                    "网易云 v1 请求失败：track=\(trackID, privacy: .public)，level=\(level, privacy: .public)，error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        for bitrate in [320_000, 128_000] {
            do {
                let request = legacyPlaybackRequest(
                    trackID: trackID,
                    bitrate: bitrate,
                    cookie: cookie
                )
                let response = try await playbackResponse(for: request)
                if let url = response.playableURL {
                    Self.logger.info(
                        "网易云旧接口播放地址成功：track=\(trackID, privacy: .public)，bitrate=\(bitrate)，host=\(url.host ?? "nil", privacy: .public)"
                    )
                    return playbackAsset(url: url, cookie: cookie)
                }
                Self.logger.error(
                    "网易云旧接口没有播放地址：track=\(trackID, privacy: .public)，bitrate=\(bitrate)，code=\(response.firstCode ?? -1)"
                )
            } catch {
                Self.logger.error(
                    "网易云旧接口请求失败：track=\(trackID, privacy: .public)，bitrate=\(bitrate)，error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        Self.logger.error(
            "网易云全部播放地址均不可用：track=\(trackID, privacy: .public)"
        )
        throw MusicProviderClientError.playbackAddressUnavailable
    }

    func lyrics(
        for trackID: String,
        session: MusicProviderSession
    ) async throws -> MusicLyrics {
        let cookie = try session.cookieHeader()
        var components = URLComponents(
            url: baseURL.appending(path: "/api/song/lyric"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: trackID),
            URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "kv", value: "-1"),
            URLQueryItem(name: "tv", value: "-1"),
            URLQueryItem(name: "yv", value: "-1"),
        ]
        let data = try checkedProviderResponse(
            await transport.send(
                providerRequest(url: components.url!, cookie: cookie)
            )
        )
        let response = try JSONDecoder().decode(
            NeteaseLyricsResponse.self,
            from: data
        )
        guard
            let original = response.lrc?.lyric,
            !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MusicProviderClientError.invalidResponse
        }
        let wordByWord = response.yrc?.lyric?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timedTranslation = response.ytlrc?.lyric?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lineTranslation = response.tlyric?.lyric?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MusicLyrics(
            original: original,
            translation: timedTranslation?.isEmpty == false
                ? timedTranslation
                : (lineTranslation?.isEmpty == false ? lineTranslation : nil),
            wordByWord: wordByWord?.isEmpty == false ? wordByWord : nil
        )
    }

    private func securePlaybackURL(_ url: URL) -> URL {
        url.gmgnHTTPSURL
    }

    private func playbackResponse(
        for request: URLRequest
    ) async throws -> NeteasePlaybackResponse {
        let data = try checkedProviderResponse(
            await transport.send(request)
        )
        return try JSONDecoder().decode(
            NeteasePlaybackResponse.self,
            from: data
        )
    }

    private func playbackAsset(
        url: URL,
        cookie: String
    ) -> MusicPlaybackAsset {
        MusicPlaybackAsset(
            url: securePlaybackURL(url),
            requestHeaders: [
                "Cookie": cookie,
                "Referer": "https://music.163.com/",
            ]
        )
    }

    private func backfillMissingArtwork(
        in tracks: [MusicProviderTrack],
        cookie: String
    ) async -> [MusicProviderTrack] {
        let missingIDs = tracks
            .filter { $0.artworkURL == nil }
            .map(\.id)
        guard !missingIDs.isEmpty else {
            return tracks
        }

        var components = URLComponents(
            url: baseURL.appending(path: "/api/song/detail/"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "ids",
                value: "[\(missingIDs.joined(separator: ","))]"
            ),
        ]
        guard
            let url = components.url,
            let response = try? await transport.send(
                providerRequest(url: url, cookie: cookie)
            ),
            let data = try? checkedProviderResponse(response),
            let detail = try? JSONDecoder().decode(
                NeteaseSongDetailResponse.self,
                from: data
            )
        else {
            Self.logger.warning(
                "网易云歌曲封面批量补全失败：count=\(missingIDs.count)"
            )
            return tracks
        }

        let artworkByTrackID: [String: URL] = Dictionary(
            uniqueKeysWithValues: detail.songs.compactMap { song
                -> (String, URL)? in
                guard let artworkURL = song.album?.picUrl ?? song.al?.picUrl else {
                    return nil
                }
                return (String(song.id), artworkURL.gmgnHTTPSURL)
            }
        )
        var hydrated = tracks
        for index in hydrated.indices where hydrated[index].artworkURL == nil {
            hydrated[index].artworkURL = artworkByTrackID[hydrated[index].id]
        }
        Self.logger.info(
            "网易云歌曲封面批量补全：requested=\(missingIDs.count)，resolved=\(artworkByTrackID.count)"
        )
        return hydrated
    }

    private func legacyPlaybackRequest(
        trackID: String,
        bitrate: Int,
        cookie: String
    ) -> URLRequest {
        var request = providerRequest(
            path: "/api/song/enhance/player/url",
            cookie: cookie
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = formData([
            URLQueryItem(name: "ids", value: "[\(trackID)]"),
            URLQueryItem(name: "br", value: String(bitrate)),
        ])
        return request
    }

    private func providerRequest(
        path: String,
        cookie: String
    ) -> URLRequest {
        providerRequest(url: baseURL.appending(path: path), cookie: cookie)
    }

    private func providerRequest(
        url: URL,
        cookie: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(
            "https://music.163.com/",
            forHTTPHeaderField: "Referer"
        )
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) gmgn-radio/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    private func searchTerm(for request: MusicSearchRequest) -> String {
        ([request.text].compactMap { $0 }
            + request.moodTags
            + request.genres)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func formData(_ items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

private struct NeteaseSearchResponse: Decodable {
    let result: Result?

    struct Result: Decodable {
        let songs: [NeteaseTrackDTO]?
    }
}

private struct NeteaseSongDetailResponse: Decodable {
    let songs: [NeteaseTrackDTO]
}

private struct NeteaseAccountResponse: Decodable {
    let code: Int?
    let message: String?
    let profile: Profile?
    let data: Payload?

    var resolvedProfile: Profile? {
        profile ?? data?.profile
    }

    struct Payload: Decodable {
        let profile: Profile?
    }

    struct Profile: Decodable {
        let userId: Int64
    }
}

private struct NeteasePlaylistsResponse: Decodable {
    let playlist: [Playlist]?

    struct Playlist: Decodable {
        let id: Int64
        let name: String?
        let coverImgUrl: URL?
        let trackCount: Int?

        func providerPlaylist(
            tracks: [MusicProviderTrack]
        ) -> MusicProviderPlaylist {
            let trimmedName = name?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
            return MusicProviderPlaylist(
                id: String(id),
                name: trimmedName.isEmpty ? "网易云歌单" : trimmedName,
                artworkURL: coverImgUrl?.gmgnHTTPSURL,
                trackCount: max(trackCount ?? 0, tracks.count),
                tracks: tracks
            )
        }
    }
}

private struct NeteasePlaylistDetailResponse: Decodable {
    let playlist: Playlist?

    struct Playlist: Decodable {
        let tracks: [NeteaseTrackDTO]?
        let trackIds: [TrackID]?
        let trackCount: Int?

        struct TrackID: Decodable {
            let id: Int64
        }
    }
}

private struct NeteasePlaybackResponse: Decodable {
    let data: [Item]?

    var playableURL: URL? {
        data?.first {
            $0.code == 200 && $0.url != nil
        }?.url
    }

    var firstCode: Int? {
        data?.first?.code
    }

    struct Item: Decodable {
        let url: URL?
        let code: Int
    }
}

private enum NeteaseWeAPIRequestEncoder {
    private static let presetKey = Data("0CoJUm6Qyw8W8jud".utf8)
    private static let secretKey = Data("gmgnRadio2026Key".utf8)
    private static let initializationVector = Data("0102030405060708".utf8)
    private static let publicKeyDERBase64 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB"

    static func accountStatusRequest(
        cookie: String,
        baseURL: URL
    ) throws -> URLRequest {
        let jsonData = Data("{}".utf8)
        let firstPass = try encryptCBC(
            jsonData,
            key: presetKey
        ).base64EncodedString()
        let params = try encryptCBC(
            Data(firstPass.utf8),
            key: secretKey
        ).base64EncodedString()
        let encSecKey = try encryptedSecretKey()
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "params", value: params),
            URLQueryItem(name: "encSecKey", value: encSecKey),
        ]

        var request = URLRequest(
            url: baseURL.appending(path: "/weapi/w/nuser/account/get")
        )
        request.timeoutInterval = 12
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(
            "https://music.163.com/",
            forHTTPHeaderField: "Referer"
        )
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) gmgn-radio/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = Data(
            (bodyComponents.percentEncodedQuery ?? "").utf8
        )
        return request
    }

    private static func encryptCBC(
        _ plaintext: Data,
        key: Data
    ) throws -> Data {
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var outputLength = 0
        let status = plaintext.withUnsafeBytes { inputBytes in
            key.withUnsafeBytes { keyBytes in
                initializationVector.withUnsafeBytes { ivBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            plaintext.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw MusicProviderClientError.invalidResponse
        }
        output.removeSubrange(outputLength ..< output.count)
        return output
    }

    private static func encryptedSecretKey() throws -> String {
        guard let der = Data(base64Encoded: publicKeyDERBase64) else {
            throw MusicProviderClientError.invalidResponse
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1_024,
        ]
        var creationError: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(
            der as CFData,
            attributes as CFDictionary,
            &creationError
        ) else {
            throw MusicProviderClientError.invalidResponse
        }
        let blockSize = SecKeyGetBlockSize(publicKey)
        let reversedSecret = Data(secretKey.reversed())
        guard reversedSecret.count <= blockSize else {
            throw MusicProviderClientError.invalidResponse
        }
        var paddedSecret = Data(
            repeating: 0,
            count: blockSize - reversedSecret.count
        )
        paddedSecret.append(reversedSecret)
        var encryptionError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionRaw,
            paddedSecret as CFData,
            &encryptionError
        ) as Data? else {
            throw MusicProviderClientError.invalidResponse
        }
        return encrypted.map { String(format: "%02x", $0) }.joined()
    }
}

private enum NeteaseEAPIRequestEncoder {
    private static let endpoint = "/api/song/enhance/player/url/v1"
    private static let encryptionKey = Data("e82ckenh8dichen8".utf8)
    private static let separator = "-36cd479b6b5-"

    static func playbackRequest(
        trackID: String,
        level: String,
        cookie: String,
        now: Date = Date()
    ) throws -> URLRequest {
        let header = requestHeader(cookie: cookie, now: now)
        let payload: [String: Any] = [
            "ids": "[\(trackID)]",
            "level": level,
            "encodeType": "flac",
            "e_r": false,
            "header": header,
        ]
        let jsonData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let json = String(data: jsonData, encoding: .utf8) else {
            throw MusicProviderClientError.invalidResponse
        }
        let digestSource = "nobody\(endpoint)use\(json)md5forencrypt"
        let digest = Insecure.MD5.hash(
            data: Data(digestSource.utf8)
        )
        .map { String(format: "%02x", $0) }
        .joined()
        let plaintext = [
            endpoint,
            json,
            digest,
        ].joined(separator: separator)
        let encrypted = try encrypt(Data(plaintext.utf8))
            .map { String(format: "%02X", $0) }
            .joined()

        guard let url = URL(
            string: "https://interface.music.163.com/eapi/song/enhance/player/url/v1"
        ) else {
            throw MusicProviderClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "NeteaseMusic/3.1.17.204416 (Macintosh; macOS) gmgn-radio/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            cookieHeader(header, originalCookie: cookie),
            forHTTPHeaderField: "Cookie"
        )
        request.setValue(
            "https://music.163.com/",
            forHTTPHeaderField: "Referer"
        )
        request.httpBody = Data("params=\(encrypted)".utf8)
        return request
    }

    private static func requestHeader(
        cookie: String,
        now: Date
    ) -> [String: String] {
        let sourceCookie = cookieValues(cookie)
        let milliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        let seconds = Int64(now.timeIntervalSince1970)
        var header: [String: String] = [
            "osver": "macOS",
            "os": "pc",
            "appver": "3.1.17.204416",
            "versioncode": "140",
            "buildver": String(seconds),
            "resolution": "1920x1080",
            "__csrf": sourceCookie["__csrf"] ?? "",
            "channel": "netease",
            "requestId": "\(milliseconds)_0001",
        ]
        for name in ["MUSIC_U", "MUSIC_A"] {
            if let value = sourceCookie[name], !value.isEmpty {
                header[name] = value
            }
        }
        return header
    }

    private static func cookieHeader(
        _ header: [String: String],
        originalCookie: String
    ) -> String {
        var values = cookieValues(originalCookie)
        header.forEach { values[$0.key] = $0.value }
        return values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func cookieValues(
        _ cookie: String
    ) -> [String: String] {
        cookie.split(separator: ";").reduce(into: [:]) { values, field in
            let pair = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard pair.count == 2 else {
                return
            }
            let name = pair[0].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let value = String(pair[1]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !name.isEmpty else {
                return
            }
            values[name] = value
        }
    }

    private static func encrypt(_ plaintext: Data) throws -> Data {
        var output = Data(
            count: plaintext.count + kCCBlockSizeAES128
        )
        let outputCapacity = output.count
        var outputLength = 0
        let status = plaintext.withUnsafeBytes { inputBytes in
            encryptionKey.withUnsafeBytes { keyBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(
                            kCCOptionPKCS7Padding | kCCOptionECBMode
                        ),
                        keyBytes.baseAddress,
                        encryptionKey.count,
                        nil,
                        inputBytes.baseAddress,
                        plaintext.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw MusicProviderClientError.invalidResponse
        }
        output.removeSubrange(outputLength ..< output.count)
        return output
    }
}

private struct NeteaseLyricsResponse: Decodable {
    let lrc: Payload?
    let tlyric: Payload?
    let yrc: Payload?
    let ytlrc: Payload?

    struct Payload: Decodable {
        let lyric: String?
    }
}

private struct NeteaseTrackDTO: Decodable {
    let id: Int64
    let name: String
    let duration: Double?
    let dt: Double?
    let status: Int?
    let artists: [Artist]?
    let ar: [Artist]?
    let album: Album?
    let al: Album?

    struct Artist: Decodable {
        let name: String
    }

    struct Album: Decodable {
        let name: String?
        let picUrl: URL?
    }

    func providerTrack(
        matchScore: Double,
        userAffinity: Double
    ) -> MusicProviderTrack {
        MusicProviderTrack(
            id: String(id),
            canonicalID: nil,
            title: name,
            artist: (artists ?? ar ?? []).map(\.name).joined(separator: " / "),
            album: album?.name ?? al?.name,
            duration: (duration ?? dt ?? 0) / 1_000,
            isPlayable: (status ?? 0) >= 0,
            matchScore: matchScore,
            userAffinity: userAffinity,
            energy: 0.5,
            moodTags: [],
            genres: [],
            releaseYear: nil,
            artworkURL: (album?.picUrl ?? al?.picUrl)?.gmgnHTTPSURL
        )
    }
}

private extension URL {
    var gmgnHTTPSURL: URL {
        guard
            scheme?.lowercased() == "http",
            var components = URLComponents(
                url: self,
                resolvingAgainstBaseURL: false
            )
        else {
            return self
        }
        components.scheme = "https"
        return components.url ?? self
    }
}
