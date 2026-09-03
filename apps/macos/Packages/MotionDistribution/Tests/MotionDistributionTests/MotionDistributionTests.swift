import CryptoKit
import Foundation
import Testing
@testable import MotionDistribution

@Suite
struct MotionDistributionTests {
    @Test
    func exposesTheBuiltInProductCatalogURL() {
        #expect(
            MotionServiceConfiguration.defaultCatalogURL.absoluteString
                == "https://192.168.1.85:8765/catalog.json"
        )
    }

    @Test
    func allowsThePinnedPrivateWorkerOverTheLAN() throws {
        try MotionRemoteURLPolicy.validate(
            MotionServiceConfiguration.defaultCatalogURL
        )
    }

    @Test
    func migratesTheOldLocalPreviewCatalogButKeepsCustomURLs() {
        #expect(
            MotionServiceConfiguration.resolvedCatalogURLString(
                persisted: "http://127.0.0.1:8765/catalog.json"
            ) == MotionServiceConfiguration.defaultCatalogURL.absoluteString
        )
        #expect(
            MotionServiceConfiguration.resolvedCatalogURLString(
                persisted: "http://pancat-linux-ci.tail4c7fb9.ts.net:8765/catalog.json"
            ) == MotionServiceConfiguration.defaultCatalogURL.absoluteString
        )
        #expect(
            MotionServiceConfiguration.resolvedCatalogURLString(
                persisted: "http://100.110.226.64:8765/catalog.json"
            ) == MotionServiceConfiguration.defaultCatalogURL.absoluteString
        )
        #expect(
            MotionServiceConfiguration.resolvedCatalogURLString(
                persisted: "https://100.110.226.64:8765/catalog.json"
            ) == MotionServiceConfiguration.defaultCatalogURL.absoluteString
        )
        #expect(
            MotionServiceConfiguration.resolvedCatalogURLString(
                persisted: "https://motions.example.com/catalog.json"
            ) == "https://motions.example.com/catalog.json"
        )
    }

    @Test
    func bypassesSystemProxyForThePinnedLANAddressOnly() {
        #expect(
            MotionRemoteURLPolicy.requiresDirectTransport(
                MotionServiceConfiguration.defaultCatalogURL
            )
        )
        #expect(
            !MotionRemoteURLPolicy.requiresDirectTransport(
                URL(string: "https://motions.example.com/catalog.json")!
            )
        )
    }

    @Test
    func pinsThePrivateMotionServiceCertificate() {
        #expect(MotionServiceConfiguration.pinnedCertificateSHA256.count == 64)
        #expect(
            MotionRemoteURLPolicy.requiresPinnedCertificate(
                MotionServiceConfiguration.defaultCatalogURL
            )
        )
        #expect(
            !MotionRemoteURLPolicy.requiresPinnedCertificate(
                URL(string: "https://motions.example.com/catalog.json")!
            )
        )
    }

    @Test
    func fetchesTheLivePinnedCatalogWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["GMGN_MOTION_LIVE_TEST"] == "1" else {
            return
        }
        let catalog = try await MotionCatalogClient().fetch(
            from: MotionServiceConfiguration.defaultCatalogURL
        )
        #expect(catalog.motions.contains {
            $0.id == "gmgn.motion.ardy-natural-jumping-jacks"
        })
    }

    @Test
    func fetchesAndValidatesAWorkerCatalog() async throws {
        let catalogURL = URL(string: "http://127.0.0.1:8765/catalog.json")!
        let vrma = makeVRMA()
        let catalog = makeCatalog(vrma: vrma)
        let transport = StubTransport([
            catalogURL: .init(statusCode: 200, finalURL: catalogURL, data: catalog),
        ])

        let result = try await MotionCatalogClient(transport: transport).fetch(from: catalogURL)

        #expect(result.schemaVersion == 1)
        #expect(result.motions.map(\.id) == ["gmgn.motion.kitchen-groove"])
        #expect(result.motions[0].activityIDs == ["cooking.stir", "music.dance"])
        #expect(result.motions[0].strideSpeed == 0.9)
        #expect(result.motions[0].playbackRate == 1.25)
        #expect(result.motions[0].inPlace == true)
        #expect(result.motions[0].source.generator.engine == "ardy")
    }

    @Test
    func downloadsVerifiesAndReusesAnImmutableArtifact() async throws {
        let catalogURL = URL(string: "https://motions.gmgn.ai/catalog.json")!
        let assetURL = URL(
            string: "https://motions.gmgn.ai/motions/gmgn.motion.kitchen-groove/1.0.0/gmgn.motion.kitchen-groove.vrma"
        )!
        let vrma = makeVRMA()
        let catalog = try JSONDecoder().decode(MotionCatalog.self, from: makeCatalog(vrma: vrma))
        let motion = try #require(catalog.motions.first)
        let transport = StubTransport([
            assetURL: .init(statusCode: 200, finalURL: assetURL, data: vrma),
        ])
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: "motion-distribution-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = MotionArtifactCache(rootURL: cacheRoot, transport: transport)

        let first = try await cache.download(motion, catalogURL: catalogURL)
        let second = try await cache.download(motion, catalogURL: catalogURL)

        #expect(first == second)
        #expect(try Data(contentsOf: first) == vrma)
        #expect(await transport.requestCount(for: assetURL) == 1)
    }

    @Test
    func rejectsPathEscapeHashMismatchAndInvalidVRMA() async throws {
        var invalidPath = try JSONDecoder().decode(MotionCatalog.self, from: makeCatalog(vrma: makeVRMA()))
        invalidPath.motions[0].path = "../secret.vrma"
        #expect(throws: MotionDistributionError.unsafeArtifactPath("../secret.vrma")) {
            try MotionCatalogValidator.validate(invalidPath)
        }

        let catalogURL = URL(string: "https://motions.gmgn.ai/catalog.json")!
        let valid = try JSONDecoder().decode(MotionCatalog.self, from: makeCatalog(vrma: makeVRMA()))
        let motion = try #require(valid.motions.first)
        let assetURL = URL(string: "https://motions.gmgn.ai/\(motion.path)")!
        var tampered = makeVRMA()
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        let transport = StubTransport([
            assetURL: .init(statusCode: 200, finalURL: assetURL, data: tampered),
        ])
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: "motion-distribution-broken-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        await #expect(throws: MotionDistributionError.hashMismatch) {
            try await MotionArtifactCache(rootURL: cacheRoot, transport: transport)
                .download(motion, catalogURL: catalogURL)
        }
    }
}

