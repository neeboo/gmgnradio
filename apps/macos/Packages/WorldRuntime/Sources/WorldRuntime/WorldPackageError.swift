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
    /// 活动的 `functionPoint` 入口绑到了一件**不在同一行 `propIDs` 里**的道具。
    case functionPointPropNotDeclared(activityID: String, propID: String)
    /// 活动的 `functionPoint` 入口在包里找不到能把该活动绑成接近锚点的道具声明。
    /// 运行时因此注册不出锚点 —— 装载期就拒绝，绝不留一个"没有锚点"的活动。
    case missingFunctionPointDeclaration(activityID: String, propID: String)
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
