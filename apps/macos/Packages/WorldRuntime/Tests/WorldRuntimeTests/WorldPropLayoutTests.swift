import Foundation
import Testing
@testable import WorldRuntime

private func layoutSimulation() -> WorldSimulation {
    WorldSimulation(restoring: WorldState(revision: 0, worldID: "room", worldTime: .distantPast,
        lastObservedWallTime: .distantPast, weather: .clear,
        agentTransform: WorldTransform(position: .init(x: 0,y: 0,z: 0),rotation: .init(x: 0,y: 0,z: 0,w: 1),scale: .init(x: 1,y: 1,z: 1))))
}
private let coffee = WorldGeneratedProp(objectID: "wish.object.1", sourceWishID: "wish1", assetID: "asset1", displayName: "咖啡机", size: .init(x: 0.3,y: 0.42,z: 0.4), sourceHeight: 2)

@Test func generatedLayoutRejectsLowMeshCornerWhichCapsuleMisses() {
    let box=WorldCollisionVolume(id:"box",center:.init(x:0,y:0.21,z:0),halfExtents:.init(x:0.2,y:0.21,z:0.2),rotation:.init(x:0,y:0,z:0,w:1),isBlocking:true)
    let bump=WorldTriangle(SIMD3(0.19,0.01,-0.01),SIMD3(0.19,0.02,-0.01),SIMD3(0.19,0.02,0.01))
    let mesh=TriangleMeshCollisionWorld(triangles:[bump])
    let radius:Float=sqrt(0.08)
    #expect(mesh.canOccupy(.init(radius:radius,height:0.42+radius*2),at:.zero))
    #expect(!WorldPropMeshClearance.canPlace(box,supportHeight:0,triangles:[bump]))
    let floor=WorldTriangle(SIMD3(-2,0,-2),SIMD3(2,0,-2),SIMD3(0,0,2))
    #expect(WorldPropMeshClearance.canPlace(box,supportHeight:0,triangles:[floor]))
    let crossing=WorldTriangle(SIMD3(0.1,-1,0),SIMD3(0.1,1,0),SIMD3(0.1,0.1,0.1))
    #expect(!WorldPropMeshClearance.canPlace(box,supportHeight:0,triangles:[crossing]))
    let outside=WorldTriangle(SIMD3(3,0,3),SIMD3(3,1,3),SIMD3(3,1,4))
    #expect(WorldPropMeshClearance.canPlace(box,supportHeight:0,triangles:[outside]))
}

@Test func generatedLayoutIsVersionedIdempotentAndRecoverable() throws {
    var sim = layoutSimulation()
    try sim.applyPropLayout(.register(coffee), expectedLayoutRevision: 0, requestID: "import")
    #expect(sim.state.objectStates[coffee.objectID]?.isEnabled == false)
    #expect(sim.state.objectStates[coffee.objectID]?.generatedProp == coffee)
    let imported = sim.state
    try sim.applyPropLayout(.register(coffee), expectedLayoutRevision: 0, requestID: "import")
    #expect(sim.state == imported)
    try sim.advance(by: 1, expectedRevision: sim.state.revision)
    let placement = WorldPropPlacement(surfaceID: "floor", position: .init(x: 2,y: 0,z: 3), yaw: .pi/2)
    try sim.applyPropLayout(.place(objectID: coffee.objectID, placement: placement), expectedLayoutRevision: 1, requestID: "place")
    #expect(sim.state.layoutRevision == 2)
    #expect(sim.state.objectStates[coffee.objectID]?.transform.scale.x == 0.21)
    let placed = sim.state.objectStates[coffee.objectID]
    #expect(throws: WorldPropLayoutError.self) { try sim.applyPropLayout(.withdraw(objectID: coffee.objectID),expectedLayoutRevision: 1,requestID: "stale") }
    try sim.applyPropLayout(.withdraw(objectID: coffee.objectID),expectedLayoutRevision: 2,requestID: "remove")
    #expect(sim.state.objectStates[coffee.objectID]?.isEnabled == false)
    var restored = WorldSimulation(restoring: try JSONDecoder().decode(WorldState.self, from: JSONEncoder().encode(sim.state)))
    try restored.applyPropLayout(.undo, expectedLayoutRevision: 3, requestID: "undo")
    #expect(restored.state.objectStates[coffee.objectID] == placed)
    #expect(throws: WorldPropLayoutError.self) { try restored.applyPropLayout(.undo,expectedLayoutRevision: 4,requestID: "undo2") }
    #expect(throws: WorldPropLayoutError.self) { try restored.applyPropLayout(.withdraw(objectID: "background"),expectedLayoutRevision: 4,requestID: "bad") }
    #expect(throws: WorldPropLayoutError.self) { try restored.applyPropLayout(.withdraw(objectID: coffee.objectID),expectedLayoutRevision: 4,requestID: "place") }
}

