import Foundation
import CryptoKit
import WorldRuntime

/// Ready output capabilities are read-only and separate from owned inventory.
/// Completion authorizes a projection, never a claim or a placement.
@MainActor final class UnityWishOutputPreviewCatalog {
    let worldID: String
    private let residentScope: String
    private let taskRoot: URL
    private var work: Task<Void,Never>?
    private var epoch: UInt64 = 0
    private var generation: UInt64 = 0
    private var cached: [String:Any]
    private var fingerprint: Data?
    private let projectionSessionID: String
    private let identity: RustWorldPropClient.Identity
    private let authority: RustWorldPropClient
    var onChange: (@MainActor () -> Void)?
    init(root: URL,worldID: String,residentScope: String,projectionSessionID: String,hostSessionID: String) {
        self.worldID=worldID; self.residentScope=residentScope
        self.projectionSessionID=projectionSessionID
        taskRoot=root.appendingPathComponent("gmgn radio/TaskService",isDirectory:true)
        identity = .init(worldID:worldID,residentScope:residentScope,hostSessionID:hostSessionID)
        authority = RustWorldPropClient(endpointFile: taskRoot.appendingPathComponent("endpoint.json"))
        cached=["worldID":worldID,"generation":UInt64(0),"entries":[[String:Any]]()]
    }
    func update(wishes: [WishMachineJob],jobs: [PropGenerationRecord]) {
        let ready=wishes.filter { $0.stage == .ready && $0.worldID == worldID && $0.residentScope == residentScope }.sorted { $0.id.uuidString < $1.id.uuidString }
        let sourceIDs=Set(ready.compactMap(\.jobID))
        let selectedJobs=jobs.filter { sourceIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        guard let wishData=try? encoder.encode(ready),let jobData=try? encoder.encode(selectedJobs) else { close();return }
        let nextFingerprint=wishData+jobData
        guard fingerprint != nextFingerprint else { return };fingerprint=nextFingerprint
        epoch &+= 1; let current=epoch; work?.cancel()
        // Revoke stale capabilities immediately when a job is claimed/replaced.
        generation &+= 1; cached=["worldID":worldID,"generation":generation,"entries":[[String:Any]]()]
        onChange?()
        work=Task { [weak self] in
            guard let self else { return }
            var entries: [[String:Any]]=[]
            var errors: [[String:String]]=[]
            for wish in ready {
                if Task.isCancelled { return }
                let matching=jobs.filter { $0.id == wish.jobID }
                guard matching.count == 1, let job=matching.first,
                      job.context?.worldID == worldID,job.context?.residentScope == residentScope,
                      job.receipt?.state == .completed,let inspection=job.receipt?.result?.inspection,
                      let path=job.localModelPath,path == wish.modelPath,
                      [job.id.uuidString.lowercased(),job.id.uuidString.uppercased()].contains(where: {
                          path == taskRoot.appendingPathComponent($0+".glb").path
                      }),
                      inspection.sha256.count == 64,inspection.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                      inspection.bytes > 0,inspection.bytes <= 32*1024*1024 else {
                    errors.append(["wishID":wish.id.uuidString,"code":"wish_output_asset_unverified"]);continue
                }
                do {
                    let hash=inspection.sha256.lowercased(),count=inspection.bytes
                    try await Task.detached(priority:.utility) {
                        let url=URL(fileURLWithPath:path)
                        for ancestor in sequence(first:url, next: { value in
                            let parent=value.deletingLastPathComponent(); return parent.path == value.path ? nil : parent
                        }) {
                            let values=try ancestor.resourceValues(forKeys:[.isSymbolicLinkKey]); guard values.isSymbolicLink != true else { throw WishMachineError.unavailable }
                        }
                        let facts=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
                        guard facts.isRegularFile == true,facts.fileSize == count else { throw WishMachineError.unavailable }
                        let bytes=try Data(contentsOf:url,options:.mappedIfSafe)
                        guard bytes.count == count,SHA256.hash(data:bytes).map({ String(format:"%02x",$0) }).joined() == hash else { throw WishMachineError.unavailable }
                    }.value
                    let sample = try await RustPropNativeMeshSampler.sample(modelURL:URL(fileURLWithPath:path))
                    guard sample.sha256 == hash else { throw WishMachineError.unavailable }
                    try await authority.putBlob(localPath:path,sha256:hash)
                    if let collisionPath = job.localCollisionPath {
                        let collision = try await RustPropNativeMeshSampler.sample(modelURL:URL(fileURLWithPath:collisionPath))
                        try await authority.putBlob(localPath:collisionPath,sha256:collision.sha256)
                    }
                    struct Snapshot: Decodable { struct Record: Decodable { let state:WorldState;let recordRevision:UInt64 };let record:Record }
                    struct Preview: Decodable { let prop:WorldGeneratedProp }
                    let decoder = JSONDecoder();decoder.dateDecodingStrategy = .millisecondsSince1970
                    let snapshot = try decoder.decode(Snapshot.self,from:await authority.snapshot(identity))
                    let projected = try await authority.outputPreview(identity,wishID:wish.id.uuidString,
                        expectedRevision:snapshot.record.recordRevision,layoutRevision:snapshot.record.state.layoutRevision,
                        blobRef:hash,triangles:sample.trianglesJSON)
                    let prop = try decoder.decode(Preview.self,from:projected).prop
                    guard !Task.isCancelled,current == epoch else { return }
                    var descriptor=try JSONSerialization.jsonObject(with:JSONEncoder().encode(prop)) as! [String:Any]
                    descriptor.merge(["worldID":worldID,"stage":"ready","wishID":wish.id.uuidString,
                        "projectionSessionID":projectionSessionID,"projectionID":UUID().uuidString,
                        "taskID":job.id.uuidString.lowercased(),"sha256":hash,"bytes":count,"localModelPath":path]) { _,next in next }
                    entries.append(descriptor)
                } catch { errors.append(["wishID":wish.id.uuidString,"code":"wish_output_preview_unavailable"]) }
            }
            guard !Task.isCancelled,current == epoch else { return }
            generation &+= 1; cached=["worldID":worldID,"generation":generation,"entries":entries,"errors":errors]; work=nil
            onChange?()
        }
    }
    func snapshot() -> [String:Any] { cached }
    func close() { epoch &+= 1;work?.cancel();work=nil;fingerprint=nil;generation &+= 1;cached=["worldID":worldID,"generation":generation,"entries":[[String:Any]]()];onChange?();onChange=nil }
}
