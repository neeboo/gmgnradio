import Foundation
import WorldRuntime

struct MarbleGenerateWorldRequest: Encodable, Equatable, Sendable {
    struct ImageReference: Encodable, Equatable, Sendable {
        let source = "media_asset"
        let mediaAssetID: String

        private enum CodingKeys: String, CodingKey {
            case source
            case mediaAssetID = "media_asset_id"
        }
    }

    struct WorldPrompt: Encodable, Equatable, Sendable {
        let type: String
        let textPrompt: String
        let disableRecaption = true
        let imagePrompt: ImageReference?
        let isPano: Bool?

        init(preset: SpatialScenePreset) {
            textPrompt = preset.generationPrompt
            if let mediaAssetID = preset.imageMediaAssetID {
                type = "image"
                imagePrompt = ImageReference(mediaAssetID: mediaAssetID)
                isPano = false
            } else {
                type = "text"
                imagePrompt = nil
                isPano = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case textPrompt = "text_prompt"
            case disableRecaption = "disable_recaption"
            case imagePrompt = "image_prompt"
            case isPano = "is_pano"
        }
    }

    let worldPrompt: WorldPrompt
    let displayName: String
    let model: String
    let tags: [String]

    init(preset: SpatialScenePreset) {
        worldPrompt = WorldPrompt(preset: preset)
        displayName = preset.worldDisplayName
        model = preset.generationModel
        tags = preset.tags
    }

    private enum CodingKeys: String, CodingKey {
        case worldPrompt = "world_prompt"
        case displayName = "display_name"
        case model
        case tags
    }
}

struct MarbleOperation: Decodable, Equatable, Sendable {
    let id: String
    let isDone: Bool
    let progressPercentage: Int?
    let errorMessage: String?
    /// Exact result identity; display-name matches do not establish provenance.
    let worldID: String?

    private struct Response: Decodable {
        let worldID: String?
        private enum CodingKeys: String, CodingKey { case worldID = "world_id" }
    }

    private struct OperationError: Decodable {
        let message: String?
    }

    private struct Metadata: Decodable {
        let progress: Progress?
    }

    private struct Progress: Decodable {
        let percentage: Double?
    }

    private enum CodingKeys: String, CodingKey {
        case id = "operation_id"
        case isDone = "done"
        case metadata
        case error
        case response
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        let metadata = try container.decodeIfPresent(
            Metadata.self,
            forKey: .metadata
        )
        progressPercentage = metadata?.progress?.percentage.map {
            Int($0.rounded())
        }
        errorMessage = try container.decodeIfPresent(
            OperationError.self,
            forKey: .error
        )?.message
        worldID = try container.decodeIfPresent(Response.self, forKey: .response)?.worldID
    }
}

enum MarbleSplatQuality: String, Codable, CaseIterable, Sendable {
    case oneHundredK = "100k"
    case oneHundredFiftyK = "150k"
    case fiveHundredK = "500k"
    case fullResolution = "full_res"

    static let playbackOrder: [Self] = [
        .fiveHundredK,
        .oneHundredFiftyK,
        .oneHundredK,
        .fullResolution,
    ]
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

struct MarbleWorld: Decodable, Identifiable, Equatable, Sendable {
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

    private enum CodingKeys: String, CodingKey {
        case id
        case worldID = "world_id"
        case displayName = "display_name"
        case model
        case assets
    }

    private struct Assets: Decodable {
        let thumbnailURL: URL?
        let mesh: Mesh?
        let splats: Splats?

        private enum CodingKeys: String, CodingKey {
            case thumbnailURL = "thumbnail_url"
            case mesh
            case splats
        }
    }

    private struct Mesh: Decodable {
        let colliderURL: URL?

        private enum CodingKeys: String, CodingKey {
            case colliderURL = "collider_mesh_url"
        }
    }

    private struct Splats: Decodable {
        let URLs: [String: URL]
        let semantics: Semantics?