@Test func generatedLayoutDuplicateImportBindsRequestAndAllowsManyVisibleItems() throws {
    var sim=layoutSimulation()
    try sim.applyPropLayout(.register(coffee),expectedLayoutRevision:0,requestID:"first")
    try sim.applyPropLayout(.register(coffee),expectedLayoutRevision:1,requestID:"duplicate")
    #expect(throws: WorldPropLayoutError.self) { try sim.applyPropLayout(.withdraw(objectID:coffee.objectID),expectedLayoutRevision:1,requestID:"duplicate") }
    for i in 2...5 {
        let prop=WorldGeneratedProp(objectID:"prop\(i)",sourceWishID:"wish\(i)",assetID:"asset\(i)",displayName:"item",size:.init(x:0.2,y:0.2,z:0.2),sourceHeight:1)
        try sim.applyPropLayout(.register(prop),expectedLayoutRevision:sim.state.layoutRevision,requestID:"r\(i)")
        try sim.applyPropLayout(.place(objectID:prop.objectID,placement:.init(surfaceID:"floor",position:.init(x:Float(i),y:0,z:2),yaw:0)),expectedLayoutRevision:sim.state.layoutRevision,requestID:"p\(i)")
    }
    // 不再有件数上限：第 5 件必须成功，而不是被拒绝或被静默丢弃。
    try sim.applyPropLayout(.place(objectID:coffee.objectID,placement:.init(surfaceID:"floor",position:.init(x:0,y:0,z:2),yaw:0)),expectedLayoutRevision:sim.state.layoutRevision,requestID:"fifth")
    #expect(sim.state.objectStates[coffee.objectID]?.isEnabled == true)
    #expect(sim.state.objectStates.values.filter { $0.isEnabled && $0.generatedProp != nil }.count == 5)
}

@Test func generatedLayoutKeepsAbsoluteScaleAndRejectsCorruptMetadata() throws {
    var sim=layoutSimulation()
    try sim.applyPropLayout(.register(coffee),expectedLayoutRevision:0,requestID:"import")
    for i in 0..<10 {
        try sim.applyPropLayout(.place(objectID:coffee.objectID,placement:.init(surfaceID:"table",position:.init(x:2,y:0.8,z:1),yaw:Float(i)*0.25)),expectedLayoutRevision:sim.state.layoutRevision,requestID:"rotation\(i)")
        #expect(sim.state.objectStates[coffee.objectID]?.transform.scale == .init(x:0.21,y:0.21,z:0.21))
    }
    let before=sim.state
    try sim.applyPropLayout(.place(objectID:coffee.objectID,placement:.init(surfaceID:"table",position:.init(x:2,y:0.8,z:1),yaw:0)),expectedLayoutRevision:1,requestID:"rotation0")
    #expect(sim.state==before, "A replay of an old placement cannot undo newer rotations")
    #expect(throws: WorldPropLayoutError.invalidPlacement) {
        try sim.applyPropLayout(.place(objectID:coffee.objectID,placement:.init(surfaceID:"table",position:.init(x:.nan,y:0,z:0),yaw:0)),expectedLayoutRevision:sim.state.layoutRevision,requestID:"nan")
    }
    #expect(sim.state==before)
    var corrupt=sim.state
    corrupt.objectStates[coffee.objectID]?.metadata["gmgn.generated-prop.v1"]="broken"
    sim=WorldSimulation(restoring:corrupt)
    #expect(sim.state.objectStates[coffee.objectID]?.generatedProp == nil)
    #expect(throws: WorldPropLayoutError.invalidObject) { try sim.applyPropLayout(.register(coffee),expectedLayoutRevision:sim.state.layoutRevision,requestID:"replace-corrupt") }
    #expect(throws: WorldPropLayoutError.invalidObject) { try sim.applyPropLayout(.withdraw(objectID:coffee.objectID),expectedLayoutRevision:sim.state.layoutRevision,requestID:"withdraw-corrupt") }
    #expect(throws: WorldPropLayoutError.invalidObject) { try sim.applyPropLayout(.place(objectID:coffee.objectID,placement:.init(surfaceID:"table",position:.init(x:2,y:0.8,z:1),yaw:0)),expectedLayoutRevision:sim.state.layoutRevision,requestID:"place-corrupt") }
}

