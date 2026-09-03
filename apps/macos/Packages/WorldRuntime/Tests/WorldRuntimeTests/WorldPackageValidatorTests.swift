import Foundation
import Testing
@testable import WorldRuntime

@Test("Validator accepts a valid manifest")
func validatorAcceptsValidManifest() {
    let findings = WorldPackageValidator().validate(
        makeManifest(),
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings.isEmpty)
}

@Test("Validator reports duplicate identifiers")
func validatorReportsDuplicateIdentifiers() {
    let duplicate = WorldWaypoint(
        id: "wp.spawn",
        position: .zero,
        arrivalRadius: 0.2,
        enabled: true
    )
    let manifest = makeManifest(waypoints: [duplicate, duplicate])

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [.duplicateID(collection: "waypoints", id: "wp.spawn")])
}

@Test("Validator applies the shared invalid package fixture")
func validatorAppliesSharedInvalidPackageFixture() {
    let sharedID = "shared.anchor"
    let waypoint = WorldWaypoint(
        id: sharedID,
        position: .zero,
        arrivalRadius: 0.2,
        enabled: true
    )
    let camera = makeCamera(id: sharedID)
    let manifest = makeManifest(
        calibration: WorldCalibration(
            visualToGameplay: Array(repeating: 0, count: 15),
            metersPerUnit: 0
        ),
        waypoints: [waypoint],
        activities: [
            makeActivity(
                entryWaypointID: sharedID,
                propIDs: ["prop.missing"]
            ),
        ],
        cameras: [camera],
        capabilities: [.activity("window.gaze"), .camera(sharedID)]
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .invalidCalibrationVisualToGameplay,
        .invalidCalibrationMetersPerUnit,
        .duplicateID(collection: "waypoints,cameras", id: sharedID),
        .missingActivityPropResource(
            activityID: "window.gaze",
            resourceID: "prop.missing"
        ),
    ])
}

@Test("Validator rejects non-finite calibration values")
func validatorRejectsNonFiniteCalibrationValues() {
    var matrix = Array(repeating: Float(0), count: 16)
    matrix[7] = .nan
    let manifest = makeManifest(
        calibration: WorldCalibration(
            visualToGameplay: matrix,
            metersPerUnit: .infinity
        )
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .invalidCalibrationVisualToGameplay,
        .invalidCalibrationMetersPerUnit,
    ])
}

@Test("Validator accepts a legacy package without activity definitions")
func validatorAcceptsLegacyPackageWithoutActivityDefinitions() {
    let findings = WorldPackageValidator().validate(
        makeManifest(activityDefinitions: []),
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings.isEmpty)
}

@Test("Validator requires definitions for every anchor when the field is present")
func validatorRequiresDefinitionsForEveryAnchorWhenPresent() {
    let idle = makeActivity(id: "home.idle", action: "idle")
    let manifest = makeManifest(
        activities: [makeActivity(), idle],
        activityDefinitions: [makeDefinition()],
        capabilities: [.activity("window.gaze"), .activity("home.idle")]
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .missingActivityDefinition(activityID: "home.idle"),
    ])
}

@Test("Validator treats an explicitly empty definition field as authored")
func validatorTreatsExplicitlyEmptyDefinitionFieldAsAuthored() throws {
    try withTemporaryDirectory { packageRoot in
        try Data(#"{"activityDefinitions":[]}"#.utf8).write(
            to: packageRoot.appendingPathComponent("world.json")
        )

        let findings = WorldPackageValidator().validate(
            makeManifest(activityDefinitions: []),
            packageRoot: packageRoot
        )

        #expect(findings == [
            .missingActivityDefinition(activityID: "window.gaze"),
        ])
    }
}

@Test("Validator rejects duplicate and orphan activity definitions")
func validatorRejectsDuplicateAndOrphanActivityDefinitions() {
    let manifest = makeManifest(
        activityDefinitions: [
            makeDefinition(),
            makeDefinition(),
            makeDefinition(id: "orphan.idle", activity: .idle),
        ]
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .duplicateActivityDefinition(activityID: "window.gaze"),
        .orphanActivityDefinition(activityID: "orphan.idle"),
    ])
}

