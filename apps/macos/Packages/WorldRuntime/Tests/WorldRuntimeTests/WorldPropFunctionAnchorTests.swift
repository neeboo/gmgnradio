import Foundation
import Testing
@testable import WorldRuntime

// 「物品上的功能点」的判据：声明是局部的，世界锚点是派生的，注册表是纯值。

private func point(
    _ role: String,
    _ kind: WorldPropFunctionPoint.Kind,
    _ position: WorldVector3,
    yaw: Float? = nil,
    activityID: String? = nil
) -> WorldPropFunctionPoint {
    WorldPropFunctionPoint(
        role: role, kind: kind, position: position, yaw: yaw, activityID: activityID
    )
}

private let wishLikeDeclaration = WorldPropFunctionPointDeclaration(
    objectID: "machine.device",
    functionPoints: [
        point("pickup", .standingSpot, WorldVector3(x: 0, y: -0.019, z: -0.95),
              activityID: "machine.collect"),
        point("outlet", .emitter, WorldVector3(x: 0, y: 0.75, z: 0)),
        point("interact", .interaction, WorldVector3(x: 0, y: 0.5, z: -0.4)),
    ]
)

@Test("A local function point becomes a world anchor only through the placement transform")
func localFunctionPointBecomesWorldAnchor() throws {
    // 手工算的旋转：yaw = π/2 把 +X 转到 -Z，把 +Z 转到 +X。
    let registry = try WorldPropAnchorRegistry(placements: [
        WorldPropFunctionPlacement(
            objectID: "machine.device",
            position: WorldVector3(x: 2, y: 1, z: -3),
            yaw: .pi / 2,
            declaration: WorldPropFunctionPointDeclaration(
                objectID: "machine.device",
                functionPoints: [
                    point("probe", .standingSpot, WorldVector3(x: 0.5, y: 0.25, z: 1.0))
                ]
            )
        )
    ])
    let anchor = try #require(registry.anchor(objectID: "machine.device", role: "probe"))
    #expect(abs(anchor.position.x - 3) < 0.0001, "x = 2 + 1.0, the +Z local axis rotated onto +X")
    #expect(abs(anchor.position.y - 1.25) < 0.0001, "local +Y is world +Y, never rotated")
    #expect(abs(anchor.position.z - (-3.5)) < 0.0001, "z = -3 - 0.5, the +X local axis rotated onto -Z")
    #expect(anchor.id == "machine.device#probe")
}

@Test("A declared role binds an activity entry; only standing spots feed the standing rule")
func declaredRoleBindsActivityEntry() throws {
    let registry = try WorldPropAnchorRegistry(derive: wishLikeDeclaration, at: .init(x: 0.8, y: -0.018, z: -2.6), yaw: 0)
    let entry = try #require(registry.entry(activityID: "machine.collect"))
    #expect(entry.id == "machine.device#pickup")
    #expect(registry.registeredActivityIDs == ["machine.collect"])
    // 只有 standingSpot 参与"居民站得住吗 / 走得到吗"：出货口与按钮不是站的地方。
    #expect(registry.routeAnchorIDs == ["machine.device#pickup"])
    #expect(registry.routeAnchorPositions["machine.device#outlet"] == nil)
    #expect(registry.routeAnchorPositions["machine.device#interact"] == nil)
    #expect(registry.anchors.count == 3)
    // 没写 yaw 的站立点面向被操作点（角色前方是 -Z，所以是 atan2(-dx,-dz)）。
    let jukeboxLike = try WorldPropAnchorRegistry(placements: [
        WorldPropFunctionPlacement(
            objectID: "machine.device",
            position: WorldVector3(x: 2, y: 0, z: -6),
            yaw: 0,
            declaration: WorldPropFunctionPointDeclaration(
                objectID: "machine.device",
                functionPoints: [
                    point("interact", .standingSpot, WorldVector3(x: -0.7, y: 0, z: 0),
                          activityID: "music.listen")
                ]
            )
        )
    ])
    let facing = try #require(jukeboxLike.anchor(objectID: "machine.device", role: "interact"))
    #expect(abs(facing.yaw - (-Float.pi / 2)) < 0.0001,
            "facing the prop from -X must be -π/2 (character forward is -Z), got \(facing.yaw)")
}

