import Foundation

/// Explicit asset-space calibration. Coordinates use the same bottom-centred,
/// metre-sized source mesh after glTF/WorldCoordinates axis conversion, before size normalization.
public struct WorldPropSeatCalibration: Codable, Equatable, Sendable {
    public static let metadataKey = "gmgn.prop-seat.v1"
    public let assetID: String
    public let contactPoint: WorldVector3
    public let approachPoint: WorldVector3
    public let facingYaw: Float
    public let sourceSize: WorldVector3

    public init(assetID: String, contactPoint: WorldVector3,
                approachPoint: WorldVector3, facingYaw: Float, sourceSize: WorldVector3) {
        self.assetID = assetID; self.contactPoint = contactPoint
        self.approachPoint = approachPoint; self.facingYaw = facingYaw
        self.sourceSize = sourceSize
    }

    public var isValid: Bool {
        !assetID.isEmpty && assetID.count <= 256 && facingYaw.isFinite
            && [sourceSize.x, sourceSize.y, sourceSize.z].allSatisfy { $0.isFinite && $0 > 0 }
            && [contactPoint.x, contactPoint.y, contactPoint.z,
                approachPoint.x, approachPoint.y, approachPoint.z]
                .allSatisfy { $0.isFinite && abs($0) <= 10 }
            && contactPoint.y > 0 && contactPoint.y <= sourceSize.y
            && abs(contactPoint.x) <= sourceSize.x / 2 && abs(contactPoint.z) <= sourceSize.z / 2
            && approachPoint.y == 0
    }

    /// This exact mesh was inspected from all six axes and ray-sampled at
    /// source x=0,z=.16: top y=.0335244902, bottom y=-.2530443966.
    /// It is deliberately keyed by immutable asset identity, never its name.
    public static let inspectedThreeSeatSofa = WorldPropSeatCalibration(
        assetID: "sha256:0eb955793605cbfe0680616f98991369f85fd46c317d1b51a877949b3fb36303",
        contactPoint: WorldVector3(x: -0.000149548054, y: 0.286568887, z: -0.160351936),
        approachPoint: WorldVector3(x: -0.000149548054, y: 0, z: -0.450351936),
        facingYaw: .pi,
        sourceSize: WorldVector3(x: 1.006890178, y: 0.511452764, z: 0.568691671))

    public func resolve(objectID: String, state: WorldObjectState) -> WorldPropSeatProjection? {
        guard isValid, state.isEnabled, let prop = state.generatedProp,
              prop.objectID == objectID, prop.assetID == assetID,
              prop.orientation?.rotation == nil || prop.orientation?.rotation == .identity
        else { return nil }
        guard [state.transform.position.x,state.transform.position.y,state.transform.position.z,
               state.transform.rotation.x,state.transform.rotation.y,state.transform.rotation.z,
               state.transform.rotation.w].allSatisfy(\.isFinite),
              abs(state.transform.rotation.x) < 0.001, abs(state.transform.rotation.z) < 0.001 else { return nil }
        // The renderer fits to effectiveSize and ignores the legacy transform
        // scale: applying that scale again would double-size the seat.
        let size = prop.effectiveSize
        guard [size.x,size.y,size.z].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let scale = WorldVector3(x: size.x/sourceSize.x, y: size.y/sourceSize.y, z: size.z/sourceSize.z)
        let q = state.transform.rotation
        let yaw = atan2(2 * (q.w*q.y + q.x*q.z), 1 - 2 * (q.y*q.y + q.z*q.z))
        func point(_ p: WorldVector3) -> WorldVector3 {
            WorldPropAnchorRegistry.worldPosition(of: WorldVector3(
                x: p.x * scale.x, y: p.y * scale.y,
                z: p.z * scale.z), placedAt: state.transform.position, yaw: yaw)
        }
        return WorldPropSeatProjection(objectID: objectID, contactPoint: point(contactPoint),
            approachPoint: point(approachPoint), facingYaw: yaw + facingYaw)
    }
}

public struct WorldPropSeatProjection: Codable, Equatable, Sendable {
    public let objectID: String
    public let contactPoint: WorldVector3
    public let approachPoint: WorldVector3
    public let facingYaw: Float
    public var activityID: String { "prop.seat.\(objectID)" }
}

public extension WorldObjectState {
    var seatCalibration: WorldPropSeatCalibration? {
        guard let prop = generatedProp else { return nil }
        if let json = metadata[WorldPropSeatCalibration.metadataKey] {
            guard let data = json.data(using: .utf8),
                  let value = try? JSONDecoder().decode(WorldPropSeatCalibration.self, from: data),
                  value.isValid, value.assetID == prop.assetID else { return nil }
            return value
        }
        let inspected = WorldPropSeatCalibration.inspectedThreeSeatSofa
        return prop.assetID == inspected.assetID ? inspected : nil
    }
}