@Test("Validator rejects an activity definition action mismatch")
func validatorRejectsActivityDefinitionActionMismatch() {
    let manifest = makeManifest(
        activityDefinitions: [makeDefinition(activity: .idle)]
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .activityDefinitionActionMismatch(
            activityID: "window.gaze",
            anchorAction: "gaze",
            definitionAction: "idle"
        ),
    ])
}

@Test("Validator requires a walk anchor to enter at its destination")
func validatorRejectsWalkDestinationMismatch() {
    let spawn = WorldWaypoint(
        id: "wp.spawn",
        position: .zero,
        arrivalRadius: 0.2,
        enabled: true
    )
    let center = WorldWaypoint(
        id: "wp.center",
        position: WorldVector3(x: 0, y: 0, z: 1),
        arrivalRadius: 0.2,
        enabled: true
    )
    let manifest = makeManifest(
        waypoints: [spawn, center],
        activities: [
            makeActivity(
                id: "home.walk",
                action: "walk",
                entryWaypointID: "wp.spawn"
            ),
        ],
        activityDefinitions: [
            makeDefinition(
                id: "home.walk",
                activity: .walk(destinationID: "wp.center")
            ),
        ],
        capabilities: [.activity("home.walk"), .camera("living.establishing")]
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .activityWalkDestinationMismatch(
            activityID: "home.walk",
            entryWaypointID: "wp.spawn",
            destinationWaypointID: "wp.center"
        ),
    ])
}

@Test("Validator reports missing then duplicate phases in stable order")
func validatorReportsMissingThenDuplicateActivityDefinitionPhases() {
    let phases = makeCompletePhases()
        .filter { $0.phase != .failed }
        + [ActivityPhaseContract(phase: .loop)]
    let manifest = makeManifest(
        activityDefinitions: [makeDefinition(phases: phases)]
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .missingActivityDefinitionPhase(
            activityID: "window.gaze",
            phase: .failed
        ),
        .duplicateActivityDefinitionPhase(
            activityID: "window.gaze",
            phase: .loop
        ),
    ])
}

@Test("Validator reports every missing route waypoint")
func validatorReportsMissingRouteWaypoint() {
    let manifest = makeManifest(
        routes: [
            WorldRoute(
                id: "route.window",
                waypointIDs: ["wp.spawn", "wp.missing"],
                bidirectional: true,
                enabled: true
            ),
        ]
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .missingRouteWaypoint(routeID: "route.window", waypointID: "wp.missing"),
    ])
}

@Test("Validator reports a missing activity entry waypoint")
func validatorReportsMissingActivityEntryWaypoint() {
    let manifest = makeManifest(
        activities: [makeActivity(entryWaypointID: "wp.missing")],
        capabilities: [.activity("window.gaze")]
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .missingActivityEntryWaypoint(
            activityID: "window.gaze",
            waypointID: "wp.missing"
        ),
    ])
}

@Test("Validator rejects an activity transform outside its entry tolerance")
func validatorRejectsActivityEntryTransformMismatch() {
    let activity = WorldActivityAnchor(
        id: "window.gaze",
        action: "gaze",
        entryWaypointID: "wp.spawn",
        transform: WorldTransform(
            position: WorldVector3(x: 0.2, y: 0, z: 0),
            rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
            scale: WorldVector3(x: 1, y: 1, z: 1)
        ),
        motionID: "gaze.window",
        propIDs: [],
        interruptible: true
    )
    let manifest = makeManifest(activities: [activity])

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .activityEntryTransformMismatch(
            activityID: "window.gaze",
            waypointID: "wp.spawn",
            distance: 0.2,
            maximumDistance: 0.08
        ),
    ])
}

