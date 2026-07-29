import Foundation
import Testing
@testable import GMGNRadio

@Test
func qqMusicClientSearchesTheCatalogAndKeepsTheMediaIdentifier() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse(
            """
            {
              "code": 0,
              "data": {
                "song": {
                  "list": [{
                    "mid": "song-mid",
                    "name": "晴天",
                    "interval": 269,
                    "singer": [{"name": "周杰伦"}],
                    "album": {"name": "叶惠美"},
                    "file": {"media_mid": "media-mid", "size_128mp3": 4317292}
                  }]
                }
              }
            }
            """
        ),
    ])
    let client = QQMusicProviderClient(transport: transport)
    let tracks = try await client.search(
        MusicSearchRequest(text: "晴天", limit: 3),
        session: providerSession("uin=o12345; qm_keyst=user-key")
    )

    #expect(tracks.count == 1)
    #expect(tracks[0].id == "song-mid@media-mid")
    #expect(tracks[0].title == "晴天")
    #expect(tracks[0].artist == "周杰伦")
    #expect(tracks[0].duration == 269)

    let request = try #require(await transport.requests.first)
    #expect(request.url?.host == "c.y.qq.com")
    #expect(request.url?.path == "/soso/fcgi-bin/client_search_cp")
    #expect(request.url?.query?.contains("w=%E6%99%B4%E5%A4%A9") == true)
    #expect(request.value(forHTTPHeaderField: "Cookie")
        == "uin=o12345; qm_keyst=user-key")
}

@Test
func qqMusicClientReadsTheUsersPlaylists() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse(
            """
            {
              "code": 0,
              "data": {
                "disslist": [
                  {"tid": 7001, "diss_name": "我喜欢"},
                  {"tid": 7002, "diss_name": "通勤"}
                ]
              }
            }
            """
        ),
    ])
    let client = QQMusicProviderClient(transport: transport)

    let library = try await client.fetchUserLibrary(
        session: providerSession("uin=o12345; qm_keyst=user-key")
    )

    #expect(library.playlistIDs == ["7001", "7002"])
    let request = try #require(await transport.requests.first)
    #expect(request.url?.query?.contains("hostuin=12345") == true)
}

@Test
func qqMusicClientResolvesVKeyPlaybackUsingTheUsersSession() async throws {
    let transport = ProviderHTTPTransportStub(responses: [
        providerResponse(
            """
            {
              "code": 0,
              "req_0": {
                "code": 0,
                "data": {
                  "sip": ["https://ws.stream.qqmusic.qq.com/"],
                  "midurlinfo": [{
                    "filename": "M800media-mid.mp3",
                    "purl": "C400example.m4a?vkey=token"
                  }]
                }
              }
            }
            """
        ),
    ])
    let client = QQMusicProviderClient(transport: transport)

    let asset = try await client.playbackAsset(
        for: "song-mid@media-mid",
        session: providerSession("uin=o12345; qm_keyst=user-key")
    )

    #expect(asset.url.absoluteString
        == "https://ws.stream.qqmusic.qq.com/C400example.m4a?vkey=token")
    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Cookie")
        == "uin=o12345; qm_keyst=user-key")
    let body = try #require(request.httpBody)
    let json = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    let comm = try #require(json["comm"] as? [String: Any])
    #expect(comm["uin"] as? String == "12345")
    #expect(comm["authst"] as? String == "user-key")
}
