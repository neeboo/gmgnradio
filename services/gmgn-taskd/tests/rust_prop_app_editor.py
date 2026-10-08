#!/usr/bin/env python3
"""Actual App UI helper + actual Swift HTTP client; private platform/model boundary."""
from pathlib import Path
import json, os, subprocess, tempfile, threading, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
repo = Path(__file__).resolve().parents[3]
source = (repo / "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift").read_text()
def method(name):
    start = source.index("    private func " + name)
    body = source.index("{", start); depth = 1; end = body + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}"); end += 1
    return source[start:end].replace("private func", "func", 1)
token = str(uuid.uuid4()); calls = []; active = None
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        assert self.headers["Authorization"] == "Bearer " + token
        wire = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        m, p = wire["method"], wire["params"]; calls.append(m)
        assert p["worldID"] == "actual-world"
        state = json.loads((fixture_root / "state.json").read_text())
        if m == "world_snapshot": result = {"record":{"recordRevision":7,"state":state}}
        else:
            assert p["residentScope"] == "resident.world.YWN0dWFsLXdvcmxk" and p["hostSessionID"] == "actual-host"
            assert p["expectedRevision"] == 7
            if m == "world_prop_observe":
                assert p["layoutRevision"] == 3 and p["facts"] == {"actualPlatformBoundary":True}
                result = {"geometryID":"actual-loaded-measurement","meshSHA256":"a"*64,"layoutRevision":3}
            elif m == "world_prop_ui_intent":
                assert p["expectedLayoutRevision"] == 3
                global active
                active = p["command"]; result = {"intentID":"actual-intent","capability":"actual-cap","expiresAtMS":12345}
                assert active["op"] in ["hold","dropHeld","delete"]
                assert "candidate" not in active and "allowed" not in active
                if active["op"] == "dropHeld": assert "position" not in active
            else:
                assert m == "world_prop_command" and p["authority"] == {"kind":"ui","intentID":"actual-intent","capability":"actual-cap"}
                assert "command" not in p and "candidate" not in p
                if active["op"] == "delete": assert "geometryID" not in p
                else: assert p["geometryID"] == "actual-loaded-measurement"
                state["layoutRevision"] = 4
                result = {"receipt":{"op":active["op"]},"commit":{"revision":8},"snapshot":{"record":{"recordRevision":8,"state":state}}}
        payload = json.dumps({"jsonrpc":"2.0","id":wire["id"],"result":result}).encode()
        self.send_response(200); self.send_header("Content-Length",str(len(payload))); self.end_headers(); self.wfile.write(payload)
