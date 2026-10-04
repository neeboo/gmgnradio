import Foundation
import Testing
@testable import GMGNRadio

@Test
func neteaseLoginValidationDoesNotRequestPlaylistsOrTracks() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse("{\"code\":200,\"profile\":{\"userId\":12345}}")
    ])
    let client = NeteaseMusicProviderClient(transport: transport)
    try await client.validateAccount(session: providerSession("MUSIC_U=test-only"))
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests.first?.url?.path == "/weapi/w/nuser/account/get")
}

@Test
func neteaseClientSearchesWithTheUsersCookieAndMapsTracks() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse(
            """
            {
              "code": 200,
              "result": {
                "songs": [{
                  "id": 347230,
                  "name": "海阔天空",
                  "duration": 326000,
                  "status": 0,
                  "fee": 8,
                  "artists": [{"name": "Beyond"}],
                  "album": {
                    "name": "乐与怒",
                    "picUrl": "https://p1.music.126.net/album.jpg"
                  }
                }]
              }
            }
            """
        ),
    ])
    let client = NeteaseMusicProviderClient(
        transport: transport,
        detailRequestConcurrency: 1
    )
    let tracks = try await client.search(
        MusicSearchRequest(text: "海阔天空", limit: 5),
        session: providerSession("MUSIC_U=user-session")
    )

    #expect(tracks.count == 1)
    #expect(tracks[0].id == "347230")
    #expect(tracks[0].title == "海阔天空")
    #expect(tracks[0].artist == "Beyond")
    #expect(tracks[0].album == "乐与怒")
    #expect(tracks[0].duration == 326)
    #expect(
        tracks[0].artworkURL?.absoluteString
            == "https://p1.music.126.net/album.jpg"
    )

    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/api/search/get/web")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Cookie") == "MUSIC_U=user-session")
    #expect(String(data: try #require(request.httpBody), encoding: .utf8)?
        .contains("%E6%B5%B7%E9%98%94%E5%A4%A9%E7%A9%BA") == true)
}

@Test
func neteaseClientBackfillsMissingSearchArtworkBySongID() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse(
            """
            {
              "code": 200,
              "result": {
                "songs": [{
                  "id": 659423,
                  "name": "プラスティック・ラヴ",
                  "duration": 291000,
                  "status": 0,
                  "artists": [{"name": "竹内まりや"}],
                  "album": {"name": "VARIETY"}
                }]
              }
            }
            """
        ),
        providerResponse(
            """
            {
              "songs": [{
                "id": 659423,
                "name": "プラスティック・ラヴ",
                "duration": 291000,
                "status": 0,
                "artists": [{"name": "竹内まりや"}],
                "album": {
                  "name": "VARIETY",
                  "picUrl": "https://p2.music.126.net/plastic-love.jpg"
                }
              }]
            }
            """
        ),
    ])
    let client = NeteaseMusicProviderClient(
        transport: transport,
        detailRequestConcurrency: 1
    )

    let tracks = try await client.search(
        MusicSearchRequest(text: "Plastic Love", limit: 5),
        session: providerSession("MUSIC_U=user-session")
    )

    #expect(
        tracks.first?.artworkURL?.absoluteString
            == "https://p2.music.126.net/plastic-love.jpg"
    )
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[1].url?.path == "/api/song/detail")
    #expect(requests[1].url?.query?.contains("659423") == true)
}