private actor StubTransport: MotionHTTPTransport {
    private let responses: [URL: MotionHTTPResponse]
    private var counts: [URL: Int] = [:]

    init(_ responses: [URL: MotionHTTPResponse]) {
        self.responses = responses
    }

    func get(_ url: URL) async throws -> MotionHTTPResponse {
        counts[url, default: 0] += 1
        guard let response = responses[url] else {
            throw URLError(.resourceUnavailable)
        }
        return response
    }

    func requestCount(for url: URL) -> Int {
        counts[url, default: 0]
    }
}

private func makeCatalog(vrma: Data) -> Data {
    let digest = SHA256.hash(data: vrma).map { String(format: "%02x", $0) }.joined()
    return Data(
        """
        {
          "schemaVersion": 1,
          "motions": [{
            "id": "gmgn.motion.kitchen-groove",
            "name": "Kitchen Groove",
            "version": "1.0.0",
            "format": "vrma",
            "path": "motions/gmgn.motion.kitchen-groove/1.0.0/gmgn.motion.kitchen-groove.vrma",
            "sha256": "\(digest)",
            "bytes": \(vrma.count),
            "duration": 2.0,
            "loop": true,
            "avatarFormats": ["vrm"],
            "activityIDs": ["cooking.stir", "music.dance"],
            "strideSpeed": 0.9,
            "playbackRate": 1.25,
            "inPlace": true,
            "source": {
              "prompt": "dance while stirring a pot",
              "seed": 17,
              "generator": {
                "engine": "ardy",
                "model": "ARDY-Core-RP-20FPS-Horizon40",
                "revision": "abe6c43"
              }
            }
          }]
        }
        """.utf8
    )
}

private func makeVRMA() -> Data {
    var json = Data(
        #"{"asset":{"version":"2.0"},"extensions":{"VRMC_vrm_animation":{"specVersion":"1.0"}}}"#.utf8
    )
    while !json.count.isMultiple(of: 4) { json.append(0x20) }
    var data = Data("glTF".utf8)
    data.appendUInt32(2)
    data.appendUInt32(UInt32(20 + json.count))
    data.appendUInt32(UInt32(json.count))
    data.appendUInt32(0x4E4F534A)
    data.append(json)
    return data
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
