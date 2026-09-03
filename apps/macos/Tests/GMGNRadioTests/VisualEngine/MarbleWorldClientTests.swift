import Foundation
import Testing
@testable import GMGNRadio

@Test
func marbleGenerationRequestUsesDJHouseV3Image() throws {
    let data = try JSONEncoder().encode(
        MarbleGenerateWorldRequest(preset: .djHouse)
    )
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

@Test
func marbleGenerationRequestKeepsTextFallbackForCosyHouse() throws {
    let data = try JSONEncoder().encode(
        MarbleGenerateWorldRequest(preset: .cosyWoodHouse)
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let prompt = try #require(object["world_prompt"] as? [String: Any])

    #expect(object["model"] as? String == "marble-1.1-plus")
    #expect(prompt["type"] as? String == "text")
    #expect(prompt["image_prompt"] == nil)
}

@Test
func marbleOperationDecodesGenerationProgressAndFailure() throws {
    let progress = try JSONDecoder().decode(
        MarbleOperation.self,
        from: Data(#"""
        {
          "done": false,
          "operation_id": "operation-1",
          "metadata": {"progress": {"status": "IN_PROGRESS", "percentage": 42}}
        }
        """#.utf8)
    )
    #expect(progress.id == "operation-1")
    #expect(progress.isDone == false)
    #expect(progress.progressPercentage == 42)

    let failure = try JSONDecoder().decode(
        MarbleOperation.self,
        from: Data(#"""
        {
          "done": true,
          "operation_id": "operation-2",
          "error": {"code": 402, "message": "insufficient credits"}
        }
        """#.utf8)
    )
    #expect(failure.isDone)
    #expect(failure.errorMessage == "insufficient credits")
}

@Test
func marbleWorldDecodesSpatialAssetsAndPrefersFiveHundredK() throws {
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

    let response = try JSONDecoder().decode(
        MarbleWorldListResponse.self,
        from: data
    )
    let world = try #require(response.worlds.first)

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

@Test
func publicMarbleCatalogUsesOfficialHTTPSExamplesWithoutGeneration() throws {
    #expect(MarblePublicWorldCatalog.worlds.count == 5)
    for world in MarblePublicWorldCatalog.worlds {
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

@Test
func marbleWorldFallsBackToAvailablePreviewSplat() throws {
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

    let response = try JSONDecoder().decode(
        MarbleWorldListResponse.self,
        from: data
    )
    let world = try #require(response.worlds.first)

    #expect(world.preferredSplat?.quality == .oneHundredK)
    #expect(world.preferredSplat?.url.lastPathComponent == "preview.spz")
}
