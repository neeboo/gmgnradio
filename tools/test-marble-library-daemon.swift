import Foundation

final class ReceiptLoss: @unchecked Sendable {
    private let lock = NSLock()
    private var lost = false
    func shouldLose(_ method: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if method == "marble_control_action_receipt" && !lost { lost = true; return true }
        return false
    }
}

@main struct MarbleLibraryAcceptance {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let endpoint = args[1], root = URL(fileURLWithPath: args[2])
        let base = URL(string: args[3])!, mode = args[4]
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpoint, helperPath: "", allowsLaunching: false)
        if mode == "restart-check" {
            let client = RustMarbleControlClient(call: { method, data in
                let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: value))
            }, owner: "restart-owner", hostSessionID: "fixture-host")
            let recovered = try await client.read()
            precondition(recovered.task?.status == "unknown")
            do {
                _ = try await client.command("space.marble.generate", expectedRevision: recovered.revision, presetID: "dj_house")
                preconditionFailure("unknown generation replay accepted")
            } catch { }
            print("PASS actual restart: inflight recovered unknown; new paid request rejected")
            return
        }
        let loss = ReceiptLoss()
        let control = RustMarbleControlClient(call: { method, data in
            let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let response = try transport.call(method: method, params: value)
            if loss.shouldLose(method) { throw RustMarbleControlError.unavailable }
            return try JSONSerialization.data(withJSONObject: response)
        }, owner: "library-owner", hostSessionID: "fixture-host")
        let http = MarbleWorldClient(baseURL: base, suppliedAPIKey: "fixture-memory-key")
        let cache = MarbleWorldCache(rootURL: root.appendingPathComponent("native-cache"))
        let library = MarbleWorldLibrary(client: http, cache: cache, spatialStage: SpatialStageStore(),
            authority: control, preparePackage: { _ in throw RustMarbleControlError.unavailable })
        let url = await library.prepare()
        precondition(url != nil && library.worlds.count == 7)
        precondition(library.selectedWorld?.id == "catalog-dj")
        precondition(library.hasWorld(for: .djHouse))
        let selected = await library.select(worldID: "catalog-cabin")
        precondition(selected != nil && library.selectedWorld?.id == "catalog-cabin")
        await library.activate(preset: .djHouse)
        precondition(library.errorMessage == nil, "activation failed: \(library.errorMessage ?? "")")
        precondition(library.selectedWorld?.id == "catalog-dj")
        print("PASS actual Library refresh/select/activate; one lost receipt recovered without HTTP replay")

        let unknown = RustMarbleControlClient(call: { method, data in
            let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: value))
        }, owner: "unknown-owner", hostSessionID: "fixture-host")
        var state = try await unknown.read()
        state = try await unknown.command("space.marble.generate", expectedRevision: state.revision, presetID: "dj_house")
        state = try await unknown.claim(taskID: state.task!.taskID, expectedRevision: state.revision)
        let action = state.action!
        let broken = MarbleWorldClient(baseURL: base.appendingPathComponent("unused"), suppliedAPIKey: "fixture-memory-key")
        let observed = await broken.executePlannedHTTP(method: action.method!, path: action.path!, body: try action.bodyData)
        precondition(observed.transportErrorCode != nil)
        let fact = RustMarbleControlClient.HTTPFact(transportErrorCode: observed.transportErrorCode!)
        state = try await unknown.receipt(action, fact: fact, requestID: "unknown-fact")
        precondition(state.task?.status == "unknown")
        let duplicate = try await unknown.receipt(action, fact: fact, requestID: "unknown-fact")
        precondition(duplicate.task?.status == "unknown")
        do {
            _ = try await unknown.command("space.marble.generate", expectedRevision: state.revision, presetID: "dj_house")
            preconditionFailure("unknown paid request replay accepted")
        } catch { }
        print("PASS actual unknown provider receipt retained; identical receipt idempotent; no paid replay")

        let generation = RustMarbleControlClient(call: { method, data in
            let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: value))
        }, owner: "generation-owner", hostSessionID: "fixture-host")
        var nativeFailureCount = 0
        let generatedLibrary = MarbleWorldLibrary(client: http, cache: cache, spatialStage: SpatialStageStore(),
            authority: generation, preparePackage: { world in
                precondition(world.id == "generated-exact" && world.colliderURL != nil)
                nativeFailureCount += 1
                throw RustMarbleControlError.unavailable
            })
        await generatedLibrary.activate(preset: .djHouse)
        var failed = try await generation.read()
        precondition(failed.task?.status == "failed")
        precondition(failed.task?.errorCode == "marble_control_package_preparation_failed")
        precondition(failed.task?.operationID == "operation-exact" && failed.task?.worldID == "generated-exact")
        precondition(failed.presetPackages.isEmpty && nativeFailureCount == 1)
        precondition(generatedLibrary.localSplatURL == nil)
        print("PASS actual Library POST→Rust due GET polls→exact world→native preparation failure; operation retained, no package completion")

        failed = try await generation.command("space.marble.resume", expectedRevision: failed.revision)
        precondition(failed.task?.status == "pending" && failed.task?.operationID == "operation-exact")
        for expectedKind in ["operation", "world", "prepare_package"] {
            failed = try await generation.claim(taskID: failed.task!.taskID, expectedRevision: failed.revision)
            let next = failed.action!
            precondition(next.kind == expectedKind && next.status == "inflight")
            if expectedKind == "prepare_package" {
                precondition(next.world?.id == "generated-exact")
                failed = try await generation.receipt(next, fact: RustMarbleControlClient.PackageFailureFact(preparationErrorCode: "native_preparation_failed"))
            } else {
                let observation = await http.executePlannedHTTP(method: next.method!, path: next.path!, body: try next.bodyData)
                precondition(observation.transportErrorCode == nil)
                failed = try await generation.receipt(next, fact: RustMarbleControlClient.HTTPFact(statusCode: observation.statusCode!, body: observation.body!))
            }
        }
        precondition(failed.task?.status == "failed" && failed.task?.operationID == "operation-exact")
        precondition(failed.task?.errorCode == "marble_control_package_preparation_failed" && failed.presetPackages.isEmpty)
        print("PASS actual explicit resume reused operation-exact without another paid POST; exact native failure remained unregistered")

        let echo = await http.executePlannedHTTP(method: "GET", path: "/marble/v1/echo", body: nil)
        precondition(echo.transportErrorCode == "credential_echo" && echo.body == nil)
        print("PASS actual native HTTP credential echo never forwarded")
        let restart = RustMarbleControlClient(call: { method, data in
            let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: value))
        }, owner: "restart-owner", hostSessionID: "fixture-host")
        var inflight = try await restart.read()
        inflight = try await restart.command("space.marble.generate", expectedRevision: inflight.revision, presetID: "dj_house")
        inflight = try await restart.claim(taskID: inflight.task!.taskID, expectedRevision: inflight.revision)
        precondition(inflight.task?.status == "inflight" && inflight.action?.status == "inflight")
        print("PASS restart setup: durable actual claim; native execution deliberately not started")
    }
}
