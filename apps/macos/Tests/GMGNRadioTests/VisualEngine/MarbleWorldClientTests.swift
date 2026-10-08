import Foundation
import Testing

/// Provider observations are inputs to the real private Rust authority.
@MainActor private struct MarbleTestAuthority {
    let lifecycle: PrivateMusicAuthorityFixture?
    let client: RustMarbleControlClient
    static func start() async throws -> Self {
        let lifecycle: PrivateMusicAuthorityFixture?
        let endpoint: String
        if let injected = ProcessInfo.processInfo.environment["GMGN_MARBLE_TEST_ENDPOINT"] {
            lifecycle = nil
            endpoint = injected
        } else {
            let fixture = try await PrivateMusicAuthorityFixture.start()
            lifecycle = fixture
            endpoint = fixture.root.appendingPathComponent("taskd.endpoint.json").path
        }
        return Self(lifecycle: lifecycle, client: RustMarbleControlClient(endpointFile: endpoint,
            helperPath: "", allowsLaunching: false, owner: "marble-tests-" + UUID().uuidString,
            hostSessionID: UUID().uuidString))
    }
    func plannedGeneration(_ preset: SpatialScenePreset) async throws -> RustMarbleControlClient.Action {
        let current = try await client.read()
        let queued = try await client.command("space.marble.generate", expectedRevision: current.revision, presetID: preset.rawValue)
        let claimed = try await client.claim(taskID: try #require(queued.task).taskID, expectedRevision: queued.revision)
        let action = try #require(claimed.action)
        #expect(action.status == "inflight")
        return action
    }
    func list(_ bytes: Data) async throws -> [MarbleWorld] {
        let current = try await client.read()
        let queued = try await client.command("refresh", expectedRevision: current.revision, pageSize: 50)
        let claimed = try await client.claim(taskID: try #require(queued.task).taskID, expectedRevision: queued.revision)
        let action = try #require(claimed.action)
        #expect(action.kind == "list" && action.method == "POST" && action.path == "/marble/v1/worlds:list")
        let receipt = try await client.receipt(action, fact: RustMarbleControlClient.HTTPFact(statusCode: 200, body: bytes))
        #expect(receipt.task?.status == "completed")
        return try receipt.worlds.map { try $0.nativeWorld() }
    }
}

@testable import GMGNRadio

@MainActor
@Test
func marbleGenerationRequestUsesDJHouseV3Image() async throws {
    let authority = try await MarbleTestAuthority.start()
    let action = try await authority.plannedGeneration(.djHouse)
    let data = try #require(try action.bodyData)
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let prompt = try #require(object["world_prompt"] as? [String: Any])
    let image = try #require(prompt["image_prompt"] as? [String: Any])

    #expect(object["display_name"] as? String == "gmgn DJ House")
    #expect(object["model"] as? String == "marble-1.0-draft")
    #expect(prompt["type"] as? String == "image")
    #expect(prompt["is_pano"] as? Bool == false)
    #expect(image["source"] as? String == "media_asset")
    #expect(
        image["media_asset_id"] as? String
            == "b14767e2-448c-4f61-9c17-b051f3cea509"
    )
    #expect(
        (prompt["text_prompt"] as? String)?.contains("recording studio")
            == true
    )
    #expect(
        object["tags"] as? [String]
            == [
                "gmgn-radio",
                "dj-house",
                "image-v3",
                "recording-studio",
            ]
    )
}

@MainActor
@Test
func marbleGenerationRequestKeepsTextFallbackForCosyHouse() async throws {
    let authority = try await MarbleTestAuthority.start()
    let action = try await authority.plannedGeneration(.cosyWoodHouse)
    let data = try #require(try action.bodyData)
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let prompt = try #require(object["world_prompt"] as? [String: Any])

    #expect(object["model"] as? String == "marble-1.1-plus")
    #expect(prompt["type"] as? String == "text")
    #expect(prompt["image_prompt"] == nil)
    #expect((prompt["text_prompt"] as? String)?.contains("wood cabin") == true)
}

