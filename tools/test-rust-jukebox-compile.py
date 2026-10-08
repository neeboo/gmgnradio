#!/usr/bin/env python3
"""Compile the actual compound host consumer with native/platform leaves only."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = repo / "apps/macos/Sources/GMGNRadio"
composition = (repo / "apps/macos/UnityHost/UnityWorldSessionComposition.swift").read_text()
region = "    var prepareJukebox:" + composition.split("    var prepareJukebox:", 1)[1].split("    private func motionProjection()", 1)[0]
leaves = '''import Foundation
enum WorldAuthorityError: Error { case invalidResponse, daemon(String) }
struct TaskdHTTPAuthorityClient: Sendable {
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, timeout: Double) {}
    func call(method: String, params: [String: Any]) throws -> [String: Any] { fatalError("compile only") }
}
struct WorldAuthorityEndpoint { let endpointFile="unused", helperPath="unused"; init(applicationSupportBase: URL) {} }
enum TaskdHTTPError: Error { case unavailable }
enum PropTaskDaemonError: Error { case unavailable }
struct WorldVector3 { let x: Float, y: Float, z: Float }
enum Phase: String { case loop }
enum StageAvatarFormat: String { case vrm }
struct StageMotionAsset { let id:String }
enum MotionPackageStore { static let iluvSlapBassVRMID="builtin.motion.iluvslapbass-vrm" }
struct Anchor { enum Kind { case interaction }; let objectID:String; let position:WorldVector3; let kind:Kind }
struct Registry { let anchorsByID:[String:Anchor]=[:]; func entry(activityID:String)->Anchor? { nil } }
struct Contract { let motionIDs:[String]=[] }
struct Definition { func contract(for phase:Phase)->Contract? { nil } }
struct Catalog { func definition(id:String)->Definition? { nil } }
struct Manifest { let worldID="fixture" }
struct State { let revision:UInt64=1 }
struct Active { let phase:Phase }
@MainActor final class WorldAgentContext {
    let manifest=Manifest(), state=State(), propAnchorRegistry=Registry(), activityCatalog=Catalog()
    let currentActivityRequestID:String?=nil; let activeActivitySnapshot:Active?=nil
    func startActivityMeasured(id:String) async throws {}
    func stopActivity(reason:String) throws {}
}
@MainActor final class UnityActivityBridge {
    enum ProjectionError:Error { case notRendered }
    func invalidateProjection() {}
}
enum UnityActivityMotionProjection {
    static func resolve(avatarFormat:StageAvatarFormat?,approvedMotions:[String:StageMotionAsset],locomoting:Bool,authoredIDs:[String])->(required:Bool,motion:[String:Any]?) { (false,nil) }
}
@MainActor final class Host {
    enum CompositionError:Error { case sessionClosed,jukeboxNotPlaced }
    var closed=false
    let context=WorldAgentContext(), activity=UnityActivityBridge()
    let applicationSupportBase=URL(fileURLWithPath:"/private-fixture"), residentScope="fixture", residentHostSessionID="host"
    let approvedMotions:[String:StageMotionAsset]=[:]; let avatarFormat:StageAvatarFormat?=nil
'''
with tempfile.TemporaryDirectory(prefix="gmgn-jukebox-compile-") as raw:
    root = Path(raw)
    host = root / "Host.swift"; host.write_text(leaves + region + "\n}\n")
    code = subprocess.run(["swiftc", "-swift-version", "6", "-typecheck", str(host),
        str(source / "Presence/RustJukeboxClient.swift")]).returncode
    if code: raise SystemExit(code)
    adapter = root / "adapter"
    code = subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
        str(repo / "tools/test-unity-resident-music-actions.swift"),
        str(repo / "apps/macos/UnityHost/UnityResidentMusicActions.swift"), "-o", str(adapter)]).returncode
    if code: raise SystemExit(code)
    code = subprocess.run([str(adapter)]).returncode
    if code: raise SystemExit(code)
    print("PASS actual host compound source Swift6 typecheck + five actual adapter operations; no RPC/audio/app")
