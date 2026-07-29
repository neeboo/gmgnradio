import Foundation
import Testing
@testable import GMGNRadio

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
                  "album": {"name": "乐与怒"}
                }]
              }
            }
            """
        ),
    ])
    let client = NeteaseMusicProviderClient(transport: transport)
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

    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/api/search/get/web")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Cookie") == "MUSIC_U=user-session")
    #expect(String(data: try #require(request.httpBody), encoding: .utf8)?
        .contains("%E6%B5%B7%E9%98%94%E5%A4%A9%E7%A9%BA") == true)
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
                {"id": 9001, "name": "我喜欢的音乐"},
                {"id": 9002, "name": "深夜"}
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
    let client = NeteaseMusicProviderClient(transport: transport)

    let library = try await client.fetchUserLibrary(
        session: providerSession("MUSIC_U=user-session")
    )

    #expect(library.playlistIDs == ["9001", "9002"])
    #expect(library.savedTracks.map(\.id) == ["1001", "1002"])

    let detailRequests = await transport.requests.filter {
        $0.url?.path == "/api/v6/playlist/detail"
    }
    #expect(detailRequests.count == 2)
    #expect(detailRequests[0].url?.query?.contains("id=9001") == true)
    #expect(detailRequests[1].url?.query?.contains("id=9002") == true)
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
    let client = NeteaseMusicProviderClient(transport: transport)

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
    let client = NeteaseMusicProviderClient(transport: transport)

    let asset = try await client.playbackAsset(
        for: "347230",
        session: providerSession("MUSIC_U=user-session")
    )

    #expect(asset.url.absoluteString == "https://m801.music.126.net/example.mp3")
    #expect(asset.requestHeaders["Referer"] == "https://music.163.com/")
}
