// Compile/run the actual test source with production consumers, private RPCs,
// no application, default taskd endpoint, provider credentials or audio.
import Foundation
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-agent-tests-private-"+UUID().uuidString)
try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
defer{try? FileManager.default.removeItem(at:scratch)}
let path="apps/macos/Tests/GMGNRadioTests/Agent/AgentConversationServiceTests.swift"
let source=try String(contentsOf:root.appendingPathComponent(path),encoding:.utf8)
let tests=scratch.appendingPathComponent("Tests.swift")
try source.replacingOccurrences(of:"@testable import GMGNRadio",with:"").write(to:tests,atomically:true,encoding:.utf8)
let shim = #"""
import Foundation
import Testing
enum E2ERuntime { static let applicationSupportBase: URL? = nil }
struct WorldAuthorityEndpoint {static func taskServiceRoot(applicationSupportBase: URL? = nil)->URL{fatalError("default formal root prohibited")}}
final class TaskdHTTPAuthorityClient: @unchecked Sendable {
 init(endpointFile:String,helperPath:String,allowsLaunching:Bool=true,timeout:Double=5){fatalError("default formal endpoint prohibited")}
 func call(method:String,params:[String:Any])throws->[String:Any]{fatalError("default formal endpoint prohibited")}
}
@MainActor final class RealtimeVoiceStatusStore {
 enum State {case disconnected}
 static let shared=RealtimeVoiceStatusStore()
 var state:State = .disconnected
}
@main struct TestMain { static func main() async { let status:CInt = await Testing.__swiftPMEntryPoint(); exit(status) } }
"""#
let main=scratch.appendingPathComponent("Main.swift");try shim.write(to:main,atomically:true,encoding:.utf8)
let agent=["CodexCLI","AgentConversationService","ResidentCodexTransport","ResidentCodexPolicy","ResidentCodexAgent","ResidentSteeringDelivery","ResidentDSHTransport","ResidentDSHConfiguration","ResidentStateClient","ResidentMemoryClient","ResidentConversationMemory","ResidentDSHAgentToolBridge","ResidentDSHHostToolsBridge","ResidentClaudeToolBridge","ResidentClaudeProcessRunner"]
let presence=["ResidentVisionCapture","RetryBackoff","RustCodexSessionClient","RustDSHSessionClient","RustResidentClaudeClient","RustChatClient","RustProductSettingsClient"]
let binary=scratch.appendingPathComponent("checks"),compile=Process()
compile.executableURL=URL(fileURLWithPath:"/usr/bin/swiftc")
let testingFrameworks="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
compile.arguments=["-swift-version","6","-j1","-parse-as-library","-F",testingFrameworks,"-Xlinker","-rpath","-Xlinker",testingFrameworks]
compile.arguments! += ["-load-plugin-library","/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"]
compile.arguments! += agent.map{root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/"+$0+".swift").path}
compile.arguments! += presence.map{root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/"+$0+".swift").path}
compile.arguments! += [tests.path,main.path,"-o",binary.path]
try compile.run();compile.waitUntilExit();guard compile.terminationStatus==0 else{exit(compile.terminationStatus)}
if CommandLine.arguments.contains("--compile-only"){print("PASS actual AgentConversationServiceTests Swift6 private compile");exit(0)}
let run=Process();run.executableURL=binary;run.arguments=Array(CommandLine.arguments.dropFirst())
try run.run();run.waitUntilExit();exit(run.terminationStatus)
