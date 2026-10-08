import CryptoKit
import Darwin
import Foundation
import WorldRuntime

/// One private DB per legacy UI context: the old harness deliberately reuses
/// worldID "a" for incompatible initial worlds. No state is reduced here.
@MainActor final class PrivatePropEditorAuthority {
    static var instances: [PrivatePropEditorAuthority] = []
    let root: URL
    let endpoint: URL
    let client: RustWorldPropClient
    private let process = Process()
    private var imported = false
    private var identity: RustWorldPropClient.Identity?
    init() {
        let base = CommandLine.arguments.count >= 3 ? URL(fileURLWithPath:CommandLine.arguments[2]).deletingLastPathComponent() : URL(fileURLWithPath:NSTemporaryDirectory())
        root = base.appendingPathComponent("gmgn-private-prop-editor-"+UUID().uuidString)
        endpoint = root.appendingPathComponent("taskd.endpoint.json")
        client = RustWorldPropClient(endpointFile:endpoint)
        Self.instances.append(self)
    }
    static func stopAll() {
        var importedContexts=0,commands=0,usedIntents=0
        for item in instances {
            if item.process.isRunning {item.process.terminate();item.process.waitUntilExit()}
            if item.process.processIdentifier > 0 {
                let pid = item.process.processIdentifier
                precondition(kill(pid,0) == -1 && errno == ESRCH,"private daemon PID survived stop")
                precondition(kill(-pid,0) == -1 && errno == ESRCH,"private daemon process group survived stop")
            }
            if item.imported {
                importedContexts += 1
                let files=(try? FileManager.default.contentsOfDirectory(at:item.root,includingPropertiesForKeys:nil)) ?? []
                if let database=files.first(where:{$0.pathExtension=="sqlite" || $0.pathExtension=="sqlite3"}) {
                    let reader=Process(),pipe=Pipe()
                    reader.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3")
                    reader.arguments=["-readonly",database.path,"SELECT COUNT(*) FROM world_prop_commands; SELECT COUNT(*) FROM world_prop_intents WHERE used=1;"]
                    reader.standardOutput=pipe
                    do {
                        try reader.run();reader.waitUntilExit()
                        Swift.precondition(reader.terminationStatus==0,"private SQLite evidence read failed")
                        let values=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).split(separator:"\n").compactMap{Int($0)}
                        Swift.precondition(values.count==2,"private SQLite evidence malformed")
                        commands += values[0];usedIntents += values[1]
                    } catch {Swift.preconditionFailure("private SQLite evidence unavailable: \(error)")}
                } else {Swift.preconditionFailure("private authority database missing")}
            }
            try? FileManager.default.removeItem(at:item.root)
        }
        if importedContexts>0 {
            Swift.precondition(commands==usedIntents,"command/intents evidence mismatch")
            print("ACTUAL SQLite: importedContexts=\(importedContexts) committedCommands=\(commands) consumedUIIntents=\(usedIntents); owned PID/process groups reaped")
        }
        instances.removeAll()
    }
    private func raw(_ method: String, _ params: [String:Any]) async throws -> Data {
        struct Endpoint: Decodable {let address:String;let token:String}
        let value = try JSONDecoder().decode(Endpoint.self,from:Data(contentsOf:endpoint))
        guard value.address.hasPrefix("127.0.0.1:") else {throw RustWorldPropError.invalidResponse}
        var request=URLRequest(url:URL(string:"http://"+value.address+"/rpc")!)
        request.httpMethod="POST";request.setValue("Bearer "+value.token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"method":method,"params":params])
        let bytes=try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Data,Error>) in
            let transport=TaskdHTTPTransport(streaming:false,receive:{continuation.resume(returning:$0)},completion:{error in
                if let error {continuation.resume(throwing:error)}
            });transport.start(request)
        }
        let envelope=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        if let error=envelope["error"] as? [String:Any] {throw RustWorldPropError.rejected(error["code"] as? String ?? "unknown")}
        guard let result=envelope["result"] else {throw RustWorldPropError.invalidResponse}
        return try JSONSerialization.data(withJSONObject:result)
    }
    func ensure(_ state: WorldState, identity: RustWorldPropClient.Identity) async throws {
        if imported {return}
        guard CommandLine.arguments.count >= 3 else {throw RustWorldPropError.unavailable}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // The child becomes its own process group before exec; this wrapper has
        // no authority rules and never executes a model or the user app.
        process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments=["-c","import os,sys;\nif os.getpgrp()!=os.getpid(): os.setsid()\nos.execv(sys.argv[1],sys.argv[1:])",CommandLine.arguments[1],
            "--root",root.path,"--endpoint-file",endpoint.path,"--concurrency","1"]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run()
        try String(process.processIdentifier).write(to:root.appendingPathComponent("owned.pid"),atomically:true,encoding:.utf8)
        var ready=false
        for _ in 0..<300 {
            if !process.isRunning {throw RustWorldPropError.unavailable}
            if FileManager.default.fileExists(atPath:endpoint.path), (try? await raw("capability_contract",[:])) != nil {ready=true;break}
            try await Task.sleep(for:.milliseconds(20))
        }
        guard ready else {throw RustWorldPropError.unavailable}
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .millisecondsSince1970
        let bytes=try encoder.encode(state)
        _ = try await raw("world_import",["worldID":state.worldID,"requestID":"private-editor-import",
            "packageID":"private-native-editor-fixture","packageVersion":"1","stateJson":String(decoding:bytes,as:UTF8.self),
            "stateSha256":SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()])
        self.identity=identity;imported=true
    }
    func facts(for state: WorldState) async throws -> Data {
        let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
        for blob in fixture["blobs"] as! [[String:String]] {
            let path=root.appendingPathComponent(blob["hash"]!+".glb")
            if !FileManager.default.fileExists(atPath:path.path) {
                try FileManager.default.copyItem(at:URL(fileURLWithPath:blob["path"]!),to:path)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
            }
            try await client.putBlob(localPath:path.path,sha256:blob["hash"]!)
        }
        var facts=fixture["facts"] as! [String:Any]
        let mesh=(facts["objects"] as! [String:Any])["cup"]!
        facts["objects"]=Dictionary(uniqueKeysWithValues:state.objectStates.keys.map{($0,mesh)})
        return try JSONSerialization.data(withJSONObject:facts)
    }
}
