import Foundation
@main struct PresenceRemovalAcceptance {
    static func main() async throws {
        precondition(CommandLine.arguments.count == 3)
        let transport = TaskdHTTPAuthorityClient(endpointFile: CommandLine.arguments[1], helperPath: "", allowsLaunching: false, timeout: 5)
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let client = RustPresenceSelectionClient(scope: root.path, call: { method, data in
            let p = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: p))
        })
        let packages = root.appendingPathComponent("PresencePackages")
        let motions = root.appendingPathComponent("MotionPackages")
        let orb = PresencePackage(manifest: .init(id: "builtin.orb",engine:.orb,entry:""),installPath:nil,isBuiltIn:true,rendererAvailable:true)
        let avatar = PresencePackage(manifest: .init(id:"test.pmx",engine:.pmx,entry:"model.pmx"),installPath:packages.appendingPathComponent("test.pmx").path,isBuiltIn:false,rendererAvailable:true)
        let idle = StageMotionAsset(id:"builtin.motion.natural-idle",format:.procedural,url:nil,loop:true)
        let clip = StageMotionAsset(id:"test.vmd",format:.vmd,url:motions.appendingPathComponent("test.vmd/clip.vmd"),loop:false)
        _ = try await client.bind(packages:[orb,avatar],motions:[idle,clip],packageRoot:packages,motionRoot:motions,policy:"native",supportedEngines:["orb","pmx"],builtInMotionIDs:[idle.id])
        _ = try await client.event("select_avatar",id:"test.pmx")
        _ = try await client.event("renderer_ack",success:true)
        _ = try await client.event("select_motion",id:"test.vmd")
        _ = try await client.event("renderer_ack",success:true)
        try await client.remove(kind:"motions",id:"test.vmd",root:motions)
        precondition(client.confirmed?.motionID == idle.id)
        precondition(!FileManager.default.fileExists(atPath:motions.appendingPathComponent("test.vmd").path))
        _ = try await client.event("renderer_ack",success:true)
        try await client.remove(kind:"avatars",id:"test.pmx",root:packages)
        precondition(client.confirmed?.avatarID == "builtin.orb")
        precondition(!FileManager.default.fileExists(atPath:packages.appendingPathComponent("test.pmx").path))
        do { try await client.remove(kind:"avatars",id:"builtin.orb",root:packages); fatalError("builtin deletion accepted") }
        catch WorldAuthorityError.daemon(let code) { precondition(code == "presence_remove_builtin") }
        print("PASS production Swift6 client actual HTTP motion/avatar deletion + fallback + builtin rejection")
    }
}