@Test("Validator rejects invalid camera clipping planes")
func validatorRejectsInvalidCameraClippingPlanes() {
    let camera = makeCamera(nearPlane: 1, farPlane: 0.5)
    let manifest = makeManifest(
        cameras: [camera],
        capabilities: [.activity("window.gaze"), .camera(camera.id)]
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .invalidCameraPlanes(cameraID: camera.id, nearPlane: 1, farPlane: 0.5),
    ])
}

@Test("Validator rejects a resource path outside the package root")
func validatorRejectsEscapingResourcePath() throws {
    try withTemporaryDirectory { packageRoot in
        let manifest = makeManifest(
            resources: [
                WorldResource(
                    id: "world.visual",
                    path: "../outside.spz",
                    sha256: String(repeating: "0", count: 64),
                    kind: "spz"
                ),
            ]
        )

        let findings = WorldPackageValidator().validate(manifest, packageRoot: packageRoot)

        #expect(findings == [
            .resourcePathEscapesPackageRoot(
                resourceID: "world.visual",
                path: "../outside.spz"
            ),
        ])
    }
}

@Test("Validator rejects a resource SHA-256 mismatch")
func validatorRejectsResourceHashMismatch() throws {
    try withTemporaryDirectory { packageRoot in
        let resourceURL = packageRoot.appendingPathComponent("world.spz")
        try Data("hello".utf8).write(to: resourceURL)
        let expected = String(repeating: "0", count: 64)
        let manifest = makeManifest(
            resources: [
                WorldResource(
                    id: "world.visual",
                    path: "world.spz",
                    sha256: expected,
                    kind: "spz"
                ),
            ]
        )

        let findings = WorldPackageValidator().validate(manifest, packageRoot: packageRoot)

        #expect(findings == [
            .resourceSHA256Mismatch(
                resourceID: "world.visual",
                expected: expected,
                actual: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            ),
        ])
    }
}

@Test("Validator rejects an unsupported schema version")
func validatorRejectsUnsupportedSchemaVersion() {
    let manifest = makeManifest(schemaVersion: 2)

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .unsupportedSchemaVersion(found: 2, supported: [1]),
    ])
}

@Test("Validator rejects a capability without a matching anchor")
func validatorRejectsUnmatchedCapability() {
    let manifest = makeManifest(capabilities: [.activity("missing.activity")])

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .unmatchedCapability(capability: .activity("missing.activity")),
    ])
}

@Test("Validator returns all findings in stable validation order")
func validatorReturnsAllFindingsInStableOrder() {
    let duplicate = WorldWaypoint(
        id: "wp.spawn",
        position: .zero,
        arrivalRadius: 0.2,
        enabled: true
    )
    let manifest = makeManifest(
        schemaVersion: 2,
        waypoints: [duplicate, duplicate],
        routes: [
            WorldRoute(
                id: "route.invalid",
                waypointIDs: ["wp.z", "wp.a"],
                bidirectional: false,
                enabled: true
            ),
        ],
        activities: [makeActivity(entryWaypointID: "wp.missing")],
        capabilities: [.camera("camera.missing"), .activity("activity.missing")]
    )

    let findings = WorldPackageValidator().validate(
        manifest,
        packageRoot: FileManager.default.temporaryDirectory
    )

    #expect(findings == [
        .unsupportedSchemaVersion(found: 2, supported: [1]),
        .duplicateID(collection: "waypoints", id: "wp.spawn"),
        .missingRouteWaypoint(routeID: "route.invalid", waypointID: "wp.a"),
        .missingRouteWaypoint(routeID: "route.invalid", waypointID: "wp.z"),
        .missingActivityEntryWaypoint(
            activityID: "window.gaze",
            waypointID: "wp.missing"
        ),
        .unmatchedCapability(capability: .activity("activity.missing")),
        .unmatchedCapability(capability: .camera("camera.missing")),
    ])
}

