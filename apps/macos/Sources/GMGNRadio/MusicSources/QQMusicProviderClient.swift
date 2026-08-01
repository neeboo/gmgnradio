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
        let playlistIDs = (response.data?.disslist ?? []).map(\.id)
        var seenTrackIDs = Set<String>()
        var savedTracks: [MusicProviderTrack] = []
        for playlistID in playlistIDs.prefix(50) {
            var detailComponents = URLComponents(
                string: "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg"
            )!
            detailComponents.queryItems = [
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "json", value: "1"),
                URLQueryItem(name: "utf8", value: "1"),
                URLQueryItem(name: "onlysong", value: "0"),
                URLQueryItem(name: "disstid", value: playlistID),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "g_tk", value: "5381"),
                URLQueryItem(name: "loginUin", value: uin),
                URLQueryItem(name: "hostUin", value: "0"),
                URLQueryItem(name: "inCharset", value: "utf8"),
                URLQueryItem(name: "outCharset", value: "utf-8"),
                URLQueryItem(name: "notice", value: "0"),
                URLQueryItem(name: "platform", value: "yqq.json"),
                URLQueryItem(name: "needNewCode", value: "0"),
            ]
            guard
                let detailResponse = try? await transport.send(
                    providerRequest(
                        url: detailComponents.url!,
                        cookie: cookie
                    )
                ),
                let detailData = try? checkedProviderResponse(detailResponse),
                let detail = try? JSONDecoder().decode(
                    QQPlaylistDetailResponse.self,
                    from: detailData
                )
            else {
                continue
            }
            for track in detail.cdlist?.first?.songlist ?? [] {
                let mapped = track.providerTrack
                guard seenTrackIDs.insert(mapped.id).inserted else {
                    continue
                }
                savedTracks.append(mapped)
            }
        }
        return MusicProviderLibrary(
            savedTracks: savedTracks,
            playlistIDs: playlistIDs,
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
            ?? values["wxuin"]
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
            ?? values["wxskey"]
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
    let playlistMediaMid: String?

    struct Singer: Decodable {
        let name: String
    }

    struct Album: Decodable {
        let name: String?
        let mid: String?

        init(name: String?, mid: String? = nil) {
            self.name = name
            self.mid = mid
        }
    }

    struct FileInfo: Decodable {
        let mediaMid: String?
        let size128mp3: Int64?

        enum CodingKeys: String, CodingKey {
            case mediaMid = "media_mid"
            case size128mp3 = "size_128mp3"
        }
    }

    enum CodingKeys: String, CodingKey {
        case mid
        case songMid = "songmid"
        case name
        case songName = "songname"
        case interval
        case singer
        case album
        case albumName = "albumname"
        case file
        case playlistMediaMid = "strMediaMid"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = try container.decodeIfPresent(String.self, forKey: .mid)
            ?? container.decode(String.self, forKey: .songMid)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decode(String.self, forKey: .songName)
        interval = try container.decode(Double.self, forKey: .interval)
        singer = try container.decodeIfPresent(
            [Singer].self,
            forKey: .singer
        ) ?? []
        if let nestedAlbum = try container.decodeIfPresent(
            Album.self,
            forKey: .album
        ) {
            album = nestedAlbum
        } else if let flatAlbum = try container.decodeIfPresent(
            String.self,
            forKey: .albumName
        ) {
            album = Album(name: flatAlbum)
        } else {
            album = nil
        }
        file = try container.decodeIfPresent(FileInfo.self, forKey: .file)
        playlistMediaMid = try container.decodeIfPresent(
            String.self,
            forKey: .playlistMediaMid
        )
    }

    var providerTrack: MusicProviderTrack {
        let mediaMid = file?.mediaMid ?? playlistMediaMid ?? mid
        let isPlayable: Bool
        if let size = file?.size128mp3 {
            isPlayable = size > 0
        } else {
            isPlayable = playlistMediaMid?.isEmpty == false
        }
        return MusicProviderTrack(
            id: "\(mid)@\(mediaMid)",
            canonicalID: nil,
            title: name,
            artist: singer.map(\.name).joined(separator: " / "),
            album: album?.name,
            duration: interval,
            isPlayable: isPlayable,
            matchScore: 0.84,
            userAffinity: 0.45,
            energy: 0.5,
            moodTags: [],
            genres: [],
            releaseYear: nil,
            artworkURL: album?.mid.flatMap {
                URL(
                    string: "https://y.qq.com/music/photo_new/T002R500x500M000\($0).jpg"
                )
            }
        )
    }
}

private struct QQPlaylistDetailResponse: Decodable {
    let cdlist: [Playlist]?

    struct Playlist: Decodable {
        let songlist: [QQTrackDTO]?
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
