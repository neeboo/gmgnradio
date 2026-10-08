import AppKit
import CryptoKit
import Foundation
import ImageIO

// Default launch glue only. The fixture injects the production actor's Call;
// every lifecycle decision is handled by the real private daemon, never a stub.
enum PropGenerationError: Error { case invalidInput }
@MainActor final class UnityWindowModeBridge {
    static let shared = UnityWindowModeBridge()
    var targetWindow: NSWindow? { nil }
}
@main struct AttachmentDaemonChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        let rpc = try PrivateRPC(CommandLine.arguments[1])
        let client = RustChatAttachmentClient(call: { method,params in
            do {return try rpc.call(method,params)}
            catch {FileHandle.standardError.write(Data("private RPC \(method): \(error)\n".utf8));throw error}
        })
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:12,pixelsHigh:12,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let png = bitmap.representation(using:.png,properties:[:])!
        func check(_ value: Bool) {precondition(value)}
        let source = root.appendingPathComponent("source.png");try png.write(to:source)
        func privateDirectory(_ name: String) throws -> URL {
            let path=root.appendingPathComponent(name,isDirectory:true)
            try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);return path
        }
        func failure(_ action: () async throws -> Void) async {
            do {try await action();preconditionFailure("invalid operation accepted")}
            catch { }
        }
        // Production store: native prepares PNGs, but all draft/ref mutations
        // round trip through SQLite, including failed submission restoration.
        let storeDir=try privateDirectory("store")
        let store=ResidentAttachmentStore(directory:storeDir,authority:client)
        await store.add(urls:[source,source]);precondition(store.attachments.count==2,store.errorMessage ?? "attachment registration failed")
        let first=try await store.takeSubmission(text:"first")
        await store.add(imageData:png);await store.add(urls:[source])
        let newIDs=store.attachments.map(\.id)
        check(await store.restoreSubmission(first))
        precondition(store.attachments.map(\.id)==first.attachments.map(\.id)+newIDs)
        await store.add(urls:[source]);precondition(store.attachments.count==4)
        let second=try await store.takeSubmission(text:"second")
        await store.add(urls:[source,source]);let freshIDs=store.attachments.map(\.id)
        check(await store.restoreSubmission(second));precondition(store.attachments.count==6 && !store.canSubmit)
        await failure {_ = try await store.takeSubmission(text:"overflow")}
        let removed=second.attachments[0]
        await store.remove(id:removed.id);precondition(FileManager.default.fileExists(atPath:removed.url.path))
        check(await store.restoreSubmission(second));precondition(!store.attachments.contains(where:{$0.id==removed.id}))
        for id in freshIDs {
            let url=store.attachments.first(where:{$0.id==id})!.url
            await store.remove(id:id);precondition(!FileManager.default.fileExists(atPath:url.path))
        }
        precondition(store.attachments.count==3)
        for image in store.attachments {
            let data=try Data(contentsOf:image.url);precondition(data.count<=8*1024*1024)
            precondition(CGImageSourceCreateWithData(data as CFData,nil) != nil)
            let attrs=try FileManager.default.attributesOfItem(atPath:image.url.path)
            precondition((attrs[.posixPermissions] as! NSNumber).intValue==0o600)
        }
        await store.finishSubmission(id:first.id,state:"unknown")
        await store.finishSubmission(id:second.id,state:"completed")
        await store.close();precondition(store.attachments.isEmpty)
        precondition(first.attachments.allSatisfy{FileManager.default.fileExists(atPath:$0.url.path)})

        // Direct production actor: exact CAS, generation and session rejection.
        let dir=try privateDirectory("actor")
        let identity=RustChatAttachmentClient.Identity(ownerID:"fixture-actor",hostSessionID:"fixture-host")
        var reply=try await client.open(identity,directory:dir.path)
        func register(_ generation: UInt64) async throws -> RustChatAttachmentClient.Attachment {
            let id=UUID(), path=dir.appendingPathComponent("\(UUID()).png")
            try png.write(to:path);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
            reply=try await client.register(identity,revision:reply.snapshot.revision,frameGeneration:generation,attachmentID:id,
                localPath:path.path,sha256:SHA256.hash(data:png).map{String(format:"%02x",$0)}.joined(),byteCount:png.count,displayName:"fixture.png")
            return reply.snapshot.attachments.last!
        }
        let a=try await register(3)
        let badPath=dir.appendingPathComponent("mismatch.png")
        try png.write(to:badPath);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:badPath.path)
        await failure {_ = try await client.register(identity,revision:reply.snapshot.revision,frameGeneration:3,attachmentID:UUID(),
            localPath:badPath.path,sha256:String(repeating:"0",count:64),byteCount:png.count,displayName:"mismatch.png")}
        let link=dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:badPath)
        await failure {_ = try await client.register(identity,revision:reply.snapshot.revision,frameGeneration:3,attachmentID:UUID(),
            localPath:link.path,sha256:SHA256.hash(data:png).map{String(format:"%02x",$0)}.joined(),byteCount:png.count,displayName:"link.png")}
        await failure {_ = try await client.remove(identity,revision:0,attachmentID:UUID(uuidString:a.id)!)}
        await failure {_ = try await register(2)}
        let b=try await register(3)
        let submission=UUID(), selection=[UUID(uuidString:a.id)!,UUID(uuidString:b.id)!]
        await failure {_ = try await client.take(identity,revision:reply.snapshot.revision,submissionID:UUID(),attachmentIDs:Array(selection.reversed()),hasText:false)}
        let issued=try await client.take(identity,revision:reply.snapshot.revision,submissionID:submission,attachmentIDs:selection,hasText:false)
        let duplicate=try await client.take(identity,revision:0,submissionID:submission,attachmentIDs:selection,hasText:false)
        precondition(issued.snapshot.revision==duplicate.snapshot.revision)
        reply=try await client.finish(identity,revision:issued.snapshot.revision,submissionID:submission,state:"unknown")
        await failure {_ = try await client.take(identity,revision:reply.snapshot.revision,submissionID:submission,attachmentIDs:selection,hasText:false)}
        let foreign=RustChatAttachmentClient.Identity(ownerID:identity.ownerID,hostSessionID:"next-host")
        _ = try await client.open(foreign,directory:dir.path)
        await failure {_ = try await client.finish(identity,revision:reply.snapshot.revision,submissionID:submission,state:"completed")}
        await failure {_ = try await client.restore(foreign,revision:reply.snapshot.revision,submissionID:submission)}

        // Production Unity bridge: private named clipboard only, real ImageIO.
        let clipboard=NSPasteboard(name:.init("gmgn-private-attachment-fixture-\(UUID())"));defer{clipboard.releaseGlobally()}
        let bridge=UnityChatImageBridge(directory:try privateDirectory("unity"),authority:client,pasteboard:{clipboard},parentWindow:{nil})
        func ready() async throws {
            for _ in 0..<500 {
                if !(bridge.snapshot()["isPreparing"] as! Bool) {return}
                try await Task.sleep(for:.milliseconds(10))
            }
            throw FixtureFailure.timedOut
        }
        clipboard.clearContents();clipboard.setString("text",forType:.string)
        precondition(!bridge.command(["op":"chat.attachments.pasteIfImage"]))
        clipboard.clearContents();clipboard.setData(png,forType:.png)
        precondition(bridge.command(["op":"chat.attachments.pasteIfImage"]));try await ready()
        let snapshot=bridge.snapshot(), images=snapshot["attachments"] as! [[String:String]]
        precondition(images.count==1 && !String(describing:snapshot).contains(root.path))
        let thumbnail=Data(base64Encoded:images[0]["thumbnailPNG"]!)!;precondition(thumbnail.count<=32768)
        precondition(CGImageSourceCreateWithData(thumbnail as CFData,nil) != nil)
        await failure {_ = try await bridge.takeSubmission(text:"",attachmentIDs:images.map{$0["id"]!},generation:0)}
        let own=try await bridge.takeSubmission(text:"",attachmentIDs:images.map{$0["id"]!},generation:snapshot["generation"] as! UInt64)
        let forged=ResidentChatSubmission(text:own.text,attachments:own.attachments)
        check(!(await bridge.restoreSubmission(forged)))
        check(await bridge.restoreSubmission(own))
        precondition(bridge.command(["op":"chat.attachments.remove","id":images[0]["id"]!]))
        try await ready();precondition(FileManager.default.fileExists(atPath:own.attachments[0].url.path))
        clipboard.clearContents();clipboard.writeObjects([source as NSURL])
        precondition(bridge.command(["op":"chat.attachments.pasteIfImage"]));try await ready()
        bridge.close()
        for _ in 0..<500 {
            if (bridge.snapshot()["attachments"] as! [[String:String]]).isEmpty {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        precondition((bridge.snapshot()["attachments"] as! [[String:String]]).isEmpty)
        let closingDir=try privateDirectory("closing"), gate=PreparationGate()
        let closing=ResidentAttachmentStore(directory:closingDir,authority:client,prepare:{url in
            await gate.wait();return try await PropImagePreparation.prepare(url:url)
        })
        let preparation=Task {@MainActor in await closing.add(urls:[source])}
        for _ in 0..<500 {
            if await gate.waiting {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        check(await gate.waiting)
        await closing.close();await gate.release();await preparation.value
        precondition(closing.attachments.isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(atPath:closingDir.path)
        precondition(remaining.isEmpty,"close during preparation leaked an unregistered PNG")
        let lostTake=LostReplyRPC(rpc,method:"chat_attachments_take")
        let takeRecovery=ResidentAttachmentStore(directory:try privateDirectory("lost-take"),authority:RustChatAttachmentClient(call:lostTake.call))
        await takeRecovery.add(urls:[source]);let immutable=takeRecovery.attachments
        let recovered=try await takeRecovery.takeSubmission(text:"lost actual response")
        precondition(recovered.attachments==immutable && takeRecovery.attachments.isEmpty)
        precondition(lostTake.count("chat_attachments_take")==1 && lostTake.count("chat_attachments_read")>=1)
        await takeRecovery.finishSubmission(id:recovered.id,state:"unknown");await takeRecovery.close()
        let lostRemove=LostReplyRPC(rpc,method:"chat_attachments_remove")
        let removeRecovery=ResidentAttachmentStore(directory:try privateDirectory("lost-remove"),authority:RustChatAttachmentClient(call:lostRemove.call))
        await removeRecovery.add(urls:[source]);let unsent=removeRecovery.attachments[0]
        await removeRecovery.remove(id:unsent.id)
        precondition(removeRecovery.attachments.isEmpty && !FileManager.default.fileExists(atPath:unsent.url.path))
        precondition(lostRemove.count("chat_attachments_remove")==1 && lostRemove.count("chat_attachments_read")>=1)
        await removeRecovery.close()
        print("PASS production native attachments → private Rust/SQLite: preparation, CAS/frame/session, exact take, recovery overflow/order, references, private clipboard and cleanup")
    }
}
