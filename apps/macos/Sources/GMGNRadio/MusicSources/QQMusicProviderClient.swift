import Foundation

struct QQMusicProviderClient: AccountMusicProviderClient {
    private let transport: any MusicProviderHTTPTransport

    init(
        transport: any MusicProviderHTTPTransport =
            URLSessionMusicProviderHTTPTransport()
    ) {
        self.transport = transport
    }

    func capabilities(
        session: MusicProviderSession
    ) async throws -> MusicAccountCapabilities {
        let cookie = try session.cookieHeader()
        return MusicAccountCapabilities(
            canSearchCatalog: true,
            canReadLibrary: qqUIN(from: cookie) != nil,
            canReadPlaylists: qqUIN(from: cookie) != nil,
            canReadRecentPlays: false,
            canPlay: qqMusicKey(from: cookie) != nil
        )
    }

    func search(
        _ request: MusicSearchRequest,
        session: MusicProviderSession
    ) async throws -> [MusicProviderTrack] {
        let term = ([request.text].compactMap { $0 }
            + request.moodTags
            + request.genres)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !term.isEmpty else {
            return []
        }

        var components = URLComponents(
            string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
        )!
        components.queryItems = [
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: String(max(1, min(request.limit, 30)))),
            URLQueryItem(name: "w", value: term),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "new_json", value: "1"),
            URLQueryItem(name: "cr", value: "1"),
            URLQueryItem(name: "g_tk", value: "5381"),
            URLQueryItem(name: "loginUin", value: qqUIN(
                from: try session.cookieHeader()
            ) ?? "0"),
            URLQueryItem(name: "hostUin", value: "0"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq.json"),
            URLQueryItem(name: "needNewCode", value: "0"),
        ]
        let response = try checkedProviderResponse(
            await transport.send(
                providerRequest(
                    url: components.url!,
                    cookie: try session.cookieHeader()
                )
            )
        )
        let decoded = try JSONDecoder().decode(
            QQSearchResponse.self,
            from: response
        )
        return (decoded.data?.song?.list ?? []).map {
            $0.providerTrack
        }
    }

    func fetchUserLibrary(
        session: MusicProviderSession
    ) async throws -> MusicProviderLibrary {
        let cookie = try session.cookieHeader()
        guard let uin = qqUIN(from: cookie) else {
            throw MusicProviderClientError.invalidCredential
        }
        var components = URLComponents(
            string: "https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss"
        )!
        components.queryItems = [
            URLQueryItem(name: "hostuin", value: uin),
            URLQueryItem(name: "sin", value: "0"),
            URLQueryItem(name: "size", value: "50"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "g_tk", value: "5381"),
            URLQueryItem(name: "loginUin", value: uin),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq.json"),
            URLQueryItem(name: "needNewCode", value: "0"),
        ]
        let data = try checkedProviderResponse(
            await transport.send(
                providerRequest(url: components.url!, cookie: cookie)
            )
        )
        let response = try JSONDecoder().decode(
            QQPlaylistsResponse.self,
            from: data
        )
        return MusicProviderLibrary(
            savedTracks: [],
            playlistIDs: (response.data?.disslist ?? []).map(\.id),
            recentlyPlayedTrackIDs: []
        )
    }

    func playbackAsset(
        for trackID: String,
        session: MusicProviderSession
    ) async throws -> MusicPlaybackAsset {
        let parts = trackID.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw MusicProviderClientError.invalidResponse
        }
        let cookie = try session.cookieHeader()
        guard
            let uin = qqUIN(from: cookie),
            let musicKey = qqMusicKey(from: cookie)
        else {
            throw MusicProviderClientError.invalidCredential
        }
        let songMid = parts[0]
        let mediaMid = parts[1]
        let filenames = [
            "M800\(mediaMid).mp3",
            "M500\(mediaMid).mp3",
            "C400\(mediaMid).m4a",
        ]
        let payload: [String: Any] = [
            "comm": [
                "uin": uin,
                "format": "json",
                "ct": 19,
                "cv": 0,
                "authst": musicKey,
            ],
            "req_0": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "guid": "10000000",
                    "songmid": Array(repeating: songMid, count: filenames.count),
                    "songtype": Array(repeating: 0, count: filenames.count),
                    "uin": uin,
                    "loginflag": 1,
                    "platform": "20",
                    "filename": filenames,
                ],
            ],
        ]
        var request = providerRequest(
            url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!,
            cookie: cookie
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try checkedProviderResponse(await transport.send(request))
        let response = try JSONDecoder().decode(
            QQPlaybackResponse.self,
            from: data
        )
        guard
            let playback = response.req_0?.data,
            let item = playback.midurlinfo.first(where: { !$0.purl.isEmpty }),
            let base = playback.sip.first,
            let url = URL(string: base + item.purl)
        else {
            throw MusicProviderClientError.playbackUnavailable
        }
        return MusicPlaybackAsset(
            url: url,
            requestHeaders: [
                "Cookie": cookie,
                "Referer": "https://y.qq.com/",
            ]
        )
    }

    private func providerRequest(
        url: URL,
        cookie: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) gmgn-radio/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    private func cookieValues(from cookie: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: cookie.split(separator: ";").compactMap {
                let parts = $0.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else {
                    return nil
                }
                return (
                    parts[0].trimmingCharacters(in: .whitespaces),
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
                )
            }
        )
    }

    private func qqUIN(from cookie: String) -> String? {
        let values = cookieValues(from: cookie)
        guard var value = values["uin"]
            ?? values["qqmusic_uin"]
            ?? values["p_uin"]
        else {
            return nil
        }
        while value.first == "o" {
            value.removeFirst()
        }
        return value.isEmpty ? nil : value
    }

    private func qqMusicKey(from cookie: String) -> String? {
        let values = cookieValues(from: cookie)
        return values["qm_keyst"]
            ?? values["qqmusic_key"]
            ?? values["music_key"]
    }
}