@Test
func neteaseClientAggregatesAndDeduplicatesTracksAcrossPlaylists() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse(
            """
            {"code":200,"profile":{"userId":42}}
            """
        ),
        providerResponse(
            """
            {
              "code": 200,
              "playlist": [
                {
                  "id": 9001,
                  "name": "我喜欢的音乐",
                  "coverImgUrl": "https://p1.music.126.net/liked.jpg",
                  "trackCount": 1
                },
                {
                  "id": 9002,
                  "name": "深夜",
                  "coverImgUrl": "https://p1.music.126.net/night.jpg",
                  "trackCount": 2
                }
              ]
            }
            """
        ),
        providerResponse(
            """
            {
              "code": 200,
              "playlist": {
                "tracks": [{
                  "id": 1001,
                  "name": "夜航",
                  "dt": 201000,
                  "fee": 0,
                  "ar": [{"name": "Example"}],
                  "al": {"name": "Night"}
                }]
              }
            }
            """
        ),
        providerResponse(
            """
            {
              "code": 200,
              "playlist": {
                "tracks": [
                  {
                    "id": 1001,
                    "name": "夜航",
                    "dt": 201000,
                    "fee": 0,
                    "ar": [{"name": "Example"}],
                    "al": {"name": "Night"}
                  },
                  {
                    "id": 1002,
                    "name": "蓝色时刻",
                    "dt": 245000,
                    "fee": 0,
                    "ar": [{"name": "Another"}],
                    "al": {"name": "Blue"}
                  }
                ]
              }
            }
            """
        ),
    ])
    let client = NeteaseMusicProviderClient(
        transport: transport,
        detailRequestConcurrency: 1
    )

    let library = try await client.fetchUserLibrary(
        session: providerSession("MUSIC_U=user-session")
    )

    #expect(library.playlistIDs == ["9001", "9002"])
    #expect(library.savedTracks.map(\.id) == ["1001", "1002"])
    #expect(library.playlists.map(\.name) == ["我喜欢的音乐", "深夜"])
    #expect(
        library.playlists[0].artworkURL?.absoluteString
            == "https://p1.music.126.net/liked.jpg"
    )
    #expect(library.playlists[1].trackCount == 2)
    #expect(library.playlists[0].tracks.map(\.id) == ["1001"])
    #expect(library.playlists[1].tracks.map(\.id) == ["1001", "1002"])

    let loginRequest = try #require(await transport.requests.first)
    #expect(loginRequest.url?.path == "/weapi/w/nuser/account/get")
    #expect(loginRequest.httpMethod == "POST")
    #expect(loginRequest.value(forHTTPHeaderField: "Cookie")?
        .contains("MUSIC_U=user-session") == true)
    let loginBody = String(
        data: try #require(loginRequest.httpBody),
        encoding: .utf8
    )
    #expect(loginBody?.contains("params=") == true)
    #expect(loginBody?.contains("encSecKey=") == true)

    let detailRequests = await transport.requests.filter {
        $0.url?.path == "/api/v6/playlist/detail"
    }
    #expect(detailRequests.count == 2)
    #expect(detailRequests[0].url?.query?.contains("id=9001") == true)
    #expect(detailRequests[1].url?.query?.contains("id=9002") == true)
}

@Test
func neteaseClientFallsBackWhenTheNewLoginStatusHasNoProfile() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse("""
            {"code":200,"profile":null}
            """),
        providerResponse("""
            {"code":200,"profile":{"userId":42}}
            """),
        providerResponse("""
            {"code":200,"playlist":[]}
            """),
    ])
    let client = NeteaseMusicProviderClient(
        transport: transport,
        detailRequestConcurrency: 1
    )

    let library = try await client.fetchUserLibrary(
        session: providerSession("MUSIC_U=user-session")
    )

    #expect(library.playlists.isEmpty)
    let requests = await transport.requests
    #expect(requests.map(\.url?.path) == [
        "/weapi/w/nuser/account/get",
        "/api/nuser/account/get",
        "/api/user/playlist",
    ])
}

@Test
func neteaseClientKeepsAvailablePlaylistsWhenOneDetailRequestFails() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse("{\"code\":200,\"profile\":{\"userId\":42}}"),
        providerResponse(
            """
            {
              "code": 200,
              "playlist": [
                {"id": 9001, "name": "暂时失效"},
                {"id": 9002, "name": "仍然可用"}
              ]
            }
            """
        ),
        providerResponse("service unavailable", statusCode: 503),
        providerResponse(
            """
            {
              "code": 200,
              "playlist": {
                "tracks": [{
                  "id": 1002,
                  "name": "蓝色时刻",
                  "dt": 245000,
                  "fee": 0,
                  "ar": [{"name": "Another"}],
                  "al": {"name": "Blue"}
                }]
              }
            }
            """
        ),
    ])
    let client = NeteaseMusicProviderClient(
        transport: transport,
        detailRequestConcurrency: 1
    )

    let library = try await client.fetchUserLibrary(
        session: providerSession("MUSIC_U=user-session")
    )

    #expect(library.playlistIDs == ["9001", "9002"])
    #expect(library.savedTracks.map(\.id) == ["1002"])
}

@Test
func neteaseClientResolvesAPlayableURLForTheUsersAccount() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse(
            """
            {
              "code": 200,
              "data": [{
                "id": 347230,
                "url": "http://m801.music.126.net/example.mp3",
                "code": 200
              }]
            }
            """
        ),
    ])
    let client = NeteaseMusicProviderClient(
        transport: transport,
        detailRequestConcurrency: 1
    )

    let asset = try await client.playbackAsset(
        for: "347230",
        session: providerSession("MUSIC_U=user-session")
    )

    #expect(asset.url.absoluteString == "https://m801.music.126.net/example.mp3")
    #expect(asset.requestHeaders["Referer"] == "https://music.163.com/")
    let request = try #require(await transport.requests.first)
    #expect(request.url?.host == "interface.music.163.com")
    #expect(request.url?.path == "/eapi/song/enhance/player/url/v1")
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody?.isEmpty == false)
}

