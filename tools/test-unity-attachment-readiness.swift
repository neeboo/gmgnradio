import Foundation
@main struct ReadinessChecks {
    static func main() {
        let now=Date(timeIntervalSince1970:100)
        let avatar="vrm.user-imported-fixture"
        var gate=UnityAttachmentReadiness()
        var receipt: [String:Any]=["worldID":"world","avatarID":avatar,"avatarFormat":"vrm",
            "selectionRevision":7,"layoutRevision":4,"slots":["rightHand","back","waist"],"assets":["prop":"asset","alien":"other"]]
        func adopt(_ value:[String:Any])->Bool { gate.adopt(value,worldID:"world",avatarID:avatar,avatarFormat:"vrm",
            selectionRevision:7,layoutRevision:4,expectedAssets:["prop":"asset"],now:now) }
        precondition(adopt(receipt))
        for slot in ["rightHand","back","waist"] {
            precondition(gate.permits(slot:slot,objectID:"prop",assetID:"asset",layoutRevision:4,now:now))
        }
        precondition(!gate.permits(slot:"back",objectID:"alien",assetID:"other",layoutRevision:4,now:now))
        precondition(!gate.permits(slot:"back",objectID:"prop",assetID:"asset",layoutRevision:5,now:now))
        precondition(!gate.permits(slot:"back",objectID:"prop",assetID:"asset",layoutRevision:4,now:now.addingTimeInterval(7)))
        for (field,value) in [("worldID","other" as Any),("avatarID","other"),("avatarFormat","pmx"),("selectionRevision",6),("layoutRevision",3),("selectionRevision",true),("slots",["invalid"])] {
            var invalid=receipt;invalid[field]=value;precondition(!adopt(invalid))
        }
        receipt["slots"]=["back","waist"];precondition(adopt(receipt))
        precondition(!gate.permits(slot:"rightHand",objectID:"prop",assetID:"asset",layoutRevision:4,now:now))
        precondition(gate.permits(slot:"back",objectID:"prop",assetID:"asset",layoutRevision:4,now:now))
        gate.invalidate();precondition(!gate.permits(slot:"back",objectID:"prop",assetID:"asset",layoutRevision:4,now:now))
        var orb=receipt;orb["avatarFormat"]="orb";orb["slots"]=[] as [String]
        precondition(gate.adopt(orb,worldID:"world",avatarID:avatar,avatarFormat:"orb",selectionRevision:7,
            layoutRevision:4,expectedAssets:["prop":"asset"],now:now))
        precondition(gate.isAssetPrepared(objectID:"prop",assetID:"asset",layoutRevision:4,now:now))
        precondition(!gate.permits(slot:"rightHand",objectID:"prop",assetID:"asset",layoutRevision:4,now:now))
        orb["slots"]=["rightHand"]
        precondition(!gate.adopt(orb,worldID:"world",avatarID:avatar,avatarFormat:"orb",selectionRevision:7,
            layoutRevision:4,expectedAssets:["prop":"asset"],now:now))
        print("Unity attachment readiness PASS arbitrary VRM/slots/assets/world/avatar/layout/selection/staleness")
    }
}