swift = r'''
import Foundation
import WorldRuntime
enum ResidentPropPlacementError: Error { case inactiveContext }
@MainActor final class WorldAgentContext {
 struct Manifest { let worldID = "actual-world" }; let manifest = Manifest()
 var state: WorldState; var adopted = 0
 init(_ state: WorldState) { self.state = state }
 struct Snapshot: Decodable { struct Record: Decodable {let state:WorldState;let recordRevision:UInt64};let record:Record }
 func rustPropAuthoritySnapshot(client:RustWorldPropClient,identity:RustWorldPropClient.Identity) async throws -> (WorldState,UInt64) {
  let d=JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970
  let v=try d.decode(Snapshot.self,from:await client.snapshot(identity)); return (v.record.state,v.record.recordRevision)
 }
 func adoptRustPropReceipt(_ data:Data) async throws {
  struct Receipt:Decodable {let snapshot:Snapshot}; let d=JSONDecoder();d.dateDecodingStrategy = .millisecondsSince1970
  state=try d.decode(Receipt.self,from:data).snapshot.record.state;adopted += 1
 }
}
@MainActor final class ActualAppHelper {
 let residentNativePropAuthority:RustWorldPropClient; let residentAuthorityHostSessionID="actual-host"
 let context:WorldAgentContext;let editorID=UUID();var current=true
 init(_ endpoint:URL,_ context:WorldAgentContext){residentNativePropAuthority=RustWorldPropClient(endpointFile:endpoint);self.context=context}
 func isResidentPropEditorCurrent(context:WorldAgentContext,editorID:UUID)->Bool {current && context === self.context && editorID == self.editorID}
 func residentRustPropFacts(context:WorldAgentContext,client:RustWorldPropClient) async throws -> Data {Data("{\"actualPlatformBoundary\":true}".utf8)}
 __METHODS__
}
@main struct Fixture {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  var state=WorldState(revision:1,worldID:"actual-world",worldTime:Date(timeIntervalSince1970:0),lastObservedWallTime:Date(timeIntervalSince1970:0),weather:.clear,agentTransform:WorldTransform(position:.init(x:0,y:0,z:0),rotation:.init(x:0,y:0,z:0,w:1),scale:.init(x:1,y:1,z:1)))
  state.layoutRevision=3;let e=JSONEncoder();e.dateEncodingStrategy = .millisecondsSince1970
  try e.encode(state).write(to:root.appendingPathComponent("state.json"))
  let context=WorldAgentContext(state),host=ActualAppHelper(root.appendingPathComponent("endpoint.json"),context)
  let calibration=WorldPropGripCalibration(avatarAssetID:"actual-avatar",hand:.rightHand,normalizedGrip:.init(x:0,y:0,z:0),localOffset:.init(x:0,y:0,z:0),localRotation:.init(x:0,y:0,z:0,w:1))
  let commands:[WorldPropLayoutCommand]=[.hold(objectID:"sword",avatarAssetID:"actual-avatar",calibration:calibration),.dropHeld(objectID:"sword",avatarAssetID:"actual-avatar",placement:.init(surfaceID:"model-proposed",position:.init(x:999,y:999,z:999),yaw:99)),.delete(objectID:"sword",reason:"actual pointer delete")]
  for (index,command) in commands.enumerated() {
   try await host.commitResidentRustPropUI(host.residentPropUICommand(command),context:context,editorID:host.editorID,layoutRevision:3,requestID:"actual-ui-\(index)")
  }
  assert(context.adopted == 3)
  host.current=false
  do {try await host.commitResidentRustPropUI(host.residentPropUICommand(.withdraw(objectID:"sword")),context:context,editorID:host.editorID,layoutRevision:3,requestID:"stale");fatalError("stale editor submitted")} catch ResidentPropPlacementError.inactiveContext {}
  print("PASS production App helpers: hold/drop/delete -> Rust typed cap/receipt; no drop candidate, stale editor denied")
 }
}
'''
swift = swift.replace("__METHODS__", "\n".join(method(n) for n in ["residentPropUIIdentity(","residentPropUICommand(","commitResidentRustPropUI("]))
with tempfile.TemporaryDirectory(prefix="gmgn-private-app-prop-") as directory:
    fixture_root = Path(directory)
    server = ThreadingHTTPServer(("127.0.0.1",0),Handler); threading.Thread(target=server.serve_forever,daemon=True).start()
    endpoint = fixture_root / "endpoint.json"; endpoint.write_text(json.dumps({"version":2,"address":"127.0.0.1:"+str(server.server_port),"token":token})); os.chmod(endpoint,0o600)
    generated = fixture_root / "fixture.swift"; generated.write_text(swift)
    flags = subprocess.check_output(["bash","tools/world-runtime-harness-flags.sh"],cwd=repo,text=True).splitlines()
    binary = fixture_root / "fixture"
    subprocess.run(["swiftc","-swift-version","6","-parse-as-library",*flags,str(repo/"apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift"),str(repo/"apps/macos/Sources/GMGNRadio/Presence/RustWorldPropClient.swift"),str(generated),"-o",str(binary)],check=True)
    subprocess.run([str(binary),str(fixture_root)],check=True)
    assert calls == ["world_snapshot","world_prop_observe","world_prop_ui_intent","world_prop_command"]*2 + ["world_snapshot","world_prop_ui_intent","world_prop_command"]
    server.shutdown()
