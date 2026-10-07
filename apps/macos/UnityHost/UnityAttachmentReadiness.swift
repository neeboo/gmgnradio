import Foundation
import CoreFoundation

/// A renderer receipt permits only the slots and prepared objects it actually
/// projected for this selected character and layout. There is no character ID
/// allow-list: bone evidence, current identity and prepared assets are required.
struct UnityAttachmentReadiness {
    private(set) var slots: Set<String> = []
    private(set) var assets: [String:String] = [:]
    private var receivedAt: Date?
    private var layoutRevision: UInt64?

    mutating func invalidate() { slots=[];assets=[:];receivedAt=nil;layoutRevision=nil }

    mutating func adopt(_ receipt: [String:Any],worldID: String,avatarID: String?,avatarFormat: String?,
                        selectionRevision: UInt64,layoutRevision expectedLayout: UInt64,
                        expectedAssets: [String:String],now: Date = Date()) -> Bool {
        guard let avatarID,!avatarID.isEmpty,let avatarFormat,["pmx","vrm","orb"].contains(avatarFormat),
              receipt["worldID"] as? String == worldID,receipt["avatarID"] as? String == avatarID,
              receipt["avatarFormat"] as? String == avatarFormat,
              Self.revision(receipt["selectionRevision"]) == selectionRevision,
              Self.revision(receipt["layoutRevision"]) == expectedLayout,
              let reportedSlots=receipt["slots"] as? [String],let reportedAssets=receipt["assets"] as? [String:String],
              reportedSlots.allSatisfy({ ["rightHand","back","waist"].contains($0) }),
              avatarFormat != "orb" || reportedSlots.isEmpty else { return false }
        slots=Set(reportedSlots)
        assets=reportedAssets.filter{ expectedAssets[$0.key] == $0.value }
        receivedAt=now;layoutRevision=expectedLayout
        return true
    }

    func permits(slot: String,objectID: String,assetID: String,layoutRevision currentLayout: UInt64,
                 now: Date = Date()) -> Bool {
        slots.contains(slot) && isAssetPrepared(objectID:objectID,assetID:assetID,layoutRevision:currentLayout,now:now)
    }

    func isAssetPrepared(objectID: String,assetID: String,layoutRevision currentLayout: UInt64,
                         now: Date = Date()) -> Bool {
        guard let receivedAt,now.timeIntervalSince(receivedAt)>=0,
              now.timeIntervalSince(receivedAt)<=6,layoutRevision == currentLayout else { return false }
        return assets[objectID] == assetID
    }

    private static func revision(_ value: Any?) -> UInt64? {
        guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(exactly:number.doubleValue)
    }
}
