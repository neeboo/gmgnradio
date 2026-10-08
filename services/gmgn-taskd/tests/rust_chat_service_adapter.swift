import Foundation
@main struct ChatTest {
 static func main() async throws {
  let http=CLIHTTP(URL(string:CommandLine.arguments[1])!)
  let client=RustChatClient(call:http.call)
  let root=URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent("private-root")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let service=AgentConversationService(client:client,root:root)
  for backend in AgentConversationBackendID.allCases {
   for _ in 0..<2 {let answer=try await service.test(backend,scope:backend.rawValue);precondition(answer=="answer")}
  }
  let reads=service.preferences.reads;precondition(reads==4)
  let image=root.appendingPathComponent("input.png")
  try Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZAAAAABJRU5ErkJggg==")!.write(to:image)
  _=try await service.test(.codex,scope:"image",images:[image])
  _=try await service.test(.dsh,scope:"dsh-image",images:[image])
  _=try await service.test(.dsh,scope:"dsh-image")
  let children=try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("ChatImages").path)
  precondition(children.isEmpty,"completed request images leaked")
  do {_=try await service.test(.codex,scope:"unknown",images:[image]);preconditionFailure("unknown accepted")}
  catch RustChatClient.ClientError.unknownExecution {}
  let unknownIdentity=service.plainChatIdentity
  do {_=try await service.test(.codex,scope:"blocked",images:[image]);preconditionFailure("unknown replayed")}
  catch RustChatClient.ClientError.busy {}
  precondition(service.plainChatIdentity==unknownIdentity,"busy replaced unknown owner")
  let retained=try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("ChatImages").path)
  precondition(retained.count==1)
  try await client.reset(backend:"codex",scopeID:"unknown",hostSessionID:"fixture-host")
  do {_=try await service.test(.dsh,scope:"unknown-dsh",images:[image]);preconditionFailure("DSH unknown accepted")}
  catch RustChatClient.ClientError.unknownExecution {}
  do {_=try await service.test(.dsh,scope:"unknown-dsh");preconditionFailure("DSH unknown replayed")}
  catch RustChatClient.ClientError.busy {}
  try await client.reset(backend:"dsh",scopeID:"unknown-dsh",hostSessionID:"fixture-host")
  let identity=RustChatClient.Identity(backend:"codex",scopeID:"cancel",hostSessionID:"fixture-host",requestID:UUID().uuidString)
  let task=Task {try await client.run(identity:identity,executable:"/fixture/executable",environment:["LANG":"C"],input:"prompt",userText:"user")}
  try await Task.sleep(for:.milliseconds(80))
  let start=Date();try await client.cancel();precondition(Date().timeIntervalSince(start)>=0.1)
  let result=try await task.value;precondition(result.state=="cancelled")
  let cancelledIdentity=RustChatClient.Identity(backend:"codex",scopeID:"cancel",hostSessionID:"fixture-host",requestID:UUID().uuidString)
  let cancelledTask=Task {try await client.run(identity:cancelledIdentity,executable:"/fixture/executable",environment:["LANG":"C"],input:"prompt",userText:"user")}
  try await Task.sleep(for:.milliseconds(80));cancelledTask.cancel()
  let cancelledResult=try await cancelledTask.value;precondition(cancelledResult.state=="cancelled")
  _=try await service.test(.pi,scope:"after-cancel")
  print("PASS actual ordinary producer: six backends/import/image/unknown/cancel-reap")
 }
}