@Test func generatedLayoutDecodesLegacyStateWithoutLayoutFields() throws {
    let old=layoutSimulation().state
    var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any]
    json.removeValue(forKey:"layoutRevision");json.removeValue(forKey:"layoutReceipts");json.removeValue(forKey:"layoutUndo")
    let restored=try JSONDecoder().decode(WorldState.self,from:JSONSerialization.data(withJSONObject:json))
    #expect(restored.layoutRevision==0 && restored.layoutReceipts.isEmpty && restored.layoutUndo==nil)
    #expect(restored.objectStates==old.objectStates && restored.agentTransform==old.agentTransform)
}

@Test func generatedLayoutRejectsOverflowedAbsoluteScale() throws {
    let bad=WorldGeneratedProp(objectID:"bad",sourceWishID:"bad-wish",assetID:"bad-asset",displayName:"bad",size:.init(x:0.2,y:0.42,z:0.2),sourceHeight:.leastNonzeroMagnitude)
    #expect(!bad.isValid)
    var sim=layoutSimulation()
    #expect(throws: WorldPropLayoutError.invalidObject) { try sim.applyPropLayout(.register(bad),expectedLayoutRevision:0,requestID:"bad-scale") }
}

private let rightHandGrip = WorldPropGripCalibration(
    avatarAssetID: "avatar.2b",
    hand: .rightHand,
    normalizedGrip: .init(x: 0.5, y: 0.2, z: 0.5),
    localOffset: .init(x: 0.01, y: -0.02, z: 0.03),
    localRotation: .init(x: 0, y: 0, z: 0, w: 1)
)

