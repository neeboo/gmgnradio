import Foundation
import WorldRuntime

/// One acknowledged character selection, not a queue of old hold commands.
/// Any changed held object/old avatar/source asset cancels this intent.
struct UnityHeldAvatarRebinding: Equatable {
    let objectID: String
    let assetID: String
    let previousAvatarID: String
    let targetAvatarID: String
    let selectionRevision: UInt64
    let slot: WorldPropSlot

    static func pending(state: WorldState, targetAvatarID: String?, selectionRevision: UInt64) -> Self? {
        guard let targetAvatarID, !targetAvatarID.isEmpty, let held = state.heldProp,
              held.avatarAssetID != targetAvatarID,
              let prop = state.objectStates[held.objectID]?.generatedProp else { return nil }
        return .init(objectID: held.objectID, assetID: prop.assetID, previousAvatarID: held.avatarAssetID,
            targetAvatarID: targetAvatarID, selectionRevision: selectionRevision, slot: held.hand)
    }

    func isCurrent(state: WorldState, targetAvatarID: String?, selectionRevision: UInt64) -> Bool {
        self == Self.pending(state: state, targetAvatarID: targetAvatarID, selectionRevision: selectionRevision)
    }
}
