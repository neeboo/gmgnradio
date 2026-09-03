import Foundation
import Testing
@testable import WorldRuntime

@Test("Gaze activities navigate to their authored target before looking")
func gazeUsesItsTargetAsTheApproachDestination() {
    #expect(
        LifeActivity.gaze(targetID: "wp.window").approachTargetID
            == "wp.window"
    )
}

@Test("Interaction activities navigate to their authored anchor")
func interactionUsesItsAnchorAsTheApproachDestination() {
    #expect(
        LifeActivity.interact(anchorID: "coffee.brew").approachTargetID
            == "coffee.brew"
    )
    #expect(LifeActivity.interact(anchorID: "coffee.brew").typeID == "interact")
}

@Test("Authored activity display names survive package encoding")
func authoredActivityDisplayNamesRoundTrip() throws {
    let definition = LifeActivityDefinition(
        id: "kitchen.walk",
        displayName: "走到厨房操作台",
        activity: .walk(destinationID: "wp.kitchen.counter"),
        phases: LifeActivityPhase.allCases.map { ActivityPhaseContract(phase: $0) },
        interruptible: true,
        cooldownSeconds: 0
    )

    let data = try JSONEncoder().encode(definition)
    let decoded = try JSONDecoder().decode(LifeActivityDefinition.self, from: data)

    #expect(decoded.displayName == "走到厨房操作台")
}

@Test("Life activity payloads decode every supported living action")
func lifeActivityPayloadsDecodeEverySupportedAction() throws {
    let fixture = Data(
        """
        [
          {"type":"idle"},
          {"type":"walk","destinationID":"wp.window"},
          {"type":"turn","targetYaw":1.5707963},
          {"type":"sit","anchorID":"chair.window"},
          {"type":"gaze","targetID":"window.rain"},
          {"type":"listenMusic","anchorID":"sofa.music"},
          {"type":"interact","anchorID":"coffee.brew"}
        ]
        """.utf8
    )

    let activities = try JSONDecoder().decode([LifeActivity].self, from: fixture)

    #expect(activities == [
        .idle,
        .walk(destinationID: "wp.window"),
        .turn(targetYaw: 1.5707963),
        .sit(anchorID: "chair.window"),
        .gaze(targetID: "window.rain"),
        .listenMusic(anchorID: "sofa.music"),
        .interact(anchorID: "coffee.brew"),
    ])
}

@Test("Activity definitions decode an omitted cooldown as zero for compatibility")
func activityDefinitionDefaultsAnOmittedCooldown() throws {
    let phasePayload = LifeActivityPhase.allCases
        .map { "{\"phase\":\"\($0.rawValue)\"}" }
        .joined(separator: ",")
    let fixture = Data(
        """
        {
          "id": "home.idle",
          "activity": {"type": "idle"},
          "phases": [\(phasePayload)],
          "interruptible": true
        }
        """.utf8
    )

    let definition = try JSONDecoder().decode(LifeActivityDefinition.self, from: fixture)

    #expect(definition.cooldownSeconds == 0)
}

@Test("Activity phases cover the complete approach-to-failure lifecycle")
func activityPhasesCoverCompleteLifecycle() {
    #expect(Set(LifeActivityPhase.allCases) == [
        .approach,
        .enter,
        .loop,
        .exit,
        .interrupt,
        .failed,
    ])
}

@Test("Catalog accepts a complete activity definition")
func catalogAcceptsCompleteActivityDefinition() throws {
    let definition = makeDefinition()

    let catalog = try ActivityCatalog(definitions: [definition])

    #expect(catalog.definition(id: definition.id) == definition)
    #expect(catalog.definitions(for: .sit(anchorID: "chair.window")) == [definition])
}

@Test("Catalog rejects missing phase contracts")
func catalogRejectsMissingPhaseContracts() {
    let incomplete = makeDefinition(
        phases: LifeActivityPhase.allCases
            .filter { $0 != .failed }
            .map { ActivityPhaseContract(phase: $0) }
    )

    #expect(throws: ActivityCatalogError.missingPhase(
        activityID: incomplete.id,
        phase: .failed
    )) {
        try ActivityCatalog(definitions: [incomplete])
    }
}

