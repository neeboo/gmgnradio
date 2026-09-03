import Foundation
import MotionDistribution

struct RemoteMotionLibrary: Sendable {
    let catalogURL: URL
    let motionStore: MotionPackageStore
    private let catalogClient: MotionCatalogClient
    private let artifactCache: MotionArtifactCache

    init(
        catalogURL: URL,
        motionStore: MotionPackageStore,
        cacheRootURL: URL,
        transport: any MotionHTTPTransport = URLSessionMotionHTTPTransport()
    ) {
        self.catalogURL = catalogURL
        self.motionStore = motionStore
        catalogClient = MotionCatalogClient(transport: transport)
        artifactCache = MotionArtifactCache(
            rootURL: cacheRootURL,
            transport: transport
        )
    }

    func refresh() async throws -> [PublishedMotion] {
        try await catalogClient.fetch(from: catalogURL).motions
    }

    func install(_ motion: PublishedMotion) async throws -> StageMotionAsset {
        let cachedURL = try await artifactCache.download(
            motion,
            catalogURL: catalogURL
        )
        let format: StageMotionFormat
        switch motion.format {
        case "vrma": format = .vrma
        case "vmd": format = .vmd
        default: throw MotionDistributionError.unsupportedFormat(motion.format)
        }
        return try motionStore.installPublishedMotion(
            id: motion.id,
            name: motion.name,
            version: motion.version,
            format: format,
            sourceURL: cachedURL,
            expectedSHA256: motion.sha256,
            loop: motion.loop,
            strideSpeed: motion.strideSpeed,
            playbackRate: motion.playbackRate ?? 1,
            inPlace: motion.inPlace
        )
    }

    static func liveCacheRoot(
        fileManager: FileManager = .default
    ) throws -> URL {
        let support = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appending(path: ProductIdentity.bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "PublishedMotions", directoryHint: .isDirectory)
    }
}