@Test
func neteaseClientFallsBackToStandardQualityWhenExhighIsUnavailable() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse(
            """
            {
              "code": 200,
              "data": [{
                "id": 347230,
                "url": null,
                "code": 404
              }]
            }
            """
        ),
        providerResponse(
            """
            {
              "code": 200,
              "data": [{
                "id": 347230,
                "url": "https://m801.music.126.net/standard.mp3",
                "code": 200
              }]
            }
            """
        ),
    ])
    let client = NeteaseMusicProviderClient(
        transport: transport,
        detailRequestConcurrency: 1
    )

    let asset = try await client.playbackAsset(
        for: "347230",
        session: providerSession("MUSIC_U=user-session")
    )

    #expect(
        asset.url.absoluteString
            == "https://m801.music.126.net/standard.mp3"
    )
    #expect(asset.requestHeaders["Cookie"] == "MUSIC_U=user-session")
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(
        requests.allSatisfy {
            $0.url?.path == "/eapi/song/enhance/player/url/v1"
        }
    )
}

@Test
func neteaseClientDoesNotReturnTheHTMLMediaRedirectAsAudio() async throws {
    let unavailable = providerResponse(
        """
        {
          "code": 200,
          "data": [{
            "id": 347230,
            "url": null,
            "code": 404
          }]
        }
        """
    )
    let transport = ProviderHTTPTransportStub(responses: [
        unavailable,
        unavailable,
        unavailable,
        unavailable,
    ])
    let client = NeteaseMusicProviderClient(
        transport: transport,
        detailRequestConcurrency: 1
    )

    await #expect(
        throws: MusicProviderClientError.playbackAddressUnavailable
    ) {
        try await client.playbackAsset(
            for: "347230",
            session: providerSession("MUSIC_U=user-session")
        )
    }

    let requests = await transport.requests
    #expect(requests.count == 4)
    #expect(
        !requests.contains {
            $0.url?.path == "/song/media/outer/url"
        }
    )
}

@Test
func neteaseClientFetchesOriginalAndTranslatedLyrics() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse(
            """
            {
              "code": 200,
              "lrc": {"lyric": "[00:08.20]第一句\\n[00:12.50]第二句"},
              "tlyric": {"lyric": "[00:08.20]First line\\n[00:12.50]Second line"}
            }
            """
        ),
    ])
    let client = NeteaseMusicProviderClient(
        transport: transport,
        detailRequestConcurrency: 1
    )

    let lyrics = try await client.lyrics(
        for: "347230",
        session: providerSession("MUSIC_U=user-session")
    )

    #expect(lyrics.original.contains("[00:08.20]第一句"))
    #expect(lyrics.translation?.contains("First line") == true)
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/api/song/lyric")
    #expect(request.url?.query?.contains("id=347230") == true)
    #expect(request.value(forHTTPHeaderField: "Cookie") == "MUSIC_U=user-session")
}

@Test
func neteaseClientPrefersYRCWordTimingAndMatchingTranslation() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse(
            """
            {
              "code": 200,
              "lrc": {"lyric": "[00:08.20]今晚慢一点"},
              "tlyric": {"lyric": "[00:08.20]Tonight"},
              "yrc": {
                "lyric": "[8200,4000](8200,800,0)今(9000,700,0)晚(9700,900,0)慢(10600,700,0)一(11300,900,0)点"
              },
              "ytlrc": {"lyric": "[00:08.20]Slow down tonight"}
            }
            """
        ),
    ])
    let client = NeteaseMusicProviderClient(
        transport: transport,
        detailRequestConcurrency: 1
    )

    let lyrics = try await client.lyrics(
        for: "347230",
        session: providerSession("MUSIC_U=user-session")
    )

    #expect(lyrics.original == "[00:08.20]今晚慢一点")
    #expect(lyrics.wordByWord?.contains("[8200,4000]") == true)
    #expect(lyrics.translation == "[00:08.20]Slow down tonight")
    let request = try #require(await transport.requests.first)
    #expect(request.url?.query?.contains("yv=-1") == true)
}