        private enum CodingKeys: String, CodingKey {
            case URLs = "spz_urls"
            case semantics = "semantics_metadata"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            URLs = try container.decodeIfPresent(
                [String: URL].self,
                forKey: .URLs
            ) ?? [:]
            semantics = try container.decodeIfPresent(
                Semantics.self,
                forKey: .semantics
            )
        }
    }

    private struct Semantics: Decodable {
        let metricScale: Double?
        let groundPlaneOffset: Double?

        private enum CodingKeys: String, CodingKey {
            case metricScale = "metric_scale_factor"
            case groundPlaneOffset = "ground_plane_offset"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .worldID)
            ?? container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(
            String.self,
            forKey: .displayName
        ) ?? id
        model = try container.decodeIfPresent(String.self, forKey: .model)

        let assets = try container.decodeIfPresent(
            Assets.self,
            forKey: .assets
        )
        thumbnailURL = assets?.thumbnailURL
        colliderURL = assets?.mesh?.colliderURL
        colliderSourceCoordinates = .glTF

        let rawURLs = assets?.splats?.URLs ?? [:]
        splatFallbacks = MarbleSplatQuality.playbackOrder.compactMap {
            quality in
            guard let url = rawURLs[quality.rawValue] else {
                return nil
            }
            return MarbleSplatAsset(quality: quality, url: url)
        }

        let rawSemantics = assets?.splats?.semantics
        semantics = MarbleWorldSemantics(
            metricScale: rawSemantics?.metricScale ?? 1,
            groundPlaneOffset: rawSemantics?.groundPlaneOffset ?? 0
        )
    }
}

enum MarblePublicWorldCatalog {
    static let modelIdentifier = "world-labs-official-example"

    static let worlds: [MarbleWorld] = [
        world(
            id: "world-labs-example-elegant-library",
            name: "壁炉图书馆",
            slug: "elegant_library_with_fireplace"
        ),
        world(
            id: "world-labs-example-modern-house",
            name: "现代住宅",
            slug: "modern_house_with_lush_landscaping"
        ),
        world(
            id: "world-labs-example-rustic-kitchen",
            name: "自然光乡村厨房",
            slug: "rustic_kitchen_with_natural_light"
        ),
        world(
            id: "world-labs-example-cobblestone-lane",
            name: "欧洲石板巷",
            slug: "narrow_european_cobblestone_lane"
        ),
        world(
            id: "world-labs-example-warm-kitchen",
            name: "暖色传统厨房",
            slug: "warm_traditional_kitchen_interior"
        ),
    ]

    private static func world(
        id: String,
        name: String,
        slug: String
    ) -> MarbleWorld {
        let root = "https://wlt-ai-cdn.art/example_exports/\(slug)"
        return MarbleWorld(
            id: id,
            name: name,
            model: modelIdentifier,
            colliderURL: URL(string: "\(root)/\(slug)_collider.glb")!,
            colliderSourceCoordinates: .worldLabsOpenCV,
            splatFallbacks: [
                MarbleSplatAsset(
                    quality: .fiveHundredK,
                    url: URL(string: "\(root)/\(slug)_500k.spz")!
                ),
                MarbleSplatAsset(
                    quality: .fullResolution,
                    url: URL(string: "\(root)/\(slug)_2m.spz")!
                ),
            ]
        )
    }
}

struct MarbleWorldListResponse: Decodable, Equatable, Sendable {
    let worlds: [MarbleWorld]
    let nextPageToken: String?

    private enum CodingKeys: String, CodingKey {
        case worlds
        case nextPageToken = "next_page_token"
    }
}

struct MarbleWorldResponse: Decodable, Equatable, Sendable {
    let world: MarbleWorld

    init(from decoder: Decoder) throws {
        if let wrapped = try? decoder.container(
            keyedBy: CodingKeys.self
        ), let world = try wrapped.decodeIfPresent(
            MarbleWorld.self,
            forKey: .world
        ) {
            self.world = world
        } else {
            world = try MarbleWorld(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case world
    }
}
