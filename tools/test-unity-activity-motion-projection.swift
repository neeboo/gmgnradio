import Foundation

enum StageAvatarFormat: String { case pmx,vrm }
enum StageMotionFormat: String { case procedural,vmd,vrma }
enum MotionPackageStore { static let iluvSlapBassVRMID = "builtin.motion.iluvslapbass-vrm" }
struct StageMotionAsset {
    let id: String
    let format: StageMotionFormat
    let url: URL?
    var loop = true
    var playbackRate: Float = 1
    var isLocomotionLoop: Bool { id.contains("walk") && loop }
}
@main struct ProjectionChecks {
    static func main() {
        let pmx = StageMotionAsset(id:"gmgn.motion.bones.walk-loop-pmx",format:.vmd,url:URL(fileURLWithPath:"/pmx.vmd"))
        let vrm = StageMotionAsset(id:"gmgn.motion.bones.walk-loop-vrm",format:.vrma,url:URL(fileURLWithPath:"/vrm.vrma"))
        let motions = [pmx.id:pmx,vrm.id:vrm]
        let exists: (String)->Bool = { _ in true }
        for (format, motionFormat, suffix) in [(StageAvatarFormat.pmx, StageMotionFormat.vmd, "pmx"), (.vrm, .vrma, "vrm")] {
            let idle = StageMotionAsset(id: "gmgn.motion.bones.idle-loop-\(suffix)", format: motionFormat, url: URL(fileURLWithPath: "/idle.\(motionFormat.rawValue)"))
            let result = UnityActivityMotionProjection.resolve(avatarFormat: format, approvedMotions: [idle.id: idle], locomoting: false, authoredIDs: [], fileExists: exists)
            precondition(result.required && result.motion?["id"] as? String == idle.id)
        }
        let orb = UnityActivityMotionProjection.resolve(avatarFormat:nil,approvedMotions:motions,locomoting:true,authoredIDs:[],fileExists:exists)
        precondition(!orb.required && orb.motion == nil)
        for (format,id) in [(StageAvatarFormat.pmx,pmx.id),(.vrm,vrm.id)] {
            let result=UnityActivityMotionProjection.resolve(avatarFormat:format,approvedMotions:motions,locomoting:true,authoredIDs:[],fileExists:exists)
            precondition(result.required && result.motion?["id"] as? String == id)
        }
        let incompatible=UnityActivityMotionProjection.resolve(avatarFormat:.vrm,approvedMotions:motions,locomoting:false,authoredIDs:[pmx.id],fileExists:exists)
        precondition(incompatible.required && incompatible.motion == nil)
        let jumpingVRM = StageMotionAsset(id: "gmgn.motion.bones.jumping-jacks-vrm", format: .vrma,
            url: URL(fileURLWithPath: "/jumping.vrma"))
        let jumping = UnityActivityMotionProjection.resolve(avatarFormat: .vrm,
            approvedMotions: [jumpingVRM.id: jumpingVRM], locomoting: false,
            authoredIDs: ["gmgn.motion.bones.jumping-jacks-pmx"], fileExists: exists)
        precondition(jumping.motion?["id"] as? String == jumpingVRM.id,
            "agent authored jumping jacks must use the exact VRMA available to manual selection")
        let musicPMX = StageMotionAsset(id: "builtin.motion.iluvslapbass", format: .vmd, url: URL(fileURLWithPath: "/music.vmd"))
        let musicVRM = StageMotionAsset(id: MotionPackageStore.iluvSlapBassVRMID, format: .vrma, url: URL(fileURLWithPath: "/music.vrma"))
        for (format, expected) in [(StageAvatarFormat.pmx, musicPMX), (.vrm, musicVRM)] {
            let result = UnityActivityMotionProjection.resolve(avatarFormat: format,
                approvedMotions: ["listen.music": musicPMX, musicVRM.id: musicVRM],
                locomoting: false, authoredIDs: ["listen.music"], fileExists: exists)
            precondition(result.motion?["id"] as? String == expected.id,
                         "music activity must retain its choreography on both humanoid formats")
        }
        let missing=UnityActivityMotionProjection.resolve(avatarFormat:.pmx,approvedMotions:motions,locomoting:true,authoredIDs:[],fileExists:{_ in false})
        precondition(missing.required && missing.motion == nil)
        let imported=StageMotionAsset(id:"imported.operate",format:.vrma,url:URL(fileURLWithPath:"/imported.vrma"))
        let updated=UnityActivityMotionProjection.resolve(avatarFormat:.vrm,approvedMotions:[imported.id:imported],locomoting:false,authoredIDs:[imported.id],fileExists:exists)
        precondition(updated.motion?["id"] as? String == imported.id)
        for (format, clipFormat) in [(StageAvatarFormat.pmx, StageMotionFormat.vmd), (.vrm, .vrma)] {
            let hold = StageMotionAsset(id: "gmgn.motion.bones.hold-display-" + format.rawValue,
                format: clipFormat, url: URL(fileURLWithPath: "/hold." + clipFormat.rawValue))
            var holdingLibrary = motions
            holdingLibrary[hold.id] = hold
            let operation = StageMotionAsset(id: "authored-device-operation-" + format.rawValue,
                format: clipFormat, url: URL(fileURLWithPath: "/operate." + clipFormat.rawValue), loop: false)
            holdingLibrary[operation.id] = operation
            let heldIdle = UnityActivityMotionProjection.resolve(avatarFormat: format,
                approvedMotions: holdingLibrary, locomoting: false, authoredIDs: [],
                holdingRightHandAtIdle: true, fileExists: exists)
            precondition(heldIdle.motion?["id"] as? String == hold.id)
            let heldWalk = UnityActivityMotionProjection.resolve(avatarFormat: format,
                approvedMotions: holdingLibrary, locomoting: true, authoredIDs: [],
                holdingRightHandAtIdle: true, fileExists: exists)
            precondition(heldWalk.motion?["id"] as? String == "gmgn.motion.bones.walk-loop-" + format.rawValue)
            let authored = UnityActivityMotionProjection.resolve(avatarFormat: format,
                approvedMotions: holdingLibrary, locomoting: false, authoredIDs: [operation.id],
                holdingRightHandAtIdle: true, fileExists: exists)
            precondition(authored.motion?["id"] as? String == operation.id,
                "held idle must not replace a finite or device operation contract")
            let absent = UnityActivityMotionProjection.resolve(avatarFormat: format,
                approvedMotions: motions, locomoting: false, authoredIDs: [],
                holdingRightHandAtIdle: true, fileExists: exists)
            precondition(absent.required && absent.motion == nil)
            let missingFile = UnityActivityMotionProjection.resolve(avatarFormat: format,
                approvedMotions: holdingLibrary, locomoting: false, authoredIDs: [],
                holdingRightHandAtIdle: true, fileExists: { _ in false })
            precondition(missingFile.required && missingFile.motion == nil)
        }
        print("Unity activity motion projection PASS orb/PMX/VRM/incompatible/missing/refreshed")
    }
}
