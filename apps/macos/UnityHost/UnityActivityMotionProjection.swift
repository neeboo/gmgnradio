import Foundation

enum UnityActivityMotionProjection {
    static func resolve(avatarFormat: StageAvatarFormat?,approvedMotions: [String: StageMotionAsset],
                        locomoting: Bool,authoredIDs: [String], holdingRightHandAtIdle: Bool = false,
                        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (required: Bool,motion: [String: Any]?) {
        // The original orb is procedural; it has no humanoid skeleton or clip.
        guard let avatarFormat else { return (false,nil) }
        let ids: [String]
        if locomoting { ids = ResidentLocomotionMotionPolicy.walkMotionIDs(avatarFormat: avatarFormat)
            + ResidentLocomotionMotionPolicy.libraryWalkMotionIDs(approvedMotions: approvedMotions,avatarFormat: avatarFormat) }
        else if !authoredIDs.isEmpty {
            ids = authoredIDs.flatMap { id in
                // The VRMA is an offline retarget of this exact original clip,
                // not a substitute from the user's idle/dance selection.
                if avatarFormat == .vrm, id == "listen.music" {
                    return [MotionPackageStore.iluvSlapBassVRMID, id]
                }
                if avatarFormat == .vrm, id == "gmgn.motion.bones.jumping-jacks-pmx" {
                    return ["gmgn.motion.bones.jumping-jacks-vrm", id]
                }
                return [id]
            }
        }
        else if holdingRightHandAtIdle {
            ids = ["gmgn.motion.bones.hold-display-" + avatarFormat.rawValue]
        }
        else { ids = ResidentLocomotionMotionPolicy.idleMotionIDs(avatarFormat: avatarFormat) }
        guard let motion = ResidentLocomotionMotionPolicy.firstPlayable(ids,approvedMotions: approvedMotions,avatarFormat: avatarFormat),
              let url = motion.url,fileExists(url.path) else { return (true,nil) }
        return (true,["id": motion.id,"format": motion.format.rawValue,"path": url.path,
                     "loop": motion.loop,"playbackRate": motion.playbackRate])
    }
}
