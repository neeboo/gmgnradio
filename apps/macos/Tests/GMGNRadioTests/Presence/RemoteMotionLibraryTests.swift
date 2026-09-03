import CryptoKit
import Foundation
import MotionDistribution
import Testing
@testable import GMGNRadio

@Suite
struct RemoteMotionLibraryTests {
    @Test
    func fetchesDownloadsAndInstallsPublishedMotionIntoTheExistingMenuStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "remote-motion-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = URL(string: "http://127.0.0.1:8765/catalog.json")!
        let artifactURL = URL(
            string: "http://127.0.0.1:8765/motions/gmgn.motion.kitchen-groove/1.0.0/gmgn.motion.kitchen-groove.vrma"
        )!
        let vrma = makeRemoteVRMA()
        let catalog = makeRemoteCatalog(vrma: vrma)
        let transport = RemoteMotionStubTransport([
            catalogURL: .init(statusCode: 200, finalURL: catalogURL, data: catalog),
            artifactURL: .init(statusCode: 200, finalURL: artifactURL, data: vrma),
        ])
        let store = MotionPackageStore(
            rootURL: root.appending(path: "installed", directoryHint: .isDirectory),
            bundledStudioGrooveURL: nil
        )
        let library = RemoteMotionLibrary(
            catalogURL: catalogURL,
            motionStore: store,
            cacheRootURL: root.appending(path: "cache", directoryHint: .isDirectory),
            transport: transport
        )

        let published = try await library.refresh()
        let installed = try await library.install(try #require(published.first))

        #expect(installed.id == "gmgn.motion.kitchen-groove")
        #expect(installed.format == .vrma)
        #expect(try store.listMotions().contains { $0.id == installed.id })
    }
}

private actor RemoteMotionStubTransport: MotionHTTPTransport {
    let responses: [URL: MotionHTTPResponse]

    init(_ responses: [URL: MotionHTTPResponse]) {
        self.responses = responses
    }

    func get(_ url: URL) async throws -> MotionHTTPResponse {
        guard let response = responses[url] else {
            throw URLError(.resourceUnavailable)
        }
        return response
    }
}

private func makeRemoteCatalog(vrma: Data) -> Data {
    let digest = SHA256.hash(data: vrma).map { String(format: "%02x", $0) }.joined()
    return Data(
        """
        {"schemaVersion":1,"motions":[{
          "id":"gmgn.motion.kitchen-groove",
          "name":"Kitchen Groove",
          "version":"1.0.0",
          "format":"vrma",
          "path":"motions/gmgn.motion.kitchen-groove/1.0.0/gmgn.motion.kitchen-groove.vrma",
          "sha256":"\(digest)",
          "bytes":\(vrma.count),
          "duration":2.0,
          "loop":true,
          "avatarFormats":["vrm"],
          "activityIDs":["music.dance"],
          "source":{"prompt":"dance","seed":17,"generator":{"engine":"ardy","model":"core","revision":"test"}}
        }]}
        """.utf8
    )
}

private func makeRemoteVRMA() -> Data {
    var json = Data(
        #"{"asset":{"version":"2.0"},"extensions":{"VRMC_vrm_animation":{"specVersion":"1.0"}}}"#.utf8
    )
    while !json.count.isMultiple(of: 4) { json.append(0x20) }
    var data = Data("glTF".utf8)
    data.appendRemoteUInt32(2)
    data.appendRemoteUInt32(UInt32(20 + json.count))
    data.appendRemoteUInt32(UInt32(json.count))
    data.appendRemoteUInt32(0x4E4F534A)
    data.append(json)
    return data
}

private extension Data {
    mutating func appendRemoteUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