@Test func generatedPropHoldingPreservesFootprintAndRestoresPlacement() throws {
    var sim = layoutSimulation()
    try sim.applyPropLayout(.register(coffee), expectedLayoutRevision: 0, requestID: "import")
    let placement = WorldPropPlacement(
        surfaceID: "display-table",
        position: .init(x: 1.2, y: 0.52, z: -2.4),
        yaw: .pi / 3
    )
    try sim.applyPropLayout(.place(objectID: coffee.objectID, placement: placement), expectedLayoutRevision: 1, requestID: "place")
    let placed = try #require(sim.state.objectStates[coffee.objectID])

    try sim.applyPropLayout(.hold(objectID: coffee.objectID, avatarAssetID: "avatar.2b", calibration: rightHandGrip), expectedLayoutRevision: 2, requestID: "hold")
    let held = try #require(sim.state.heldProp)
    #expect(held.objectID == coffee.objectID)
    #expect(held.avatarAssetID == "avatar.2b")
    #expect(held.hand == .rightHand)
    #expect(held.returnState.isEnabled == placed.isEnabled)
    #expect(held.returnState.transform == placed.transform)
    #expect(held.returnState.supportSurfaceID == placed.supportSurfaceID)
    #expect(held.returnState.gripCalibration == rightHandGrip)
    #expect(sim.state.objectStates[coffee.objectID]?.isEnabled == false)
    #expect(sim.state.objectStates[coffee.objectID]?.transform == placed.transform)
    #expect(sim.state.objectStates[coffee.objectID]?.supportSurfaceID == "display-table")
    #expect(throws: WorldPropLayoutError.objectIsHeld(objectID: coffee.objectID)) {
        try sim.applyPropLayout(.place(objectID: coffee.objectID, placement: placement), expectedLayoutRevision: 3, requestID: "place-held")
    }
    #expect(throws: WorldPropLayoutError.objectIsHeld(objectID: coffee.objectID)) {
        try sim.applyPropLayout(.withdraw(objectID: coffee.objectID), expectedLayoutRevision: 3, requestID: "withdraw-held")
    }

    try sim.applyPropLayout(.adjustGrip(objectID: coffee.objectID, avatarAssetID: "avatar.2b", calibration: rightHandGrip), expectedLayoutRevision: 3, requestID: "adjust")
    #expect(sim.state.objectStates[coffee.objectID]?.gripCalibration == rightHandGrip)
    #expect(sim.state.heldProp?.returnState.gripCalibration == rightHandGrip)
    let adjustedHeld = sim.state.heldProp

    let encoded = try JSONEncoder().encode(sim.state)
    sim = WorldSimulation(restoring: try JSONDecoder().decode(WorldState.self, from: encoded))
    #expect(sim.state.heldProp == adjustedHeld)

    try sim.applyPropLayout(.returnHeld(objectID: coffee.objectID, avatarAssetID: "avatar.2b"), expectedLayoutRevision: 4, requestID: "return")
    #expect(sim.state.heldProp == nil)
    #expect(sim.state.objectStates[coffee.objectID]?.isEnabled == true)
    #expect(sim.state.objectStates[coffee.objectID]?.transform == placed.transform)
    #expect(sim.state.objectStates[coffee.objectID]?.supportSurfaceID == "display-table")
    #expect(sim.state.objectStates[coffee.objectID]?.gripCalibration == rightHandGrip)
    #expect(sim.state.layoutUndo == nil)
    #expect(throws: WorldPropLayoutError.nothingToUndo) {
        try sim.applyPropLayout(.undo, expectedLayoutRevision: 5, requestID: "undo-return")
    }
}

@Test func generatedPropHoldingReturnsInventoryItemsWithoutUndoingTheAttachment() throws {
    var sim = layoutSimulation()
    try sim.applyPropLayout(.register(coffee), expectedLayoutRevision: 0, requestID: "import")
    let inventoryState = try #require(sim.state.objectStates[coffee.objectID])
    try sim.applyPropLayout(.hold(objectID: coffee.objectID, avatarAssetID: "avatar.2b", calibration: rightHandGrip), expectedLayoutRevision: 1, requestID: "hold")
    #expect(sim.state.objectStates[coffee.objectID]?.isEnabled == false)
    try sim.applyPropLayout(.returnHeld(objectID: coffee.objectID, avatarAssetID: "avatar.2b"), expectedLayoutRevision: 2, requestID: "return")
    #expect(sim.state.heldProp == nil)
    #expect(sim.state.objectStates[coffee.objectID]?.isEnabled == inventoryState.isEnabled)
    #expect(sim.state.objectStates[coffee.objectID]?.transform == inventoryState.transform)
    #expect(sim.state.objectStates[coffee.objectID]?.supportSurfaceID == inventoryState.supportSurfaceID)
    #expect(sim.state.objectStates[coffee.objectID]?.gripCalibration == rightHandGrip)

    #expect(throws: WorldPropLayoutError.nothingToUndo) {
        try sim.applyPropLayout(.undo, expectedLayoutRevision: 3, requestID: "undo-return")
    }
}