@MainActor
@Test
func marbleOperationDecodesGenerationProgressAndFailure() async throws {
    let progressAuthority = try await MarbleTestAuthority.start()
    let progressAction = try await progressAuthority.plannedGeneration(.djHouse)
    let progress = try await progressAuthority.client.receipt(progressAction,
        fact: RustMarbleControlClient.HTTPFact(statusCode: 200, body: Data(#"""
        {"done":false,"operation_id":"operation-1","metadata":{"progress":{"status":"IN_PROGRESS","percentage":42}}}
        """#.utf8)))
    #expect(progress.task?.operationID == "operation-1")
    #expect(progress.task?.status == "pending")
    #expect(progress.task?.progress == 42)

    let failureAuthority = try await MarbleTestAuthority.start()
    let failureAction = try await failureAuthority.plannedGeneration(.djHouse)
    let failure = try await failureAuthority.client.receipt(failureAction,
        fact: RustMarbleControlClient.HTTPFact(statusCode: 200, body: Data(#"""
        {"done":true,"operation_id":"operation-2","error":{"code":402,"message":"insufficient credits"}}
        """#.utf8)))
    #expect(failure.task?.status == "failed")
    #expect(failure.task?.errorCode == "marble_control_generation_failed")
    #expect(failure.task?.errorMessage == "insufficient credits")
}

@MainActor
@Test
func marbleWorldDecodesSpatialAssetsAndPrefersFiveHundredK() async throws {
    let data = Data(
        #"""
        {
          "worlds": [{
            "world_id": "world-1",
            "display_name": "Sanctuary",
            "model": "marble-1.1",
            "assets": {
              "splats": {
                "spz_urls": {
                  "100k": "https://example.com/100.spz",
                  "500k": "https://example.com/500.spz",
                  "full_res": "https://example.com/full.spz"
                },
                "semantics_metadata": {
                  "metric_scale_factor": 1.76,
                  "ground_plane_offset": 1.01
                }
              },
              "mesh": {
                "collider_mesh_url": "https://example.com/collider.glb"
              }
            }
          }]
        }
        """#.utf8
    )

    let authority = try await MarbleTestAuthority.start()
    let worlds = try await authority.list(data)
    let world = try #require(worlds.first)

    #expect(world.id == "world-1")
    #expect(world.name == "Sanctuary")
    #expect(world.preferredSplat?.quality == .fiveHundredK)
    #expect(
        world.splatFallbacks.map(\.quality)
            == [.fiveHundredK, .oneHundredK, .fullResolution]
    )
    #expect(world.colliderURL?.pathExtension == "glb")
    #expect(world.semantics.metricScale == 1.76)
    #expect(world.semantics.groundPlaneOffset == 1.01)
}

@MainActor
@Test
func publicMarbleCatalogUsesOfficialHTTPSExamplesWithoutGeneration() async throws {
    let authority = try await MarbleTestAuthority.start()
    let snapshot = try await authority.client.read()
    #expect(snapshot.task == nil)
    #expect(snapshot.worlds.count == 5)
    for world in try snapshot.worlds.map({ try $0.nativeWorld() }) {
        #expect(world.isPublicExample)
        #expect(world.preferredSplat?.quality == .fiveHundredK)
        #expect(world.preferredSplat?.url.scheme == "https")
        #expect(world.preferredSplat?.url.host == "wlt-ai-cdn.art")
        #expect(world.colliderURL?.scheme == "https")
        #expect(world.colliderURL?.host == "wlt-ai-cdn.art")
        #expect(
            world.colliderURL?.lastPathComponent.hasSuffix("_collider.glb")
                == true
        )
    }
}

@MainActor
@Test
func marbleWorldFallsBackToAvailablePreviewSplat() async throws {
    let data = Data(
        #"""
        {
          "worlds": [{
            "world_id": "world-2",
            "display_name": "Preview",
            "assets": {
              "splats": {
                "spz_urls": {
                  "100k": "https://example.com/preview.spz"
                }
              }
            }
          }]
        }
        """#.utf8
    )

    let authority = try await MarbleTestAuthority.start()
    let worlds = try await authority.list(data)
    let world = try #require(worlds.first)

    #expect(world.preferredSplat?.quality == .oneHundredK)
    #expect(world.preferredSplat?.url.lastPathComponent == "preview.spz")
}
