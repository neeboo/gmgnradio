import Foundation

/// Native consumption leaf only. It neither validates nor selects configuration.
@MainActor final class PropGenerationStore {
    var errorMessage: String?
    var calls = 0
    var endpoint: URL?
    func configure(endpoint: URL, token: String) throws { calls += 1; self.endpoint = endpoint }
    func clearConfiguration() { endpoint = nil }
}
final class GenerationFault: @unchecked Sendable {
    let rpc: PrivateRPC
    private let lock = NSLock()
    private var lose = false
    private var captured: Data?
    init(_ rpc: PrivateRPC) { self.rpc = rpc }
    func loseNext() { lock.lock();lose=true;lock.unlock() }
    func lostRequest() -> Data { lock.lock();defer{lock.unlock()};return captured! }
    func call(_ method: String, _ data: Data) throws -> Data {
        let output = try rpc.call(method,data)
        lock.lock();let drop=lose && method=="generation_configuration_save"
        if drop { lose=false;captured=data };lock.unlock()
        if drop { throw FixtureFailure.timedOut };return output
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        let rpc=try PrivateRPC(CommandLine.arguments[1])
        let root=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        let secrets=root.deletingLastPathComponent().appendingPathComponent("secrets",isDirectory:true)
        let current=secrets.appendingPathComponent("prop-generation.json")
        let legacy=root.deletingLastPathComponent().appendingPathComponent("legacy.json")
        let authority=RustGenerationConfigurationClient(secretRoot:secrets,call:rpc.call)
        if CommandLine.arguments[3]=="reopen" {
            let receipt=try await authority.load(currentFile:current,legacyFile:legacy)
            let configuration=try await authority.configuration(receipt)
            assert(configuration?.endpoint.port==8192 && receipt.imported)
            print("PASS same SQLite restart selection, no reimport/replay");return
        }
        try FileManager.default.createDirectory(at:secrets,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let raw=try JSONSerialization.data(withJSONObject:["endpoint":"http://127.0.0.1:8191","token":"synthetic-original-token"])
        try raw.write(to:legacy)
        if CommandLine.arguments[3]=="corrupt" { try Data("bad-json".utf8).write(to:current) }
        let store=PropGenerationStore()
        let bridge=UnityGenerationConfigurationBridge(store:store,authority:authority,fileURL:current,readableLegacyFileURL:legacy)
        if CommandLine.arguments[3]=="corrupt" {
            let loaded=await bridge.settingsCommand(["op":"generation.load"]);assert(!loaded)
            assert(store.calls==0 && store.endpoint==nil)
            let corrupt=try Data(contentsOf:current);assert(corrupt==Data("bad-json".utf8))
            let repaired=await bridge.settingsCommand(["op":"generation.save","endpoint":"http://127.0.0.1:8192","token":"synthetic-repaired-token"]);assert(repaired)
            assert(store.calls==1 && store.endpoint?.port==8192)
            bridge.close();print("PASS corrupt current blocks legacy; explicit Rust repair");return
        }
        let loaded=await bridge.settingsCommand(["op":"generation.load"]);assert(loaded)
        assert(store.calls==1 && store.endpoint?.port==8191)
        assert(!FileManager.default.fileExists(atPath:current.path))
        assert(bridge.snapshot["token"]==nil)
        let refused=await bridge.settingsCommand(["op":"generation.save","endpoint":"http://127.0.0.1:8192"]);assert(!refused)
        assert(store.calls==1 && store.endpoint?.port==8191)
        let kept=await bridge.settingsCommand(["op":"generation.save","endpoint":"http://127.0.0.1:8191"]);assert(kept)
        assert(store.calls==2)
        let changed=await bridge.settingsCommand(["op":"generation.save","endpoint":"http://127.0.0.1:8192","token":"synthetic-new-token"]);assert(changed)
        assert(store.calls==3 && store.endpoint?.port==8192)
        for invalid in ["http://external.example","https://example.com/path","https://user:pass@example.com"] {
            do { _=try await authority.save(endpoint:invalid,replacementToken:"synthetic-invalid");fatalError("unsafe endpoint accepted") }catch{}
        }
        let fault=GenerationFault(rpc)
        let lost=RustGenerationConfigurationClient(secretRoot:secrets,call:fault.call)
        _=try await lost.load(currentFile:current,legacyFile:legacy)
        let before=lost.confirmed!.revision
        fault.loseNext()
        do { _=try await lost.save(endpoint:"http://127.0.0.1:8192",replacementToken:"synthetic-loss-token");fatalError("lost receipt published") }catch{}
        assert(lost.confirmed!.revision==before)
        let request=fault.lostRequest()
        assert(!String(decoding:request,as:UTF8.self).contains("synthetic-"))
        let replay=try rpc.call("generation_configuration_save",request)
        let receipt=try JSONDecoder().decode(RustGenerationConfigurationClient.Snapshot.self,from:replay)
        let configuration=try await lost.configuration(receipt)
        assert(receipt.revision==before+1 && configuration?.token=="synthetic-loss-token")
        let directoryMode=try FileManager.default.attributesOfItem(atPath:secrets.path)[.posixPermissions] as! NSNumber
        let file=secrets.appendingPathComponent("generation-\(receipt.secretRef!).secret")
        let mode=try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber
        assert(directoryMode.intValue==0o700 && mode.intValue==0o600)
        bridge.close();let closed=await bridge.settingsCommand(["op":"generation.load"]);assert(!closed)
        print("PASS actual client/Unity consumer load/save, endpoint-token binding, private file, lost receipt exact replay")
    }
}