@Test func holdingRejectsUndoAndReturningCannotRestoreAnAttachmentThroughUndo() throws {
    var sim = layoutSimulation()
    try sim.applyPropLayout(.register(coffee), expectedLayoutRevision: 0, requestID: "import")
    try sim.applyPropLayout(
        .place(objectID: coffee.objectID, placement: .init(surfaceID: "floor", position: .init(x: 1, y: 0, z: 1), yaw: 0)),
        expectedLayoutRevision: 1,
        requestID: "place"
    )
    #expect(sim.state.layoutUndo != nil)
    try sim.applyPropLayout(.hold(objectID: coffee.objectID, avatarAssetID: "avatar.2b", calibration: rightHandGrip), expectedLayoutRevision: 2, requestID: "hold")
    #expect(sim.state.layoutUndo == nil)
    let held = sim.state
    #expect(throws: WorldPropLayoutError.objectIsHeld(objectID: coffee.objectID)) {
        try sim.applyPropLayout(.undo, expectedLayoutRevision: 3, requestID: "undo-hold")
    }
    #expect(sim.state == held)
    try sim.applyPropLayout(.returnHeld(objectID: coffee.objectID, avatarAssetID: "avatar.2b"), expectedLayoutRevision: 3, requestID: "return")
    #expect(sim.state.heldProp == nil)
    #expect(sim.state.layoutUndo == nil)
    #expect(throws: WorldPropLayoutError.nothingToUndo) {
        try sim.applyPropLayout(.undo, expectedLayoutRevision: 4, requestID: "undo-after-return")
    }
}

@Test func generatedPropHoldingRejectsConflictsAndInvalidGripWithoutMutation() throws {
    var sim = layoutSimulation()
    try sim.applyPropLayout(.register(coffee), expectedLayoutRevision: 0, requestID: "import")
    try sim.startActivity("music.listen", expectedRevision: sim.state.revision)
    let active = sim.state
    #expect(throws: WorldPropLayoutError.activeActivityConflict(activityID: "music.listen")) {
        try sim.applyPropLayout(.hold(objectID: coffee.objectID, avatarAssetID: "avatar.2b", calibration: rightHandGrip), expectedLayoutRevision: 1, requestID: "hold-during-activity")
    }
    #expect(sim.state == active)
    try sim.cancelActivity(expectedRevision: sim.state.revision)
    try sim.applyPropLayout(.hold(objectID: coffee.objectID, avatarAssetID: "avatar.2b", calibration: rightHandGrip), expectedLayoutRevision: 1, requestID: "hold")
    let held = sim.state

    #expect(throws: WorldPropLayoutError.heldPropAlreadyExists(objectID: coffee.objectID)) {
        try sim.applyPropLayout(.hold(objectID: coffee.objectID, avatarAssetID: "avatar.other", calibration: rightHandGrip), expectedLayoutRevision: 2, requestID: "other-hold")
    }
    #expect(throws: WorldPropLayoutError.heldPropMismatch) {
        try sim.applyPropLayout(.returnHeld(objectID: coffee.objectID, avatarAssetID: "avatar.other"), expectedLayoutRevision: 2, requestID: "wrong-return")
    }
    #expect(throws: WorldPropLayoutError.heldPropMismatch) {
        try sim.applyPropLayout(.adjustGrip(objectID: coffee.objectID, avatarAssetID: "avatar.other", calibration: rightHandGrip), expectedLayoutRevision: 2, requestID: "late-adjust")
    }
    let invalidGrip = WorldPropGripCalibration(
        avatarAssetID: "avatar.2b",
        hand: .rightHand,
        normalizedGrip: .init(x: 1.1, y: 0.2, z: 0.5),
        localOffset: .init(x: 0, y: 0, z: 0),
        localRotation: .init(x: 0, y: 0, z: 0, w: 1)
    )
    #expect(throws: WorldPropLayoutError.invalidGripCalibration) {
        try sim.applyPropLayout(.adjustGrip(objectID: coffee.objectID, avatarAssetID: "avatar.2b", calibration: invalidGrip), expectedLayoutRevision: 2, requestID: "bad-grip")
    }
    #expect(sim.state == held)
    #expect(throws: WorldSimulationError.propIsHeld(objectID: coffee.objectID)) {
        try sim.startActivity("music.listen", expectedRevision: sim.state.revision)
    }
}

