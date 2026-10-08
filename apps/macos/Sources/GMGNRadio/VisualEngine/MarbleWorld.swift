import Foundation
import WorldRuntime

enum MarbleSplatQuality: String, Codable, CaseIterable, Sendable {
    case oneHundredK = "100k"
    case oneHundredFiftyK = "150k"
    case fiveHundredK = "500k"
    case fullResolution = "full_res"

}

struct MarbleSplatAsset: Equatable, Sendable {
    let quality: MarbleSplatQuality
    let url: URL
}

struct MarbleWorldSemantics: Equatable, Sendable {
    var metricScale: Double
    var groundPlaneOffset: Double

    static let identity = MarbleWorldSemantics(
        metricScale: 1,
        groundPlaneOffset: 0
    )
}

enum MarbleColliderSourceCoordinates: Equatable, Sendable {
    case glTF
    case worldLabsOpenCV

    var axisConversion: WorldMeshAxisConversion {
        switch self {
        case .glTF:
            .identity
        case .worldLabsOpenCV:
            .flipYAndZ
        }
    }
}

struct MarbleWorld: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let model: String?
    let thumbnailURL: URL?
    let colliderURL: URL?
    let colliderSourceCoordinates: MarbleColliderSourceCoordinates
    let semantics: MarbleWorldSemantics
    let splatFallbacks: [MarbleSplatAsset]

    var preferredSplat: MarbleSplatAsset? {
        splatFallbacks.first
    }

    var isPublicExample: Bool {
        model == MarblePublicWorldCatalog.modelIdentifier
    }

    init(
        id: String,
        name: String,
        model: String? = nil,
        thumbnailURL: URL? = nil,
        colliderURL: URL? = nil,
        colliderSourceCoordinates: MarbleColliderSourceCoordinates = .glTF,
        semantics: MarbleWorldSemantics = .identity,
        splatFallbacks: [MarbleSplatAsset]
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.thumbnailURL = thumbnailURL
        self.colliderURL = colliderURL
        self.colliderSourceCoordinates = colliderSourceCoordinates
        self.semantics = semantics
        self.splatFallbacks = splatFallbacks
    }

}

enum MarblePublicWorldCatalog {
    static let modelIdentifier = "world-labs-official-example"

}