@Test("Validator finding order does not depend on manifest input order")
func validatorFindingOrderIsIndependentOfInputOrder() {
    let nearBeyondFar = makeCamera(nearPlane: 2, farPlane: 1)
    let negativeNear = makeCamera(nearPlane: -1, farPlane: 100)
    let forward = makeManifest(
        cameras: [nearBeyondFar, negativeNear],
        capabilities: [.activity("window.gaze")]
    )
    let reverse = makeManifest(
        cameras: [negativeNear, nearBeyondFar],
        capabilities: [.activity("window.gaze")]
    )
    let validator = WorldPackageValidator()
    let packageRoot = FileManager.default.temporaryDirectory

    #expect(
        validator.validate(forward, packageRoot: packageRoot)
            == validator.validate(reverse, packageRoot: packageRoot)
    )
}

private func makeManifest(
    schemaVersion: Int = 1,
    calibration: WorldCalibration = WorldCalibration(
        visualToGameplay: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ],
        metersPerUnit: 1
    ),
    collisionVolumes: [WorldCollisionVolume] = [],
    waypoints: [WorldWaypoint] = [
        WorldWaypoint(
            id: "wp.spawn",
            position: .zero,
            arrivalRadius: 0.2,
            enabled: true
        ),
    ],
    routes: [WorldRoute] = [],
    activities: [WorldActivityAnchor] = [makeActivity()],
    activityDefinitions: [LifeActivityDefinition] = [],
    cameras: [WorldCameraAnchor] = [makeCamera()],
    capabilities: Set<WorldCapability> = [
        .activity("window.gaze"),
        .camera("living.establishing"),
    ],
    resources: [WorldResource] = []
) -> WorldManifest {
    WorldManifest(
        schemaVersion: schemaVersion,
        packageID: "warm-kitchen-canary",
        packageVersion: "1.0.0",
        worldID: "world-labs-example-warm-kitchen",
        displayName: "Warm Kitchen",
        calibration: calibration,
        spawn: .identity,
        collisionVolumes: collisionVolumes,
        waypoints: waypoints,
        routes: routes,
        activities: activities,
        activityDefinitions: activityDefinitions,
        cameras: cameras,
        capabilities: capabilities,
        resources: resources
    )
}

private func makeActivity(
    id: String = "window.gaze",
    action: String = "gaze",
    entryWaypointID: String = "wp.spawn",
    propIDs: [String] = []
) -> WorldActivityAnchor {
    WorldActivityAnchor(
        id: id,
        action: action,
        entryWaypointID: entryWaypointID,
        transform: .identity,
        motionID: "gaze.window",
        propIDs: propIDs,
        interruptible: true
    )
}

private func makeDefinition(
    id: String = "window.gaze",
    activity: LifeActivity = .gaze(targetID: "window.gaze"),
    phases: [ActivityPhaseContract] = makeCompletePhases()
) -> LifeActivityDefinition {
    LifeActivityDefinition(
        id: id,
        activity: activity,
        phases: phases,
        interruptible: true,
        cooldownSeconds: 0
    )
}

private func makeCompletePhases() -> [ActivityPhaseContract] {
    LifeActivityPhase.allCases.map { ActivityPhaseContract(phase: $0) }
}

private func makeCamera(
    id: String = "living.establishing",
    nearPlane: Float = 0.05,
    farPlane: Float = 100
) -> WorldCameraAnchor {
    WorldCameraAnchor(
        id: id,
        transform: .identity,
        fieldOfViewDegrees: 50,
        nearPlane: nearPlane,
        farPlane: farPlane
    )
}

private func withTemporaryDirectory(
    _ body: (URL) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private extension WorldVector3 {
    static let zero = WorldVector3(x: 0, y: 0, z: 0)
    static let one = WorldVector3(x: 1, y: 1, z: 1)
}

private extension WorldQuaternion {
    static let identity = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
}

private extension WorldTransform {
    static let identity = WorldTransform(
        position: .zero,
        rotation: .identity,
        scale: .one
    )
}