@Test func generatedPropHoldingCountsAgainstVisibleLimitAndRemainsIdempotent() throws {
    var sim = layoutSimulation()
    try sim.applyPropLayout(.register(coffee), expectedLayoutRevision: 0, requestID: "coffee-import")
    try sim.applyPropLayout(.hold(objectID: coffee.objectID, avatarAssetID: "avatar.2b", calibration: rightHandGrip), expectedLayoutRevision: 1, requestID: "coffee-hold")
    let held = sim.state
    try sim.applyPropLayout(.hold(objectID: coffee.objectID, avatarAssetID: "avatar.2b", calibration: rightHandGrip), expectedLayoutRevision: 1, requestID: "coffee-hold")
    #expect(sim.state == held)
    for i in 2...5 {
        let prop = WorldGeneratedProp(objectID: "prop\(i)", sourceWishID: "wish\(i)", assetID: "asset\(i)", displayName: "item", size: .init(x: 0.2, y: 0.2, z: 0.2), sourceHeight: 1)
        try sim.applyPropLayout(.register(prop), expectedLayoutRevision: sim.state.layoutRevision, requestID: "r\(i)")
        // 手持中的物件与已摆放物件各自计数，不再互相挤占名额。
        try sim.applyPropLayout(
            .place(objectID: prop.objectID, placement: .init(surfaceID: "floor", position: .init(x: Float(i), y: 0, z: 2), yaw: 0)),
            expectedLayoutRevision: sim.state.layoutRevision,
            requestID: "p\(i)"
        )
    }
    #expect(throws: WorldPropLayoutError.requestConflict) {
        try sim.applyPropLayout(.returnHeld(objectID: coffee.objectID, avatarAssetID: "avatar.2b"), expectedLayoutRevision: sim.state.layoutRevision, requestID: "coffee-hold")
    }
}

@Test func generatedPropHoldingDecodesLegacyStateAndErrorsAreLocalized() throws {
    let current = layoutSimulation().state
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as! [String: Any]
    json.removeValue(forKey: "heldProp")
    let restored = try JSONDecoder().decode(WorldState.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.heldProp == nil)

    let errors: [WorldPropLayoutError] = [
        .heldPropAlreadyExists(objectID: "prop"), .objectIsHeld(objectID: "prop"),
        .heldPropMismatch, .activeActivityConflict(activityID: "music.listen"), .invalidGripCalibration,
    ]
    for error in errors {
        #expect(error.errorDescription?.contains("物件") == true || error.errorDescription?.contains("活动") == true || error.errorDescription?.contains("握持") == true)
    }
    #expect(WorldSimulationError.propIsHeld(objectID: "prop").errorDescription?.contains("手持") == true)
}

@Test func generatedLayoutPlacesThirtyItemsAndPersistsThem() throws {
    // 装修的验收：不设件数上限。放下 30 件后全部可见，并且能原样存档、原样恢复。
    // 这条取代了原来的"第四件上限"语义，也钉住了"渲染预算不得变成不许放"。
    var sim = layoutSimulation()
    for i in 0..<30 {
        let prop = WorldGeneratedProp(
            objectID: "prop\(i)", sourceWishID: "wish\(i)", assetID: "asset\(i)",
            displayName: "item\(i)", size: .init(x: 0.2, y: 0.2, z: 0.2), sourceHeight: 1
        )
        try sim.applyPropLayout(.register(prop), expectedLayoutRevision: sim.state.layoutRevision, requestID: "r\(i)")
        try sim.applyPropLayout(
            .place(objectID: prop.objectID,
                   placement: .init(surfaceID: "floor",
                                    position: .init(x: Float(i % 10), y: 0, z: Float(i / 10)),
                                    yaw: Float(i) * 0.1)),
            expectedLayoutRevision: sim.state.layoutRevision,
            requestID: "p\(i)"
        )
    }
    let visible = sim.state.objectStates.values.filter { $0.isEnabled && $0.generatedProp != nil }
    #expect(visible.count == 30, "no placement cap: all thirty items stay visible")
    #expect(visible.compactMap { $0.generatedProp?.objectID }.count == 30)

    // 原子 JSON 存档往返后仍然全部在位，且位置/朝向逐一相同。
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-thirty-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let persistence = AtomicJSONWorldStatePersistence(fileURL: url)
    try persistence.save(sim.state)
    let loaded = try persistence.load()
    let restored = try #require(loaded)
    let restoredVisible = restored.objectStates.values.filter { $0.isEnabled && $0.generatedProp != nil }
    #expect(restoredVisible.count == 30)
    for (id, item) in sim.state.objectStates {
        #expect(restored.objectStates[id]?.transform == item.transform, "\(id) keeps its placement across a reload")
    }
}
