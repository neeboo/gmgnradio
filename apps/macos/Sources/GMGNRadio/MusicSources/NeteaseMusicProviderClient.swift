import Foundation

struct NeteaseMusicProviderClient: AccountMusicProviderClient {
    private let transport: any MusicProviderHTTPTransport
    private let baseURL: URL

    init(
        transport: any MusicProviderHTTPTransport =
            URLSessionMusicProviderHTTPTransport(),
        baseURL: URL = URL(string: "https://music.163.com")!
    ) {
        self.transport = transport
        self.baseURL = baseURL
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
        return (response.result?.songs ?? []).map {
            $0.providerTrack(matchScore: 0.86, userAffinity: 0.45)
        }
    }

    func fetchUserLibrary(
        session: MusicProviderSession
    ) async throws -> MusicProviderLibrary {
        let cookie = try session.cookieHeader()
        let accountData = try checkedProviderResponse(
            await transport.send(
                providerRequest(path: "/api/nuser/account/get", cookie: cookie)
            )
        )
        let account = try JSONDecoder().decode(
            NeteaseAccountResponse.self,
            from: accountData
        )
        guard let userID = account.profile?.userId else {
            throw MusicProviderClientError.accountUnavailable
        }

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
        let playlists = playlistsResponse.playlist ?? []
        let playlistIDs = playlists.map(\.id)
        var seenTrackIDs = Set<String>()
        var savedTracks: [MusicProviderTrack] = []
        for playlistID in playlistIDs.prefix(50) {
            var detailComponents = URLComponents(
                url: baseURL.appending(path: "/api/v6/playlist/detail"),
                resolvingAgainstBaseURL: false
            )!
            detailComponents.queryItems = [
                URLQueryItem(name: "id", value: String(playlistID)),
                URLQueryItem(name: "n", value: "1000"),
                URLQueryItem(name: "s", value: "0"),
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
                    NeteasePlaylistDetailResponse.self,
                    from: detailData
                )
            else {
                continue
            }
            for track in detail.playlist?.tracks ?? [] {
                let mapped = track.providerTrack(
                    matchScore: 0.72,
                    userAffinity: 1
                )
                guard seenTrackIDs.insert(mapped.id).inserted else {
                    continue
                }
                savedTracks.append(mapped)
            }
        }

        return MusicProviderLibrary(
            savedTracks: savedTracks,
            playlistIDs: playlistIDs.map(String.init),
            recentlyPlayedTrackIDs: []
        )
    }

    func playbackAsset(
        for trackID: String,
        session: MusicProviderSession
    ) async throws -> MusicPlaybackAsset {
        let cookie = try session.cookieHeader()
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
            URLQueryItem(name: "br", value: "320000"),
        ])
        let data = try checkedProviderResponse(await transport.send(request))
        let response = try JSONDecoder().decode(
            NeteasePlaybackResponse.self,
            from: data
        )
        guard
            let item = response.data?.first,
            item.code == 200,
            let url = item.url
        else {
            throw MusicProviderClientError.playbackUnavailable
        }
        return MusicPlaybackAsset(
            url: securePlaybackURL(url),
            requestHeaders: [
                "Cookie": cookie,
                "Referer": "https://music.163.com/",
            ]
        )
    }

    private func securePlaybackURL(_ url: URL) -> URL {
        guard
            url.scheme?.lowercased() == "http",
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
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

private struct NeteaseAccountResponse: Decodable {
    let profile: Profile?

    struct Profile: Decodable {
        let userId: Int64
    }
}

private struct NeteasePlaylistsResponse: Decodable {
    let playlist: [Playlist]?

    struct Playlist: Decodable {
        let id: Int64
    }
}

private struct NeteasePlaylistDetailResponse: Decodable {
    let playlist: Playlist?

    struct Playlist: Decodable {
        let tracks: [NeteaseTrackDTO]?
    }
}

private struct NeteasePlaybackResponse: Decodable {
    let data: [Item]?

    struct Item: Decodable {
        let url: URL?
        let code: Int
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
            releaseYear: nil
        )
    }
}
