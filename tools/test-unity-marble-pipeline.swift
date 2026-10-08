import Foundation
import WorldRuntime

@main struct MarblePipelineRegression {
    @MainActor static func settle(_ bridge: UnityMarbleWorldBridge, line: Int = #line) async throws {
        for _ in 0..<500 {
            if bridge.snapshot["marbleWorking"] as? Bool == false { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        FileHandle.standardError.write(Data("settle timeout caller line \(line), snapshot \(bridge.snapshot)\n".utf8))
        preconditionFailure("fixture did not finish")
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let base = URL(string: CommandLine.arguments[2])!
        let fixture = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let authorityEndpoint = CommandLine.arguments[4]
        func makeControl(_ owner: String) -> RustMarbleControlClient {
            RustMarbleControlClient(endpointFile: authorityEndpoint, helperPath: "/unused", allowsLaunching: false,
                owner: owner, hostSessionID: "private-pipeline-host")
        }
        let control = makeControl("marble.pipeline")
        let geometry = control.makeGeometryClient()
        let blobRoot = URL(fileURLWithPath: authorityEndpoint).deletingLastPathComponent().appendingPathComponent("blobs", isDirectory: true)
        if CommandLine.arguments.count > 5, CommandLine.arguments[5] == "reopen" {
            let stored = try await control.read()
            precondition(stored.task?.status == "completed")
            precondition(stored.task?.operationID == nil)
            let receipt = stored.presetPackages["dj_house"]!
            precondition(receipt.worldID == "world-exact")
            let directory = UnityMarblePackageBuilder.packageRoot(root: root, worldID: receipt.worldID)
            let bytes = try Data(contentsOf: directory.appendingPathComponent("world.json"))
            precondition(UnityMarblePackageBuilder.digest(bytes) == receipt.manifestSHA256)
            let state = try WorldAuthorityClient(worldID: receipt.worldID, endpointFile: authorityEndpoint, helperPath: "/unused", allowsLaunching: false).snapshot()!
            precondition(state.state.weather == .rain)
            precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("gmgn radio/MarbleOperations/pending.json").path))
            precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("gmgn radio/WorldRegistrations").path))
            print("PASS same private SQLite daemon restart: durable package binding, evolved world, no legacy pending/seed writes or provider replay")
            return
        }
        let registration = UnityMarbleAuthorityRegistration(services: { id in
            UnityMarbleAuthorityRegistration.Services(client: WorldAuthorityClient(worldID: id, endpointFile: authorityEndpoint, helperPath: "/unused", allowsLaunching: false))
        })
        let client = MarbleWorldClient(baseURL: base, suppliedAPIKey: "isolated-http-key")
        let cache = MarbleWorldCache(rootURL: root.appendingPathComponent("download-cache"))
        let services = UnityMarbleWorldBridge.Services(http: { action in
            let fact = await client.executePlannedHTTP(method: action.method!, path: action.path!, body: try action.bodyData)
            if let status = fact.statusCode, let body = fact.body { return .init(statusCode: status, body: body) }
            return .init(transportErrorCode: fact.transportErrorCode ?? "transport_error")
        }, prepare: { world in try await UnityMarblePackageBuilder.prepare(world: try world.nativeWorld(), root: root, cache: cache, geometry: geometry, blobRoot: blobRoot) })
        let name = "gmgn-marble-pipeline-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = RustProductSettingsClient(root: URL(fileURLWithPath: authorityEndpoint).deletingLastPathComponent(), allowsLaunching: false)
        let library = UnitySpaceLibraryBridge(registeredPackageRoots: [], defaults: defaults,
            selectedWorldID: { nil }, requestSelection: { _,_ in false }, settings: settings)
        try await settings.ensureLoaded()
        var registrations = 0
        let bridge = UnityMarbleWorldBridge(root: root, authority: control, blobRoot: blobRoot, services: services, runtimeReady: { true }, register: { package in
            registrations += 1
            precondition(package.manifest.worldID == "world-exact")
            precondition(WorldPackageValidator().validate(package.manifest, packageRoot: package.packageRoot).isEmpty)
            precondition(try! UnityMarbleRuntimeDocument.load(package: package) != nil)
            return try await registration.register(package)
        }, onRegistered: { library.registerPackage($0) })
        try await settle(bridge)
        do {
            let current = try await control.read()
            _ = try await control.command("space.marble.generate", expectedRevision: current.revision, presetID: "unknown")
            preconditionFailure("unknown preset accepted by authority")
        } catch {}
        precondition(bridge.command(["op":"space.marble.generate","presetID":"dj_house"]))
        precondition(!bridge.command(["op":"space.marble.generate","presetID":"dj_house"]))
        try await settle(bridge)
        precondition(bridge.snapshot["marblePhase"] as? String == "registered", String(describing: bridge.snapshot))
        precondition(registrations == 1 && library.package(for: "world-exact") != nil,
            "registrations=\(registrations), native package present=\(library.package(for: "world-exact") != nil), projection=\(bridge.snapshot)")
        precondition(library.savedSelectionID == nil, "registration must not silently select")
        let restored = UnityMarblePackageBuilder.registeredRoots(root: root)
        precondition(restored.count == 1)
        let authority = WorldAuthorityClient(worldID: "world-exact", endpointFile: authorityEndpoint, helperPath: "/unused", allowsLaunching: false)
        let originalRecord = try authority.snapshot()!
        let originalImports = try authority.facts(after: 0).facts.filter { $0.kind == "world.imported" }
        precondition(originalImports.count == 1)
        var evolved = originalRecord.state
        evolved.revision += 1; evolved.weather = .rain
        _ = try authority.commit(state: evolved, expectedRevision: originalRecord.recordRevision, intent: ["kind":"isolated-fixture-weather"])
        let registeredPackage = library.package(for: "world-exact")!
        let acceptedExisting = try await registration.register(registeredPackage)
        precondition(acceptedExisting)
        precondition(try! authority.snapshot()!.state.weather == .rain, "idempotent registration must preserve evolved authoritative state")
        precondition(try! authority.facts(after: 0).facts.filter { $0.kind == "world.imported" }.count == 1)
        let wrongPackageRegistration = UnityMarbleAuthorityRegistration(services: { _ in
            var service = UnityMarbleAuthorityRegistration.Services(client: authority)
            service.facts = { cursor in
                let page = try authority.facts(after: cursor)
                return (page.facts.map { fact in
                    guard fact.kind == "world.imported" else { return fact }
                    var payload = fact.payload; payload["packageID"] = "different-package"
                    return WorldAuthorityFact(sequence: fact.sequence, id: fact.id, kind: fact.kind, subjectDomain: fact.subjectDomain,
                        subjectKey: fact.subjectKey, revision: fact.revision, payload: payload, producer: fact.producer, atMilliseconds: fact.atMilliseconds)
                }, page.nextCursor)
            }
            return service
        })
        do { _ = try await wrongPackageRegistration.register(registeredPackage); preconditionFailure("wrong package provenance accepted") }
        catch UnityMarbleError.packageConflict {}
        let wrongHashRegistration = UnityMarbleAuthorityRegistration(services: { _ in
            var service = UnityMarbleAuthorityRegistration.Services(client: authority)
            service.snapshot = {
                let record = try authority.snapshot()!
                return WorldAuthorityRecord(recordRevision: record.recordRevision, boundarySeq: record.boundarySeq,
                    stateSha256: String(repeating: "a", count: 64), state: record.state)
            }
            return service
        })
        let wrongHashAccepted = try await wrongHashRegistration.register(registeredPackage)
        precondition(!wrongHashAccepted, "unconfirmed authoritative digest accepted")
        precondition(try! authority.snapshot()!.state.weather == .rain)
        let reopened = UnityMarbleWorldBridge(root: root, authority: control, blobRoot: blobRoot, services: services, runtimeReady: { true }, register: { _ in false }, onRegistered: { _ in false })
        try await settle(reopened)
        precondition(reopened.snapshot["marbleOperationID"] is NSNull, "success retires operation identity")
        reopened.close()
        let repeatedPreset = try await bridge.activatePreset(.djHouse)
        precondition(repeatedPreset.manifest.worldID == "world-exact", "preset reactivation must reuse formal package without new paid call")
        var badServices = services
        badServices.http = { _ in .init(statusCode: 200, body: Data(#"{"operation_id":"no-result","done":true}"#.utf8)) }
        let bad = UnityMarbleWorldBridge(root: root, authority: makeControl("identity-failure"), blobRoot: blobRoot, services: badServices, runtimeReady: { true }, register: { _ in preconditionFailure("missing identity registered") }, onRegistered: { _ in false })
        try await settle(bad)
        precondition(bad.command(["op":"space.marble.generate","presetID":"dj_house"]))
        try await settle(bad)
        precondition(bad.snapshot["marblePhase"] as? String == "failed")
        let badState = try await makeControl("identity-failure").read()
        precondition(badState.task?.package == nil)
        bad.close()
        var cancelServices = services
        cancelServices.http = { _ in .init(statusCode: 200, body: Data(#"{"operation_id":"pending","done":false}"#.utf8)) }
        let cancelControl = makeControl("cancelled")
        let cancelled = UnityMarbleWorldBridge(root: root, authority: cancelControl, blobRoot: blobRoot, services: cancelServices, runtimeReady: { true }, register: { _ in false }, onRegistered: { _ in false })
        try await settle(cancelled)
        precondition(cancelled.command(["op":"space.marble.generate","presetID":"dj_house"]))
        for _ in 0..<100 {
            if cancelled.snapshot["marbleOperationID"] as? String == "pending" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(cancelled.command(["op":"space.marble.cancel"]))
        try await settle(cancelled)
        precondition(cancelled.snapshot["marblePhase"] as? String == "cancelled_remote_operation_may_continue")
        let recover = UnityMarbleWorldBridge(root: root, authority: cancelControl, blobRoot: blobRoot, services: cancelServices, runtimeReady: { true }, register: { _ in false }, onRegistered: { _ in false })
        try await settle(recover)
        precondition(recover.snapshot["marblePhase"] as? String == "cancelled_remote_operation_may_continue")
        do {
            let current = try await cancelControl.read()
            _ = try await cancelControl.command("space.marble.generate", expectedRevision: current.revision, presetID: "dj_house")
            preconditionFailure("pending remote operation silently replayed")
        } catch {}
        recover.close(); cancelled.close()
        let confirmedWorlds = try await control.read()
        let world = try confirmedWorlds.worlds.first(where: { $0.id == "world-exact" })!.nativeWorld()
        let reject = UnityMarbleWorldBridge(root: root, authority: makeControl("registration-rejected"), blobRoot: blobRoot, services: services, runtimeReady: { true }, register: { _ in false }, onRegistered: { _ in preconditionFailure("rejected registration appeared") })
        try await settle(reject)
        precondition(reject.command(["op":"space.marble.import","worldID":world.id]))
        try await settle(reject)
        precondition(reject.snapshot["marbleError"] as? String != nil, "native publication rejection must remain visible")
        let gated = UnityMarbleWorldBridge(root: root, authority: makeControl("gated"), blobRoot: blobRoot, services: services, runtimeReady: { false }, register: { _ in false }, onRegistered: { _ in false })
        precondition(gated.snapshot["generationSupported"] as? Bool == false)
        precondition(!gated.command(["op":"space.marble.generate","presetID":"dj_house"]))
        precondition(!gated.command(["op":"space.marble.import","worldID":world.id]))
        gated.close()
        var wrongServices = services
        wrongServices.http = { _ in .init(statusCode:200,body:Data(#"{"world":{"world_id":"wrong-result","assets":{}}}"#.utf8)) }
        let wrong = UnityMarbleWorldBridge(root: root, authority: makeControl("wrong-world"), blobRoot: blobRoot, services: wrongServices, runtimeReady: { true }, register: { _ in preconditionFailure("wrong world registered") }, onRegistered: { _ in false })
        try await settle(wrong)
        precondition(wrong.command(["op":"space.marble.import","worldID":world.id]))
        try await settle(wrong)
        precondition(wrong.snapshot["marblePhase"] as? String == "failed")
        wrong.close()
        var rejectedServices = services
        rejectedServices.http = { _ in .init(statusCode:401,body:Data(#"{"error":"isolated-secret-do-not-expose"}"#.utf8)) }
        let rejectedHTTP = UnityMarbleWorldBridge(root: root, authority: makeControl("rejected-http"), blobRoot: blobRoot, services: rejectedServices, runtimeReady: { true }, register: { _ in false }, onRegistered: { _ in false })
        try await settle(rejectedHTTP)
        precondition(rejectedHTTP.command(["op":"space.marble.import","worldID":world.id]))
        try await settle(rejectedHTTP)
        precondition(rejectedHTTP.snapshot["marbleError"] as? String != nil)
        precondition(!(rejectedHTTP.snapshot["marbleError"] as? String ?? "").contains("isolated-secret-do-not-expose"))
        rejectedHTTP.close()
        let invalid = fixture.appendingPathComponent("invalid.spz")
        try Data("invalid".utf8).write(to: invalid)
        do { _ = try await UnityMarblePackageBuilder.publish(world: world, splat: invalid, collider: fixture.appendingPathComponent("collider.glb"), root: root, geometry: geometry, blobRoot: blobRoot); preconditionFailure("invalid SPZ accepted") }
        catch { precondition(UnityMarblePackageBuilder.registeredRoots(root: root).count == 1) }
        for name in ["unsupported-v3", "over-limit", "unsupported-sh", "unsupported-bits"] {
            do { try UnityMarbleSPZFormat.requireRuntimeSupported(fixture.appendingPathComponent(name + ".spz")); preconditionFailure("unsupported runtime format accepted: " + name) }
            catch UnityMarbleError.invalidGeometry {}
        }
        do { _ = try await UnityMarblePackageBuilder.publish(world: world, splat: fixture.appendingPathComponent("scene.spz"), collider: fixture.appendingPathComponent("invalid-collider.glb"), root: root, geometry: geometry, blobRoot: blobRoot); preconditionFailure("invalid GLB accepted") }
        catch GLBColliderError.invalidHeader {}
        let registeredSplat = restored[0].appendingPathComponent("scene.spz")
        let original = try Data(contentsOf: registeredSplat)
        try Data("tampered".utf8).write(to: registeredSplat)
        precondition(UnityMarblePackageBuilder.registeredRoots(root: root).isEmpty, "modified resources must fail restart catalog validation")
        try original.write(to: registeredSplat)
        precondition(UnityMarblePackageBuilder.registeredRoots(root: root).count == 1)
        bridge.close(); reject.close(); library.close()
        print("PASS exact operation identity, production HTTP download/decode/hash package, real isolated authority import/facts/hash readback, evolved-state idempotence, no implicit selection, restart/preset reuse, invalid assets, failed registration and cancellation receipt")
    }
}
