import Foundation

// Compiles the exact production allowlist; no Host construction or task execution.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = try String(contentsOf: root.appendingPathComponent("apps/macos/UnityHost/UnityMediaHost.swift"), encoding: .utf8)
guard let start = source.range(of: "enum UnityRuntimeDiagnostics {") else { fatalError("Diagnostics projection missing") }
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-runtime-diagnostics-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let test = #"""
let secret = "FORBIDDEN_PRIVATE_VALUE"
let value = UnityRuntimeDiagnostics.project(world: ["agentNotifications": ["status":"subscribed","pending":1,"token":secret],"notificationError":secret,"renderedWishOutputIDs":["prop.safe"],"currentActivityPhase":"approach"], autonomy: ["status":"ready","isStopped":true,"intentPausedByUser":true,"backgroundTurnsPerHour":0,"backgroundTurnsInLastHour":0,"recentEvents":[secret],"lastFailure":secret,"pendingUserMessages":[secret],"intent":["summary":secret]], preview: ["worldID":"world.safe","generation":1,"entries":[["objectID":"prop.safe","sourceWishID":"wish.safe","taskID":"task.safe","stage":"ready","localModelPath":secret,"name":secret,"token":secret]]],ambientEnabled:false,editing:true)
let data = try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)
let text = String(decoding:data,as:UTF8.self)
precondition(!text.contains(secret))
let state=value["autonomy"] as! [String:Any]
let blockers=state["observedBlockers"] as! [String]
precondition(Set(blockers)==Set(["ambient_disabled","world_editing","user_stopped","intent_paused_by_user","zero_budget"]))
precondition(state["ambientDisabledBlocksExistingTaskContinuation"] as? Bool == false)
let preview=value["wishOutputPreview"] as! [String:Any]
precondition(preview["entryCount"] as? Int == 1 && preview["phase"] as? String == "ready_entries")
precondition(value["renderedWishOutputIDs"] as? [String] == ["prop.safe"])
precondition(value["currentActivityPhase"] as? String == "approach")
let empty=UnityRuntimeDiagnostics.project(world:[:],autonomy:[:],preview:[:],ambientEnabled:true,editing:false)
precondition(empty["notificationRetryFailures"] as? Int == 0)
let retry=UnityRuntimeDiagnostics.project(world:["notificationRetryFailures":3],autonomy:[:],preview:[:],ambientEnabled:true,editing:false)
precondition(retry["notificationRetryFailures"] as? Int == 3)
precondition((empty["wishOutputPreview"] as! [String:Any])["phase"] as? String == "unavailable")
let encoded=try JSONSerialization.data(withJSONObject:empty)
precondition(!encoded.isEmpty)
print("PASS: production runtime diagnostics privacy allowlist, blockers, preview IDs, accepted projection IDs and unavailable state")
"""#
let program = directory.appendingPathComponent("checks.swift"), binary = directory.appendingPathComponent("checks")
try ("import Foundation\n" + source[start.lowerBound...] + "\n" + test).write(to: program, atomically: true, encoding: .utf8)
let compiler=Process();compiler.executableURL=URL(fileURLWithPath:"/usr/bin/swiftc");compiler.arguments=["-swift-version","6",program.path,"-o",binary.path]
try compiler.run();compiler.waitUntilExit();guard compiler.terminationStatus==0 else {exit(compiler.terminationStatus)}
let run=Process();run.executableURL=binary;try run.run();run.waitUntilExit();exit(run.terminationStatus)