private struct QQSearchResponse: Decodable {
    let data: DataBlock?

    struct DataBlock: Decodable {
        let song: SongBlock?
    }

    struct SongBlock: Decodable {
        let list: [QQTrackDTO]?
    }
}

private struct QQTrackDTO: Decodable {
    let mid: String
    let name: String
    let interval: Double
    let singer: [Singer]
    let album: Album?
    let file: FileInfo?

    struct Singer: Decodable {
        let name: String
    }

    struct Album: Decodable {
        let name: String?
    }

    struct FileInfo: Decodable {
        let mediaMid: String?
        let size128mp3: Int64?

        enum CodingKeys: String, CodingKey {
            case mediaMid = "media_mid"
            case size128mp3 = "size_128mp3"
        }
    }

    var providerTrack: MusicProviderTrack {
        let mediaMid = file?.mediaMid ?? mid
        return MusicProviderTrack(
            id: "\(mid)@\(mediaMid)",
            canonicalID: nil,
            title: name,
            artist: singer.map(\.name).joined(separator: " / "),
            album: album?.name,
            duration: interval,
            isPlayable: (file?.size128mp3 ?? 0) > 0,
            matchScore: 0.84,
            userAffinity: 0.45,
            energy: 0.5,
            moodTags: [],
            genres: [],
            releaseYear: nil
        )
    }
}

private struct QQPlaylistsResponse: Decodable {
    let data: DataBlock?

    struct DataBlock: Decodable {
        let disslist: [Playlist]?
    }

    struct Playlist: Decodable {
        let id: String

        enum CodingKeys: String, CodingKey {
            case tid
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? container.decode(String.self, forKey: .tid) {
                id = value
            } else {
                id = String(try container.decode(Int64.self, forKey: .tid))
            }
        }
    }
}

private struct QQPlaybackResponse: Decodable {
    let req_0: RequestBlock?

    struct RequestBlock: Decodable {
        let data: PlaybackData?
    }

    struct PlaybackData: Decodable {
        let sip: [String]
        let midurlinfo: [URLInfo]
    }

    struct URLInfo: Decodable {
        let purl: String
    }
}
