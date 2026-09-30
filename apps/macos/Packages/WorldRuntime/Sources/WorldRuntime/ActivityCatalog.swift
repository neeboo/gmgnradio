import Foundation

public enum ActivityCatalogError: Error, Equatable, Sendable {
    case duplicateActivityID(String)
    case missingPhase(activityID: String, phase: LifeActivityPhase)
    case duplicatePhase(activityID: String, phase: LifeActivityPhase)
    case missingDefinition(activityID: String)
    case orphanDefinition(activityID: String)
    case unsupportedAction(activityID: String, action: String)
    /// 旧包适配器遇到了"道具功能点锚点"：它的几何只有运行时才存在，
    /// 旧包（无 `activityDefinitions`）无从表达 ⇒ 拒绝。
    case functionPointAnchorRequiresDefinition(activityID: String)
    case actionMismatch(
        activityID: String,
        anchorAction: String,
        definitionAction: String
    )
}

public struct ActivityCatalog: Sendable {
    public let definitions: [LifeActivityDefinition]
    private let definitionsByID: [String: LifeActivityDefinition]

    public init(definitions: [LifeActivityDefinition]) throws {
        var byID: [String: LifeActivityDefinition] = [:]

        for definition in definitions {
            guard byID[definition.id] == nil else {
                throw ActivityCatalogError.duplicateActivityID(definition.id)
            }

            var seenPhases: Set<LifeActivityPhase> = []
            for contract in definition.phases {
                guard seenPhases.insert(contract.phase).inserted else {
                    throw ActivityCatalogError.duplicatePhase(
                        activityID: definition.id,
                        phase: contract.phase
                    )
                }
            }

            for phase in LifeActivityPhase.allCases where !seenPhases.contains(phase) {
                throw ActivityCatalogError.missingPhase(
                    activityID: definition.id,
                    phase: phase
                )
            }
            byID[definition.id] = definition
        }

        self.definitions = definitions
        definitionsByID = byID
    }

    /// Builds the runtime catalog entirely from a world package. Modern
    /// packages carry explicit definitions; early schema-v1 packages are
    /// adapted deterministically from their activity anchors.
    public init(manifest: WorldManifest) throws {
        if manifest.activityDefinitions.isEmpty {
            try self.init(definitions: manifest.activities.map(Self.legacyDefinition))
            return
        }

        let anchorIDs = Set(manifest.activities.map(\.id))
        let definitionIDs = Set(manifest.activityDefinitions.map(\.id))

        if let missing = anchorIDs.subtracting(definitionIDs).sorted().first {
            throw ActivityCatalogError.missingDefinition(activityID: missing)
        }
        if let orphan = definitionIDs.subtracting(anchorIDs).sorted().first {
            throw ActivityCatalogError.orphanDefinition(activityID: orphan)
        }

        let authoredCatalog = try ActivityCatalog(definitions: manifest.activityDefinitions)
        for anchor in manifest.activities {
            guard let canonicalAction = LifeActivity.canonicalTypeID(for: anchor.action) else {
                throw ActivityCatalogError.unsupportedAction(
                    activityID: anchor.id,
                    action: anchor.action
                )
            }
            guard let definition = authoredCatalog.definition(id: anchor.id) else { continue }
            guard canonicalAction == definition.activity.typeID else {
                throw ActivityCatalogError.actionMismatch(
                    activityID: anchor.id,
                    anchorAction: anchor.action,
                    definitionAction: definition.activity.typeID
                )
            }
        }

        self = authoredCatalog
    }

    public func definition(id: String) -> LifeActivityDefinition? {
        definitionsByID[id]
    }

    public func definitions(for activity: LifeActivity) -> [LifeActivityDefinition] {
        definitions.filter { $0.activity == activity }
    }

    private static func legacyDefinition(
        anchor: WorldActivityAnchor
    ) throws -> LifeActivityDefinition {
        guard let action = LifeActivity.canonicalTypeID(for: anchor.action) else {
            throw ActivityCatalogError.unsupportedAction(
                activityID: anchor.id,
                action: anchor.action
            )
        }
        // 旧包（没有 `activityDefinitions`）只能表达世界固有锚点：它的执行契约完全由
        // 烘焙几何决定。道具功能点锚点的几何是**运行时派生**的，旧包无从表达 ——
        // 拒绝，而不是替它编一份契约。
        guard let entryWaypointID = anchor.entryWaypointID,
              let transform = anchor.transform else {
            throw ActivityCatalogError.functionPointAnchorRequiresDefinition(
                activityID: anchor.id
            )
        }

        let activity: LifeActivity
        switch action {
        case "idle":
            activity = .idle
        case "walk":
            activity = .walk(destinationID: entryWaypointID)
        case "turn":
            activity = .turn(targetYaw: yaw(of: transform.rotation))
        case "sit":
            activity = .sit(anchorID: anchor.id)
        case "gaze":
            activity = .gaze(targetID: anchor.id)
        case "listenMusic":
            activity = .listenMusic(anchorID: anchor.id)
        default:
            throw ActivityCatalogError.unsupportedAction(
                activityID: anchor.id,
                action: anchor.action
            )
        }

        let phases = LifeActivityPhase.allCases.map { phase in
            ActivityPhaseContract(
                phase: phase,
                requiredAnchorIDs: phase == .approach && activity.approachTargetID != nil
                    ? [anchor.id]
                    : [],
                motionIDs: phase == .loop ? [anchor.motionID].compactMap { $0 } : [],
                propIDs: phase == .loop ? anchor.propIDs : []
            )
        }
        return LifeActivityDefinition(
            id: anchor.id,
            activity: activity,
            phases: phases,
            interruptible: anchor.interruptible,
            cooldownSeconds: 0
        )
    }

    private static func yaw(of rotation: WorldQuaternion) -> Float {
        let numerator = 2 * (rotation.w * rotation.y + rotation.x * rotation.z)
        let denominator = 1 - 2 * (rotation.y * rotation.y + rotation.z * rotation.z)
        return atan2(numerator, denominator)
    }
}
