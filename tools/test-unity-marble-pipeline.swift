import Foundation
import WorldRuntime

@main struct MarblePipelineRegression {
    @MainActor static func settle(_ bridge: UnityMarbleWorldBridge) async throws {
        for _ in 0..<500 {
            if bridge.snapshot["marbleWorking"] as? Bool == false { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("fixture did not finish")
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let base = URL(string: CommandLine.arguments[2])!
        let fixture = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let authorityEndpoint = CommandLine.arguments[4]
        let registration = UnityMarbleAuthorityRegistration(root: root, services: { id in
            UnityMarbleAuthorityRegistration.Services(client: WorldAuthorityClient(worldID: id, endpointFile: authorityEndpoint, helperPath: "/unused", allowsLaunching: false))
        })
        let provider = MarbleAPIKeyProvider(fileURL: root.appendingPathComponent("secrets/world-labs-api-key"))
        try provider.save("isolated-http-key")
        let client = MarbleWorldClient(baseURL: base, apiKeyProvider: provider)
        let cache = MarbleWorldCache(rootURL: root.appendingPathComponent("download-cache"))
        let services = UnityMarbleWorldBridge.Services(generate: { try await client.generateWorld(preset: $0) },
            operation: { try await client.operation(id: $0) }, world: { try await client.world(id: $0) },
            splat: { try await cache.localSplat(for: $0, asset: $1) }, collider: { try await cache.localCollider(for: $0) }, sleep: {})
        let name = "gmgn-marble-pipeline-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let library = UnitySpaceLibraryBridge(registeredPackageRoots: [], defaults: defaults,
            selectedWorldID: { nil }, requestSelection: { _,_ in false })
        var registrations = 0
        let bridge = UnityMarbleWorldBridge(root: root, services: services, runtimeReady: { true }, register: { package in
            registrations += 1
            precondition(package.manifest.worldID == "world-exact")
            precondition(WorldPackageValidator().validate(package.manifest, packageRoot: package.packageRoot).isEmpty)
            precondition(try! UnityMarbleRuntimeDocument.load(package: package) != nil)
            return try await registration.register(package)
        }, onRegistered: { library.registerPackage($0) })
        precondition(bridge.snapshot["marblePhase"] as? String == "idle")
        precondition(!bridge.command(["op":"space.marble.generate","presetID":"unknown"]))
        precondition(bridge.command(["op":"space.marble.generate","presetID":"dj_house"]))
        precondition(!bridge.command(["op":"space.marble.generate","presetID":"dj_house"]))
        try await settle(bridge)
        precondition(bridge.snapshot["marblePhase"] as? String == "registered", String(describing: bridge.snapshot))
        precondition(registrations == 1 && library.package(for: "world-exact") != nil)
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
        let wrongPackageRegistration = UnityMarbleAuthorityRegistration(root: root, services: { _ in
            var service = UnityMarbleAuthorityRegistration.Services(client: authority)
            service.importState = { _,_,_,_ in preconditionFailure("existing conflicting record was overwritten") }
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
        let wrongHashRegistration = UnityMarbleAuthorityRegistration(root: root, services: { _ in
            var service = UnityMarbleAuthorityRegistration.Services(client: authority)
            service.importState = { _,_,_,_ in preconditionFailure("existing bad digest was overwritten") }
            service.snapshot = {
                let record = try authority.snapshot()!
                return WorldAuthorityRecord(recordRevision: record.recordRevision, boundarySeq: record.boundarySeq,
                    stateSha256: String(repeating: "a", count: 64), state: record.state)
            }
            return service
        })
        do { _ = try await wrongHashRegistration.register(registeredPackage); preconditionFailure("unconfirmed authoritative digest accepted") }
        catch UnityMarbleError.packageConflict {}
        precondition(try! authority.snapshot()!.state.weather == .rain)
        let reopened = UnityMarbleWorldBridge(root: root, services: services, runtimeReady: { true }, register: { _ in false }, onRegistered: { _ in false })
        precondition(reopened.snapshot["marblePhase"] as? String == "idle", "success retires operation receipt")
        reopened.close()
        let repeatedPreset = try await bridge.activatePreset(.djHouse)
        precondition(repeatedPreset.manifest.worldID == "world-exact", "preset reactivation must reuse formal package without new paid call")
        let missingIdentity = try JSONDecoder().decode(MarbleOperation.self, from: Data(#"{"operation_id":"no-result","done":true}"#.utf8))
        var badServices = services
        badServices.generate = { _ in missingIdentity }
        let failureRoot = root.appendingPathComponent("identity-failure")
        let bad = UnityMarbleWorldBridge(root: failureRoot, services: badServices, runtimeReady: { true }, register: { _ in preconditionFailure("missing identity registered") }, onRegistered: { _ in false })
        precondition(bad.command(["op":"space.marble.generate","presetID":"dj_house"]))
        try await settle(bad)
        precondition(bad.snapshot["marblePhase"] as? String == "failed")
        precondition(UnityMarblePackageBuilder.registeredRoots(root: failureRoot).isEmpty)
        bad.close()
        let pending = try JSONDecoder().decode(MarbleOperation.self, from: Data(#"{"operation_id":"pending","done":false}"#.utf8))
        var cancelServices = services
        cancelServices.generate = { _ in pending }
        cancelServices.sleep = { try await Task.sleep(for: .seconds(10)) }
        let cancelRoot = root.appendingPathComponent("cancelled")
        let cancelled = UnityMarbleWorldBridge(root: cancelRoot, services: cancelServices, runtimeReady: { true }, register: { _ in false }, onRegistered: { _ in false })
        precondition(cancelled.command(["op":"space.marble.generate","presetID":"dj_house"]))
        for _ in 0..<100 {
            if cancelled.snapshot["marbleOperationID"] as? String == "pending" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(cancelled.command(["op":"space.marble.cancel"]))
        try await settle(cancelled)
        precondition(cancelled.snapshot["marblePhase"] as? String == "cancelled_remote_operation_may_continue")
        let recover = UnityMarbleWorldBridge(root: cancelRoot, services: cancelServices, runtimeReady: { true }, register: { _ in false }, onRegistered: { _ in false })
        precondition(recover.snapshot["marblePhase"] as? String == "resume_available")
        precondition(!recover.command(["op":"space.marble.generate","presetID":"dj_house"]))
        recover.close(); cancelled.close()
        let world = try await client.world(id: "world-exact")
        let rejectedRoot = root.appendingPathComponent("registration-rejected")
        let reject = UnityMarbleWorldBridge(root: rejectedRoot, services: services, runtimeReady: { true }, register: { _ in false }, onRegistered: { _ in preconditionFailure("rejected registration appeared") })
        precondition(reject.command(["op":"space.marble.import","worldID":world.id]))
        try await settle(reject)
        precondition(reject.snapshot["marblePhase"] as? String == "failed")
        precondition(UnityMarblePackageBuilder.registeredRoots(root: rejectedRoot).isEmpty)
        let gated = UnityMarbleWorldBridge(root: root.appendingPathComponent("gated"), services: services, runtimeReady: { false }, register: { _ in false }, onRegistered: { _ in false })
        precondition(gated.snapshot["generationSupported"] as? Bool == false)
        precondition(!gated.command(["op":"space.marble.generate","presetID":"dj_house"]))
        precondition(!gated.command(["op":"space.marble.import","worldID":world.id]))
        gated.close()
        var wrongServices = services
        wrongServices.world = { _ in MarbleWorld(id: "wrong-result", name: world.name, colliderURL: world.colliderURL, splatFallbacks: world.splatFallbacks) }
        let wrong = UnityMarbleWorldBridge(root: root.appendingPathComponent("wrong-world"), services: wrongServices, runtimeReady: { true }, register: { _ in preconditionFailure("wrong world registered") }, onRegistered: { _ in false })
        precondition(wrong.command(["op":"space.marble.import","worldID":world.id]))
        try await settle(wrong)
        precondition(wrong.snapshot["marblePhase"] as? String == "failed")
        wrong.close()
        var rejectedServices = services
        rejectedServices.world = { _ in throw MarbleWorldClientError.rejected(statusCode: 401, message: "isolated-secret-do-not-expose") }
        let rejectedHTTP = UnityMarbleWorldBridge(root: root.appendingPathComponent("rejected-http"), services: rejectedServices, runtimeReady: { true }, register: { _ in false }, onRegistered: { _ in false })
        precondition(rejectedHTTP.command(["op":"space.marble.import","worldID":world.id]))
        try await settle(rejectedHTTP)
        precondition(rejectedHTTP.snapshot["marbleError"] as? String == "Marble 请求失败（401）。")
        rejectedHTTP.close()
        let invalid = fixture.appendingPathComponent("invalid.spz")
        try Data("invalid".utf8).write(to: invalid)
        do { _ = try await UnityMarblePackageBuilder.publish(world: world, splat: invalid, collider: fixture.appendingPathComponent("collider.glb"), root: root); preconditionFailure("invalid SPZ accepted") }
        catch { precondition(UnityMarblePackageBuilder.registeredRoots(root: root).count == 1) }
        for name in ["unsupported-v3", "over-limit", "unsupported-sh", "unsupported-bits"] {
            do { try UnityMarbleSPZFormat.requireRuntimeSupported(fixture.appendingPathComponent(name + ".spz")); preconditionFailure("unsupported runtime format accepted: " + name) }
            catch UnityMarbleError.invalidGeometry {}
        }
        do { _ = try await UnityMarblePackageBuilder.publish(world: world, splat: fixture.appendingPathComponent("scene.spz"), collider: fixture.appendingPathComponent("invalid-collider.glb"), root: root); preconditionFailure("invalid GLB accepted") }
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
