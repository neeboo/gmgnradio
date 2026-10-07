import Foundation
import CryptoKit
import WorldRuntime
import UnityMediaHost
import MMDSceneKit

/// Read-only rehearsal. The real service runs all spatial checks; its persistence
/// seam captures the candidate in memory. This tool has no authority write mode.
final class GripPreviewPersistence: WorldStatePersisting, @unchecked Sendable {
    let baseline: WorldState
    private(set) var candidate: WorldState?
    init(_ state: WorldState) { baseline = state }
    func load() throws -> WorldState? { baseline }
    func save(_ state: WorldState) throws { candidate = state }
}

@main struct RecalibrateHeldProp {
    static func output(_ value: [String: Any]) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }
    static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    static func fail(_ code: String) throws -> Never {
        try output(["ok": false, "code": code, "mode": "preview", "authority_mutated": false])
        exit(2)
    }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 7 else {
            print("Usage: preview WORLD_ID OBJECT_ID AVATAR_ID APP_BUNDLE APPLICATION_SUPPORT_BASE ASSET_ID (six positional arguments; no apply mode)")
            exit(64)
        }
        let worldID = CommandLine.arguments[1], objectID = CommandLine.arguments[2]
        let avatarID = CommandLine.arguments[3]
        let bundleURL = URL(fileURLWithPath: CommandLine.arguments[4]).standardizedFileURL
        let root = URL(fileURLWithPath: CommandLine.arguments[5]).standardizedFileURL
        let assetID = CommandLine.arguments[6]
        guard let bundle = Bundle(url: bundleURL) else { try fail("invalid_app_bundle") }
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root, bundle: bundle)
        let client = WorldAuthorityClient(worldID: worldID, endpointFile: endpoint.endpointFile,
            helperPath: endpoint.helperPath, allowsLaunching: false)
        guard let record = try client.snapshot(), record.state.worldID == worldID else { try fail("world_missing") }
        guard let item = record.state.objectStates[objectID], let prop = item.generatedProp,
              prop.objectID == objectID, prop.assetID == assetID,
              record.state.propTombstones?[objectID] == nil else { try fail("target_identity_mismatch") }
        try output(["mode": "preview", "world_id": worldID, "record_revision": record.recordRevision,
            "layout_revision": record.state.layoutRevision, "state_sha256": record.stateSha256,
            "object_id": objectID, "asset_id": prop.assetID, "object_enabled": item.isEnabled,
            "held": try record.state.heldProp.map { try json($0) } ?? NSNull(),
            "existing_calibration": try item.gripCalibration.map { try json($0) } ?? NSNull(),
            "authority_mutated": false])
        // Do not replay a stale request after return_held_prop. This CLI cannot
        // turn a placed/inventory object into a new hold.
        guard let held = record.state.heldProp, held.objectID == objectID,
              held.avatarAssetID == avatarID, held.hand == .rightHand else { try fail("target_not_currently_held_in_right_hand") }
        guard record.state.activeActivity == nil else { try fail("activity_active") }

        let package = try LivingWorldBootstrap.loadBundledCanary(bundle: bundle)
        guard package.manifest.worldID == worldID else { try fail("selected_package_mismatch") }
        guard let cabin = try LivingWorldBootstrap.loadMarbleCabin(package: package) else { try fail("real_cabin_geometry_unavailable") }
        let collision = MarbleLivingCabinCollisionWorld(
            environment: TriangleMeshCollisionWorld(triangles: try GLBColliderDecoder().decode(
                data: Data(contentsOf: cabin.colliderURL, options: .mappedIfSafe),
                transform: cabin.presentation.sceneFraming.colliderTransform(sourceCoordinates: cabin.world.colliderSourceCoordinates))),
            props: CollisionVolumeWorld(volumes: ResidentPropPlacementConfiguration.independentCollisionVolumes(package.manifest)))
        let persistence = GripPreviewPersistence(record.state)
        let context = try WorldAgentContext(manifest: package.manifest, persistence: persistence,
            capsule: LivingWorldBootstrap.collisionCapsule(worldID: worldID),
            propFunctionSources: LivingWorldBootstrap.propFunctionSources(in: package), initialCollisionWorld: collision)
        guard let base = context.propSupportQuerying else { try fail("support_geometry_unavailable") }
        let positions = package.manifest.waypoints.filter(\.enabled).map(\.position)
        guard !positions.isEmpty else { try fail("navigation_waypoints_unavailable") }
        let parameters = PropSupportGridParameters.default
        let margin = parameters.spacing + parameters.capsuleRadius
        let bounds = WorldPlanarBounds(minimumX: positions.map(\.x).min()! - margin,
            maximumX: positions.map(\.x).max()! + margin, minimumZ: positions.map(\.z).min()! - margin,
            maximumZ: positions.map(\.z).max()! + margin)
        let grid = ResidentPropGridEditorModel()
        grid.setRouteBand(fromWaypoints: package.manifest.waypoints)
        await grid.preparePlacementSupport(collision: PropSupportDerivationWorld(base: base,
            topVolumes: package.manifest.collisionVolumes.filter(\.isBlocking)),
            seed: package.manifest.spawn.position, bounds: bounds, key: worldID)

        let supportRoot = root.appendingPathComponent("gmgn radio", isDirectory: true)
        let daemon = PropTaskDaemonClient(root: supportRoot.appendingPathComponent("TaskService", isDirectory: true),
            legacyRoot: supportRoot.appendingPathComponent("PropGeneration", isDirectory: true), allowsLaunching: false)
        let tasks = try await daemon.snapshot()
        let scope = "resident.world." + Data(worldID.utf8).base64EncodedString()
        let catalog = UnityGeneratedAssetCatalog(root: root, worldID: worldID, residentScope: scope)
        try catalog.update(state: record.state, jobs: tasks.jobs, revision: record.state.layoutRevision)
        let modelURL = try catalog.verifyPreparedAsset(prop)
        let geometry = try GLBColliderDecoder().decode(data: Data(contentsOf: modelURL, options: .mappedIfSafe))
        let presenceRoot = supportRoot.appendingPathComponent("PresencePackages", isDirectory: true)
        guard FileManager.default.fileExists(atPath: presenceRoot.path) else { try fail("active_avatar_registry_missing") }
        let avatars = PresencePackageStore(rootURL: presenceRoot)
        guard let avatar = try avatars.activeAvatar(), avatar.id == avatarID, avatar.format == .pmx,
              let scene = MMDSceneSource(url: avatar.modelURL), let model = scene.getModel(),
              PropAttachmentSlots.boneNameCandidates(for: .rightHand).contains(where: {
                  model.childNode(withName: $0, recursively: true) != nil
              }) else { try fail("active_avatar_or_wrist_bone_mismatch") }
        let service = ResidentPropPlacementService(context: context, support: {
            guard let support = grid.supportForPlacement(key: worldID) else { return nil }
            return ResidentPropPlacementSupport(grid: support.grid, collision: support.collision,
                routeConstraint: grid.routeConstraint(activities: package.manifest.activities, waypoints: package.manifest.waypoints))
        }, prepare: { _ = try catalog.verifyPreparedAsset($0) }, currentAvatarAssetID: {
            try? avatars.activeAvatar()?.id
        }, makeGripCalibration: { candidate, selectedAvatarID, point in
            guard candidate == prop, selectedAvatarID == avatarID, point == .rightHand,
                  let calibration = PropAttachmentSlots.calibration(avatarAssetID: avatarID, prop: candidate,
                    point: point, geometry: geometry) else { throw PropAttachmentError.invalidHandPose }
            return calibration
        })
        guard let fresh = try client.snapshot(), fresh.recordRevision == record.recordRevision,
              fresh.state == record.state else { try fail("authority_changed_retry_preview") }
        let command = try service.holdCommand(objectID: objectID, point: .rightHand)
        guard case .adjustGrip = command else { try fail("unexpected_new_hold_command") }
        let result = try service.commit(command, expectedLayoutRevision: record.state.layoutRevision,
            requestID: "grip-preview:" + UUID().uuidString.lowercased())
        var oldReturnMetadata = held.returnState.metadata
        var newReturnMetadata = result.heldProp?.returnState.metadata ?? [:]
        oldReturnMetadata.removeValue(forKey: "gmgn.prop-grip.v1")
        newReturnMetadata.removeValue(forKey: "gmgn.prop-grip.v1")
        guard persistence.candidate == result,
              result.heldProp?.objectID == held.objectID,
              result.heldProp?.returnState.transform == held.returnState.transform,
              result.heldProp?.returnState.isEnabled == held.returnState.isEnabled,
              result.heldProp?.returnState.generatedProp == held.returnState.generatedProp,
              oldReturnMetadata == newReturnMetadata,
              result.objectStates.count == record.state.objectStates.count else { try fail("unexpected_recalibration_delta") }
        try output(["ok": true, "mode": "preview", "authority_mutated": false,
            "validation": "production holdCommand + complete service.commit spatial validation; in-memory persistence only",
            "avatar_source_bone_validated": true, "live_renderer_readiness_rechecked": false,
            "command": try json(command), "new_calibration": try result.objectStates[objectID]?.gripCalibration.map { try json($0) } ?? NSNull(),
            "return_placement_preserved": true, "asset_id": assetID])
    }
}
