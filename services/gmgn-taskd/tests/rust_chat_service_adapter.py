#!/usr/bin/env python3
"""Swift 6 test of the actual ordinary-chat producer and client; no native CLI."""
import pathlib, subprocess, tempfile, threading, http.server, json, time, base64
ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift'
IMAGE = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZAAAAABJRU5ErkJggg==')
def declaration(source, marker):
    start = source.index(marker); end = source.index('{', start) + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]
class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        p = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method = self.path.rsplit('/', 1)[-1]
        with self.server.lock:
            self.server.calls.append(method)
            assert not set(p) & {'worldID','runID','eventID','residentScope'}
            assert p['scopeID'] and p['hostSessionID']
            if method == 'agent_chat_import':
                key = p['backend'] + p['scopeID']; self.server.imports[key] = self.server.imports.get(key, 0) + 1
                result = {'imported': True}
            elif method == 'agent_chat_start':
                assert p['executable'] == ('/fixture/node' if p['backend']=='dsh' else '/fixture/executable')
                if p['backend']=='dsh':
                    assert p['dshEntryPoint']=='/fixture/acp.js' and p['persona']=='fixture-persona'
                else: assert 'dshEntryPoint' not in p and 'persona' not in p
                assert p['environment'] == {'LANG':'C'}
                assert p['input'] == 'prompt' and p['userText'] == 'user'
                for image in p['images']:
                    file = pathlib.Path(image)
                    assert 'ChatImages' in file.parts and file.read_bytes() == IMAGE
                    assert file.stat().st_mode & 0o777 == 0o600
                    assert file.parent.stat().st_mode & 0o777 == 0o700
                self.server.rows[p['requestID']] = {'state': 'unknown' if p['scopeID'].startswith('unknown') else 'running' if p['scopeID']=='cancel' else 'completed', 'reply':'answer'}
                result = {'requestID':p['requestID'], 'state':self.server.rows[p['requestID']]['state']}
            elif method == 'agent_chat_read': result = self.server.rows[p['requestID']]
            elif method == 'agent_chat_cancel':
                time.sleep(.12)  # Private fixture simulates owned process reap.
                self.server.rows[p['requestID']]['state'] = 'cancelled'; result = {'cancelled':True}
            elif method == 'agent_chat_reset':
                self.server.rows.clear(); result = {'reset':True}
            else: raise AssertionError(method)
        data = json.dumps(result).encode(); self.send_response(200); self.end_headers(); self.wfile.write(data)
source = SOURCE.read_text()
assert 'if !toolsAvailable && !(id == .dsh && !imageURLs.isEmpty)' not in source
assert 'if !toolsAvailable {\n            return try await sendRustPlainChat' in source
methods = '\n'.join(declaration(source, m) for m in ('    private func sendRustPlainChat(', '    private func notePlainChatTerminal(', '    private func restorePlainChatIdentity('))
transport = pathlib.Path(__file__).with_name('rust_codex_swift_client.swift').read_text().split('actor CLISink')[0]
stubs = '''
struct TaskdHTTPAuthorityClient: Sendable {
 init(endpointFile:String,helperPath:String,allowsLaunching:Bool,timeout:Double) {}
 func call(method:String,params:[String:Any])throws->[String:Any] { fatalError("formal transport forbidden") }
}
enum AgentConversationBackendID:String,Sendable,CaseIterable {case codex,workbuddy,qoder,pi,dsh,claudeCode}
enum AgentConversationError:Error {case backendNotInstalled(AgentConversationBackendID), imagesUnsupported(AgentConversationBackendID),imageFormatUnsupported,emptyReply,cancelled,dshTextTransportUnavailable}
struct AgentConversationOutcome:Sendable {let reply:String;let sessionID:String?}
struct Backend {let executableNames:[String]}
enum AgentConversationBackends {static func backend(for id:AgentConversationBackendID)->Backend {Backend(executableNames:[id.rawValue])}}
struct Locator:Sendable {func locate(executableNames:[String])->URL? {URL(fileURLWithPath:"/fixture/executable")}}
enum ResidentDSHComposition {static func locateNativeTransport(using:Locator,environment:[String:String])->(node:URL,entry:URL)? {(URL(fileURLWithPath:"/fixture/node"),URL(fileURLWithPath:"/fixture/acp.js"))}}
struct ResidentPreferences {let persona="fixture-persona"}
@MainActor final class Preferences {var reads=0;func sessionID(for backend:AgentConversationBackendID,scope:String?)->String? {reads += 1; return "old"}}
@MainActor final class AgentConversationService {
 let plainChatClient:RustChatClient; let plainChatRoot:URL; let plainChatHostSessionID="fixture-host"
 let plainChatEnvironment:@Sendable()->[String:String] = {["LANG":"C","NODE_OPTIONS":"forbidden"]}
 let locator=Locator();let preferences=Preferences()
 let residentPreferences=ResidentPreferences()
 var plainChatMaintenance:Task<Void,Never>?;var plainChatIdentity:RustChatClient.Identity?;var plainChatControlScope:String?
 var plainChatTerminalRequests=Set<String>();var plainChatLegacyRead=Set<String>();var plainChatLegacySessions:[String:String]=[:]
 init(client:RustChatClient,root:URL){plainChatClient=client;plainChatRoot=root}
 func run(_ op:@escaping @Sendable ()async throws->AgentConversationOutcome)async throws->AgentConversationOutcome {try await op()}
 func test(_ backend:AgentConversationBackendID,scope:String,images:[URL]=[])async throws->String {try await sendRustPlainChat(backend:backend,scopeID:scope,legacyScope:nil,input:"prompt",userText:"user",imageURLs:images)}
'''
with tempfile.TemporaryDirectory(prefix='gmgn-chat-adapter-') as directory:
    generated = pathlib.Path(directory)/'adapter.swift'; generated.write_text(transport+stubs+methods+'\n}\n')
    binary = pathlib.Path(directory)/'test'
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(generated),str(ROOT/'apps/macos/Sources/GMGNRadio/Presence/RustChatClient.swift'),str(pathlib.Path(__file__).with_suffix('.swift')),'-o',str(binary)],check=True)
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture)
    server.lock=threading.Lock();server.calls=[];server.imports={};server.rows={}
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        subprocess.run([str(binary),f'http://127.0.0.1:{server.server_port}',directory],check=True,timeout=30)
        assert all(count==1 for count in server.imports.values()), server.imports
        assert 'agent_chat_cancel' in server.calls and 'agent_chat_reset' in server.calls
    finally: server.shutdown();server.server_close();thread.join()
