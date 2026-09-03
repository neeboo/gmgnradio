public struct WorldCameraState: Codable, Equatable, Sendable {
    public var anchorID: String?
    public var transform: WorldTransform
    public var fieldOfViewDegrees: Float
    public var nearPlane: Float
    public var farPlane: Float

    public init(
        anchorID: String?,
        transform: WorldTransform,
        fieldOfViewDegrees: Float,
        nearPlane: Float,
        farPlane: Float
    ) {
        self.anchorID = anchorID
        self.transform = transform
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.nearPlane = nearPlane
        self.farPlane = farPlane
    }

    public init(anchorID: String? = nil, anchor: WorldCameraAnchor) {
        self.init(
            anchorID: anchorID ?? anchor.id,
            transform: anchor.transform,
            fieldOfViewDegrees: anchor.fieldOfViewDegrees,
            nearPlane: anchor.nearPlane,
            farPlane: anchor.farPlane
        )
    }
}

/// Keeps automatic framing separate from direct user camera manipulation.
public struct LiveCamCameraState: Codable, Equatable, Sendable {
    public var director: WorldCameraState
    public var user: WorldCameraState

    public init(director: WorldCameraState, user: WorldCameraState) {
        self.director = director
        self.user = user
    }
}
