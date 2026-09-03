import Foundation
import Testing
@testable import WorldRuntime

@Test("World manifest decodes stable world, activity, and camera identifiers")
func worldManifestDecodesStableIdentifiers() throws {
    let fixture = Data(
        """
        {
          "schemaVersion": 1,
          "packageID": "warm-kitchen-canary",
          "packageVersion": "1.0.0",
          "worldID": "world-labs-example-warm-kitchen",
          "displayName": "Warm Kitchen",
          "calibration": {
            "visualToGameplay": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            "metersPerUnit": 1
          },
          "spawn": {
            "position": {"x": 0, "y": 0, "z": 0},
            "rotation": {"x": 0, "y": 0, "z": 0, "w": 1},
            "scale": {"x": 1, "y": 1, "z": 1}
          },
          "collisionVolumes": [],
          "waypoints": [
            {"id": "wp.window", "position": {"x": 1, "y": 0, "z": 2}, "arrivalRadius": 0.2, "enabled": true}
          ],
          "routes": [],
          "activities": [
            {
              "id": "window.gaze",
              "action": "gaze",
              "entryWaypointID": "wp.window",
              "transform": {
                "position": {"x": 1, "y": 0, "z": 2},
                "rotation": {"x": 0, "y": 0, "z": 0, "w": 1},
                "scale": {"x": 1, "y": 1, "z": 1}
              },
              "motionID": "gaze.window",
              "propIDs": [],
              "interruptible": true
            }
          ],
          "cameras": [
            {
              "id": "living.establishing",
              "transform": {
                "position": {"x": 0, "y": 1.6, "z": 4},
                "rotation": {"x": 0, "y": 0, "z": 0, "w": 1},
                "scale": {"x": 1, "y": 1, "z": 1}
              },
              "fieldOfViewDegrees": 50,
              "nearPlane": 0.05,
              "farPlane": 100
            }
          ],
          "capabilities": ["activity:window.gaze", "camera:living.establishing"],
          "resources": []
        }
        """.utf8
    )

    let manifest = try JSONDecoder().decode(WorldManifest.self, from: fixture)

    #expect(manifest.schemaVersion == 1)
    #expect(manifest.worldID == "world-labs-example-warm-kitchen")
    #expect(manifest.activities.map(\.id).contains("window.gaze"))
    #expect(manifest.cameras.map(\.id).contains("living.establishing"))
    #expect(manifest.activityDefinitions.isEmpty)
}

@Test("World manifest carries a complete living activity definition")
func worldManifestCarriesLivingActivityDefinition() throws {
    let fixture = Data(
        """
        {
          "schemaVersion": 1,
          "packageID": "second-world",
          "packageVersion": "1.0.0",
          "worldID": "world.second",
          "displayName": "Second World",
          "calibration": {
            "visualToGameplay": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            "metersPerUnit": 1
          },
          "spawn": {
            "position": {"x": 0, "y": 0, "z": 0},
            "rotation": {"x": 0, "y": 0, "z": 0, "w": 1},
            "scale": {"x": 1, "y": 1, "z": 1}
          },
          "collisionVolumes": [],
          "waypoints": [
            {"id": "wp.music", "position": {"x": 0, "y": 0, "z": 0}, "arrivalRadius": 0.2, "enabled": true}
          ],
          "routes": [],
          "activities": [
            {
              "id": "music.listen",
              "action": "listenMusic",
              "entryWaypointID": "wp.music",
              "transform": {
                "position": {"x": 0, "y": 0, "z": 0},
                "rotation": {"x": 0, "y": 0, "z": 0, "w": 1},
                "scale": {"x": 1, "y": 1, "z": 1}
              },
              "motionID": "listen.loop",
              "propIDs": ["speaker"],
              "interruptible": true
            }
          ],
          "activityDefinitions": [
            {
              "id": "music.listen",
              "activity": {"type": "listenMusic", "anchorID": "music.listen"},
              "phases": [
                {"phase": "approach", "requiredAnchorIDs": ["music.listen"], "motionIDs": [], "propIDs": [], "durationSeconds": null},
                {"phase": "enter"},
                {"phase": "loop", "requiredAnchorIDs": [], "motionIDs": ["listen.loop"], "propIDs": ["speaker"], "durationSeconds": 30},
                {"phase": "exit", "requiredAnchorIDs": [], "motionIDs": [], "propIDs": [], "durationSeconds": null},
                {"phase": "interrupt", "requiredAnchorIDs": [], "motionIDs": [], "propIDs": [], "durationSeconds": null},
                {"phase": "failed", "requiredAnchorIDs": [], "motionIDs": [], "propIDs": [], "durationSeconds": null}
              ],
              "interruptible": true,
              "cooldownSeconds": 45
            }
          ],
          "cameras": [],
          "capabilities": ["activity:music.listen"],
          "resources": []
        }
        """.utf8
    )

    let manifest = try JSONDecoder().decode(WorldManifest.self, from: fixture)

    #expect(manifest.activities.first?.action == "listenMusic")
    #expect(manifest.activityDefinitions.first?.activity == .listenMusic(anchorID: "music.listen"))
    #expect(manifest.activityDefinitions.first?.contract(for: .loop)?.motionIDs == ["listen.loop"])
    #expect(manifest.activityDefinitions.first?.cooldownSeconds == 45)
}

@Test("Bundled canary world supplies every activity contract without code tables")
func bundledCanaryWorldSuppliesEveryActivityContract() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let manifestURL = testFile
        .deletingLastPathComponent()
        .appendingPathComponent("../../../../Resources/Worlds/warm-kitchen-canary/world.json")
        .standardizedFileURL
    let manifest = try JSONDecoder().decode(
        WorldManifest.self,
        from: Data(contentsOf: manifestURL)
    )

    let catalog = try ActivityCatalog(manifest: manifest)

    #expect(manifest.activityDefinitions.count == manifest.activities.count)
    #expect(catalog.definitions.count == manifest.activities.count)
    #expect(catalog.definition(id: "music.listen")?.activity == .listenMusic(
        anchorID: "music.listen"
    ))
    for activityID in ["chair.sit", "music.listen", "window.gaze"] {
        let approach = try #require(
            catalog.definition(id: activityID)?.contract(for: .approach)
        )
        #expect(
            approach.motionIDs.contains("gmgn.motion.bones.walk-loop-pmx")
        )
        #expect(
            approach.motionIDs.contains("gmgn.motion.bones.walk-loop-vrm")
        )
        #expect(
            approach.motionIDs.first == "gmgn.motion.bones.walk-loop-pmx"
        )
    }
}

@Test("A second world package supplies dynamic activity and camera capabilities")
func secondWorldPackageUsesOnlyManifestAuthoredCapabilities() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let manifestURL = testFile
        .deletingLastPathComponent()
        .appendingPathComponent("../../../../Resources/Worlds/quiet-corner-fixture/world.json")
        .standardizedFileURL
    let packageRoot = manifestURL.deletingLastPathComponent()
    let manifest = try JSONDecoder().decode(
        WorldManifest.self,
        from: Data(contentsOf: manifestURL)
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: packageRoot
    )
    let catalog = try ActivityCatalog(manifest: manifest)

    #expect(findings.isEmpty)
    #expect(manifest.worldID == "world-fixture-quiet-corner")
    #expect(catalog.definition(id: "fixture.window.gaze")?.activity == .gaze(
        targetID: "fixture.window.gaze"
    ))
    #expect(manifest.capabilities == [
        .activity("fixture.idle"),
        .activity("fixture.window.gaze"),
        .camera("fixture.character.closeup"),
    ])
}
