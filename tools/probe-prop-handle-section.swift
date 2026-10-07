import Foundation
import simd
import WorldRuntime

@main struct HandleSectionProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass verified source GLB path") }
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let size = WorldVector3(x: 0.14604884, y: 1.1, z: 0.061886825)
        let orientation = WorldQuaternion(x: 0, y: 0, z: 0.70710677, w: 0.7071068)
        let suggestion = PropGripInference.suggestion(size: size, orientation: orientation, geometry: triangles)
        precondition(suggestion.origin == .meshHandleSection, "real blade must have handle evidence")
        precondition(suggestion.normalizedGrip.x > 0.75 && suggestion.normalizedGrip.x < 0.95)
        precondition(suggestion.normalizedGrip.y > 0.65, "handle center must follow actual off-center section")
        precondition(suggestion.isValid)
        let blade = WorldPropRotation.rotate(WorldPropRotation.rotate(SIMD3<Float>(-1, 0, 0), by: orientation), by: suggestion.localRotation)
        precondition(abs(blade.y - 1) < 0.001)
        let mirrored = triangles.map { triangle in
            func mirror(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-p.x, p.y, p.z) }
            return WorldTriangle(mirror(triangle.first), mirror(triangle.second), mirror(triangle.third))
        }
        let reverse = PropGripInference.suggestion(size: size, orientation: orientation, geometry: mirrored)
        precondition(reverse.origin == .meshHandleSection)
        precondition(abs(reverse.normalizedGrip.x + suggestion.normalizedGrip.x - 1) < 0.03)
        let unknown = PropGripInference.suggestion(size: size, orientation: orientation)
        precondition(unknown.origin == .unknownHandle)
        // Actual six-view mesh inspection confirms raw -Y is the cutting edge;
        // -X is handle→tip, not the cutting edge or the broad face normal.
        let axis = PropGripInference.preparedSourceDirection(SIMD3<Float>(-1, 0, 0), orientation: orientation)
        let edge = PropGripInference.preparedSourceDirection(SIMD3<Float>(0, -1, 0), orientation: orientation)
        let frame = PropGripInference.rotationAligningFrame(primary: axis, edge: edge,
            toPrimary: SIMD3<Float>(0, 1, 0), toEdge: SIMD3<Float>(0, 0, 1))!
        precondition(simd_dot(WorldPropRotation.rotate(axis, by: frame), SIMD3<Float>(0, 1, 0)) > 0.9999)
        precondition(simd_dot(WorldPropRotation.rotate(edge, by: frame), SIMD3<Float>(0, 0, 1)) > 0.9999)
        precondition(PropGripInference.rotationAligningFrame(primary: axis, edge: axis,
            toPrimary: SIMD3<Float>(0, 1, 0), toEdge: SIMD3<Float>(0, 0, 1)) == nil)
        precondition(PropGripInference.rotationAligningFrame(primary: axis, edge: edge,
            toPrimary: SIMD3<Float>(0, 1, 0), toEdge: SIMD3<Float>(0, 1, 0)) == nil)
        precondition(PropGripInference.rotationAligningFrame(primary: .zero, edge: edge,
            toPrimary: SIMD3<Float>(0, 1, 0), toEdge: SIMD3<Float>(0, 0, 1)) == nil)
        let verifiedProp = WorldGeneratedProp(objectID: "actual-sword", sourceWishID: "actual-wish",
            assetID: "sha256:e9dda009e47ca4c1ace5e8a6e4ccf18645a109556b4f4772e410815c2be05529",
            displayName: "actual white sword", size: size, sourceHeight: 1.0054325,
            orientation: .init(rotation: orientation, source: .inferredPrincipalAxis, notice: nil))
        let verified = PropGripInference.verifiedForwardFacingSwordRotation(for: verifiedProp,
            avatarAssetID: "pmx.2b-miss-0414-standard")!
        precondition(simd_dot(WorldPropRotation.rotate(axis, by: verified),
            SIMD3<Float>(0.3697862, -0.2558435, -0.8931977)) > 0.9999)
        precondition(simd_dot(WorldPropRotation.rotate(edge, by: verified),
            SIMD3<Float>(0.8843164, 0.3918314, 0.2538750)) > 0.9999)
        precondition(PropGripInference.verifiedForwardFacingSwordRotation(for: verifiedProp,
            avatarAssetID: "unmeasured-avatar") == nil)
        print("verified forward-facing persisted rotation=\(verified)")
        print("PASS actual GLB + reversed source axis + missing geometry")
        print("source grip=\(suggestion.normalizedGrip) rotation=\(suggestion.localRotation)")
    }
}