@Test("A committed placement is the only truth; a withdrawn object registers nothing")
func objectStateIsTheOnlyPlacementTruth() throws {
    let source = WorldPropFunctionSource(
        declaration: wishLikeDeclaration,
        seedPosition: WorldVector3(x: 0.8, y: -0.018, z: -2.6),
        seedYaw: 0
    )
    // 存档里没有这件道具 ⇒ 用世界包里的**种子**摆放。
    let seeded = try WorldPropAnchorRegistry.derive(sources: [source], objectStates: [:])
    #expect(abs((seeded.entry(activityID: "machine.collect")?.position.z ?? 0) - (-3.55)) < 0.0001)

    // 存档里有 ⇒ 存档说话。
    let moved = try WorldPropAnchorRegistry.derive(
        sources: [source],
        objectStates: ["machine.device": WorldObjectState(
            transform: WorldTransform(
                position: WorldVector3(x: -1.5, y: 0, z: -4.5),
                rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
                scale: WorldVector3(x: 1, y: 1, z: 1)
            )
        )]
    )
    let movedEntry = try #require(moved.entry(activityID: "machine.collect"))
    #expect(abs(movedEntry.position.x - (-1.5)) < 0.0001)
    #expect(abs(movedEntry.position.z - (-5.45)) < 0.0001)

    // 收回了 ⇒ **注销**，而且**不回退到种子**（收回不能"复活"锚点）。
    let withdrawn = try WorldPropAnchorRegistry.derive(
        sources: [source],
        objectStates: ["machine.device": WorldObjectState(
            isEnabled: false,
            transform: WorldTransform(
                position: WorldVector3(x: -1.5, y: 0, z: -4.5),
                rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
                scale: WorldVector3(x: 1, y: 1, z: 1)
            )
        )]
    )
    #expect(withdrawn.anchors.isEmpty)
    #expect(withdrawn.entry(activityID: "machine.collect") == nil)
}

@Test("Two props claiming one activity entry is refused, never silently resolved")
func duplicateActivityEntryIsRefused() throws {
    let first = WorldPropFunctionPlacement(
        objectID: "machine.a", position: WorldVector3(x: 0, y: 0, z: 0), yaw: 0,
        declaration: WorldPropFunctionPointDeclaration(
            objectID: "machine.a",
            functionPoints: [point("pickup", .standingSpot, WorldVector3(x: 1, y: 0, z: 0),
                                   activityID: "shared.activity")]
        )
    )
    let second = WorldPropFunctionPlacement(
        objectID: "machine.b", position: WorldVector3(x: 4, y: 0, z: 0), yaw: 0,
        declaration: WorldPropFunctionPointDeclaration(
            objectID: "machine.b",
            functionPoints: [point("pickup", .standingSpot, WorldVector3(x: 1, y: 0, z: 0),
                                   activityID: "shared.activity")]
        )
    )
    #expect(throws: WorldPropAnchorError.activityEntryConflict(
        activityID: "shared.activity",
        first: "machine.a#pickup",
        second: "machine.b#pickup"
    )) {
        _ = try WorldPropAnchorRegistry(placements: [first, second])
    }
    // 同一个角色在一件道具里出现两次：声明本身就不合法（角色必须唯一），
    // 于是连注册表都构造不出来 —— 拒绝发生在**最早**的那一层。
    #expect(throws: WorldPropAnchorError.invalidDeclaration(objectID: "machine.a")) {
        _ = try WorldPropAnchorRegistry(placements: [WorldPropFunctionPlacement(
            objectID: "machine.a", position: WorldVector3(x: 0, y: 0, z: 0), yaw: 0,
            declaration: WorldPropFunctionPointDeclaration(
                objectID: "machine.a",
                functionPoints: [
                    point("pickup", .standingSpot, WorldVector3(x: 1, y: 0, z: 0)),
                    point("pickup", .standingSpot, WorldVector3(x: 2, y: 0, z: 0)),
                ]
            )
        )])
    }
}

@Test("Re-deriving a moved registry is atomic: the old value stays complete")
func reDerivationIsAtomic() throws {
    let original = try WorldPropAnchorRegistry(derive: wishLikeDeclaration, at: .init(x: 0.8, y: -0.018, z: -2.6), yaw: 0)
    let before = try #require(original.entry(activityID: "machine.collect"))
    let moved = try original.applying(.place(
        objectID: "machine.device", position: WorldVector3(x: 3, y: 0, z: -7), yaw: .pi
    ))
    let after = try #require(moved.entry(activityID: "machine.collect"))
    #expect(abs(after.position.x - 3) < 0.0001)
    #expect(abs(after.position.z - (-6.05)) < 0.0001, "yaw π turns the -0.95 m local offset onto +Z")
    // 旧值一个字节都没动 —— 这就是"失败时回滚"的形态：注册表是纯值。
    #expect(original.entry(activityID: "machine.collect")?.position == before.position)
    #expect(original.anchors.count == 3)
    // 收回后没有任何锚点留下。
    #expect(try original.applying(.withdraw(objectID: "machine.device")).anchors.isEmpty)
    #expect(throws: WorldPropAnchorError.unknownPlacement(objectID: "machine.missing")) {
        _ = try original.applying(.withdraw(objectID: "machine.missing"))
    }
}