@Test("Catalog rejects duplicate phase contracts")
func catalogRejectsDuplicatePhaseContracts() {
    var phases = LifeActivityPhase.allCases.map { ActivityPhaseContract(phase: $0) }
    phases.append(ActivityPhaseContract(phase: .loop, motionIDs: ["sit.loop.alt"]))
    let duplicate = makeDefinition(phases: phases)

    #expect(throws: ActivityCatalogError.duplicatePhase(
        activityID: duplicate.id,
        phase: .loop
    )) {
        try ActivityCatalog(definitions: [duplicate])
    }
}

@Test("Catalog preserves required anchors, motions, and props per phase")
func catalogPreservesPhaseRequirements() throws {
    let loop = ActivityPhaseContract(
        phase: .loop,
        requiredAnchorIDs: ["chair.window"],
        motionIDs: ["sit.loop"],
        propIDs: ["book.blue"]
    )
    let definition = makeDefinition(
        phases: LifeActivityPhase.allCases.map { phase in
            phase == .loop ? loop : ActivityPhaseContract(phase: phase)
        }
    )

    let catalog = try ActivityCatalog(definitions: [definition])

    #expect(catalog.definition(id: definition.id)?.contract(for: .loop) == loop)
}

@Test("Catalog builds directly from self-contained world definitions")
func catalogBuildsFromSelfContainedWorldDefinitions() throws {
    let definition = makeDefinition()
    let manifest = makeManifest(
        activities: [makeAnchor(id: definition.id, action: "sit")],
        activityDefinitions: [definition]
    )

    let catalog = try ActivityCatalog(manifest: manifest)

    #expect(catalog.definition(id: definition.id) == definition)
}

@Test("Catalog rejects an authored action that disagrees with its definition")
func catalogRejectsActionDefinitionMismatch() {
    let definition = makeDefinition()
    let manifest = makeManifest(
        activities: [makeAnchor(id: definition.id, action: "listenMusic")],
        activityDefinitions: [definition]
    )

    #expect(throws: ActivityCatalogError.actionMismatch(
        activityID: definition.id,
        anchorAction: "listenMusic",
        definitionAction: "sit"
    )) {
        try ActivityCatalog(manifest: manifest)
    }
}

@Test("Catalog synthesizes legacy definitions when the optional manifest field is absent")
func catalogSynthesizesLegacyDefinitions() throws {
    let anchor = makeAnchor(id: "music.listen", action: "listen-to-music")
    let manifest = makeManifest(activities: [anchor], activityDefinitions: [])

    let catalog = try ActivityCatalog(manifest: manifest)

    let definition = try #require(catalog.definition(id: anchor.id))
    #expect(definition.activity == .listenMusic(anchorID: anchor.id))
    #expect(definition.phases.count == LifeActivityPhase.allCases.count)
    #expect(definition.contract(for: .loop)?.motionIDs == ["motion.loop"])
}

private func makeDefinition(
    phases: [ActivityPhaseContract] = LifeActivityPhase.allCases.map {
        ActivityPhaseContract(phase: $0)
    }
) -> LifeActivityDefinition {
    LifeActivityDefinition(
        id: "sit.window-chair",
        activity: .sit(anchorID: "chair.window"),
        phases: phases,
        interruptible: true,
        cooldownSeconds: 30
    )
}

private func makeAnchor(id: String, action: String) -> WorldActivityAnchor {
    WorldActivityAnchor(
        id: id,
        action: action,
        entryWaypointID: "wp.entry",
        transform: testIdentityTransform,
        motionID: "motion.loop",
        propIDs: ["prop.one"],
        interruptible: true
    )
}

private func makeManifest(
    activities: [WorldActivityAnchor],
    activityDefinitions: [LifeActivityDefinition]
) -> WorldManifest {
    WorldManifest(
        schemaVersion: 1,
        packageID: "test-world",
        packageVersion: "1.0.0",
        worldID: "world.test",
        displayName: "Test World",
        calibration: WorldCalibration(visualToGameplay: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ], metersPerUnit: 1),
        spawn: testIdentityTransform,
        collisionVolumes: [],
        waypoints: [],
        routes: [],
        activities: activities,
        activityDefinitions: activityDefinitions,
        cameras: [],
        capabilities: [],
        resources: []
    )
}

private let testIdentityTransform = WorldTransform(
    position: WorldVector3(x: 0, y: 0, z: 0),
    rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
    scale: WorldVector3(x: 1, y: 1, z: 1)
)
