public enum WorldPackageError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: [Int])
    case invalidCalibrationVisualToGameplay
    case invalidCalibrationMetersPerUnit
    case duplicateID(collection: String, id: String)
    case missingRouteWaypoint(routeID: String, waypointID: String)
    case missingActivityEntryWaypoint(activityID: String, waypointID: String)
    case activityEntryTransformMismatch(
        activityID: String,
        waypointID: String,
        distance: Float,
        maximumDistance: Float
    )
    case missingActivityPropResource(activityID: String, resourceID: String)
    case missingActivityDefinition(activityID: String)
    case duplicateActivityDefinition(activityID: String)
    case orphanActivityDefinition(activityID: String)
    case activityDefinitionActionMismatch(
        activityID: String,
        anchorAction: String,
        definitionAction: String
    )
    case activityWalkDestinationMismatch(
        activityID: String,
        entryWaypointID: String,
        destinationWaypointID: String
    )
    case missingActivityDefinitionPhase(
        activityID: String,
        phase: LifeActivityPhase
    )
    case duplicateActivityDefinitionPhase(
        activityID: String,
        phase: LifeActivityPhase
    )
    case invalidCameraPlanes(cameraID: String, nearPlane: Float, farPlane: Float)
    case resourcePathEscapesPackageRoot(resourceID: String, path: String)
    case resourceNotFound(resourceID: String, path: String)
    case resourceUnreadable(resourceID: String, path: String)
    case resourceSHA256Mismatch(resourceID: String, expected: String, actual: String)
    case unmatchedCapability(capability: WorldCapability)
}