@Test("An activity anchor is exactly one of baked geometry or a prop function point")
func activityEntryIsEitherGeometryOrDeclaration() throws {
    let functionPointJSON = """
    {"id":"machine.collect","action":"interact","functionPoint":{"propID":"machine.device"},
     "motionID":null,"propIDs":["machine.device"],"interruptible":true}
    """
    let anchor = try JSONDecoder().decode(
        WorldActivityAnchor.self, from: Data(functionPointJSON.utf8)
    )
    #expect(anchor.entry == .functionPoint(propID: "machine.device"))
    #expect(anchor.entryWaypointID == nil && anchor.transform == nil,
            "a function-point anchor must not carry baked geometry")

    let waypointJSON = """
    {"id":"home.idle","action":"idle","entryWaypointID":"wp.spawn",
     "transform":{"position":{"x":0,"y":0,"z":0},"rotation":{"x":0,"y":0,"z":0,"w":1},
     "scale":{"x":1,"y":1,"z":1}},
     "motionID":null,"propIDs":[],"interruptible":true}
    """
    let baked = try JSONDecoder().decode(
        WorldActivityAnchor.self, from: Data(waypointJSON.utf8)
    )
    #expect(baked.entry == .waypoint(
        id: "wp.spawn",
        transform: WorldTransform(
            position: WorldVector3(x: 0, y: 0, z: 0),
            rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
            scale: WorldVector3(x: 1, y: 1, z: 1)
        )
    ))

    // 两份几何 / 一份都没有：**装载期就拒绝**，绝不猜一个。
    let both = """
    {"id":"machine.collect","action":"interact","entryWaypointID":"wp.spawn",
     "transform":{"position":{"x":0,"y":0,"z":0},"rotation":{"x":0,"y":0,"z":0,"w":1},
     "scale":{"x":1,"y":1,"z":1}},"functionPoint":{"propID":"machine.device"},
     "motionID":null,"propIDs":[],"interruptible":true}
    """
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(WorldActivityAnchor.self, from: Data(both.utf8))
    }
    let neither = """
    {"id":"machine.collect","action":"interact","motionID":null,"propIDs":[],"interruptible":true}
    """
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(WorldActivityAnchor.self, from: Data(neither.utf8))
    }
}

@Test("A package prop declaration reads [x,y,z] vectors and keeps its declaration identity")
func proceduralDeclarationDecodesArrayVectors() throws {
    let json = """
    {"id":"prop.jukebox","kind":"prop.procedural","renderer":"builtin.jukebox",
     "position":[2,0.024776516,-6],"yaw":0,"size":[0.9,0.5,0.8],"activityID":"music.listen",
     "functionPoints":[{"role":"interact","kind":"standingSpot",
       "position":[-0.7,0.006824641,0],"activityID":"music.listen"}]}
    """
    let declaration = try JSONDecoder().decode(
        WorldProceduralPropDeclaration.self, from: Data(json.utf8)
    )
    #expect(declaration.objectID == "prop.jukebox")
    #expect(abs(declaration.seedPosition.z - (-6)) < 0.0001)
    #expect(declaration.size == WorldVector3(x: 0.9, y: 0.5, z: 0.8))
    let source = try #require(declaration.functionSource)
    let registry = try WorldPropAnchorRegistry.derive(sources: [source], objectStates: [:])
    let entry = try #require(registry.entry(activityID: "music.listen"))
    #expect(abs(entry.position.x - 1.3) < 0.0001)
    #expect(abs(entry.position.y - 0.031601157) < 0.0001)
    #expect(abs(entry.position.z - (-6)) < 0.0001)
}

@Test("Generated prop metadata declares function points only for its own object")
func generatedPropMetadataIsSelfIdentifying() throws {
    let declaration = WorldPropFunctionPointDeclaration(
        objectID: "generated.a",
        functionPoints: [point("interact", .standingSpot, WorldVector3(x: 0, y: 0, z: -0.4),
                               activityID: "coffee.brew")]
    )
    let json = String(decoding: try JSONEncoder().encode(declaration), as: UTF8.self)
    let prop = WorldGeneratedProp(
        objectID: "generated.a", sourceWishID: "w", assetID: "a",
        displayName: "咖啡机", size: WorldVector3(x: 0.3, y: 0.4, z: 0.5), sourceHeight: 0.7
    )
    let propJSON = String(decoding: try JSONEncoder().encode(prop), as: UTF8.self)
    let matching = WorldObjectState(
        transform: WorldTransform(
            position: WorldVector3(x: 1, y: 0, z: 1),
            rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
            scale: WorldVector3(x: 1, y: 1, z: 1)
        ),
        metadata: [
            "gmgn.generated-prop.v1": propJSON,
            WorldPropFunctionPointDeclaration.metadataKey: json,
        ]
    )
    #expect(matching.functionPointDeclaration?.objectID == "generated.a")
    // 张冠李戴（元数据自称是别的物件）⇒ 当作没有声明，绝不错挂。
    let mismatched = WorldObjectState(
        transform: matching.transform,
        metadata: [
            "gmgn.generated-prop.v1": propJSON,
            WorldPropFunctionPointDeclaration.metadataKey: json.replacingOccurrences(
                of: "generated.a", with: "generated.other"
            ),
        ]
    )
    #expect(mismatched.functionPointDeclaration == nil)
}

private extension WorldPropAnchorRegistry {
    /// 测试用：一件道具 + 一个摆放。
    init(
        derive declaration: WorldPropFunctionPointDeclaration,
        at position: WorldVector3,
        yaw: Float
    ) throws {
        try self.init(placements: [
            WorldPropFunctionPlacement(
                objectID: declaration.objectID, position: position, yaw: yaw,
                declaration: declaration
            )
        ])
    }
}
