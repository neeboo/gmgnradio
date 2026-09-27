import Foundation
import CryptoKit

/// Explicitly invoked integration probe. It never launches the app or creates a second job.
/// Compile with the real configuration, client, store, image preparation, attachment,
/// output descriptor and coordinator sources; run only after the parent approves the gate.
@main struct WishMachineServiceProbe {
    enum ProbeError: Error { case failed(String) }

    @MainActor static func main() async {
        var remoteID = "unknown"
        func report(_ state: String, extra: [String: Any] = [:]) {
            var value = extra
            value["jobID"] = remoteID
            value["state"] = state
            if var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                data.append(10)
                FileHandle.standardOutput.write(data)
            }
        }
        do {
            guard Array(CommandLine.arguments.dropFirst()) == ["--run-authorized-single-job"] else {
                throw ProbeError.failed("not_authorized_to_run")
            }
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let proof = root.appendingPathComponent("tmp/wish-machine-service-proof-20260906", isDirectory: true)
            let reference = root.appendingPathComponent("tmp/generated-props/espresso-machine-v1/reference.png")
            guard FileManager.default.fileExists(atPath: reference.path) else { throw ProbeError.failed("reference_missing") }
            guard let configuration = try PropGenerationConfigurationStore().load(),
                  configuration.endpoint.absoluteString == "http://127.0.0.1:8191" else {
                throw ProbeError.failed("expected_local_service_not_configured")
            }
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 15
            sessionConfiguration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: sessionConfiguration)
            defer { session.invalidateAndCancel() }
            let store = PropGenerationStore(directory: proof.appendingPathComponent("core"), session: session)
            try store.configure(endpoint: configuration.endpoint, token: configuration.token)
            let coordinator = WishMachineCoordinator(store: store, directory: proof.appendingPathComponent("wishes"), canClaim: { _ in nil })
            let world = "84503420-3010-4944-8fde-2f383cd08ebe"
            let resident = "wish-machine-service-proof-20260906"
            let authorization = UUID(uuidString: "8A80044E-FAED-418A-8184-E0BD179F9822")!
            let attachment = ResidentImageAttachment(id: UUID(uuidString: "261BB0EA-FA13-4FE9-8A9B-28702BF4C664")!,
                                                     url: reference, displayName: "reference.png")
            let name = "wish-machine-espresso-service-proof-20260906"
            let requestID = "wish-machine-service-proof-submit-v1"
            let targetHeight = 0.42
            let deadline = Date().addingTimeInterval(300)
            let originalJobs = coordinator.residentJobs(worldID: world, residentScope: resident)
            var job: WishMachineJob
            if let existing = originalJobs.first {
                guard originalJobs.count == 1, existing.authorizationID == authorization,
                      existing.requestID == requestID, existing.name == name else { throw ProbeError.failed("unexpected_existing_job") }
                job = existing // Read/refresh only. Re-running this probe cannot submit again.
            } else {
                let marker = proof.appendingPathComponent("single-submission-started")
                guard !FileManager.default.fileExists(atPath: marker.path) else {
                    throw ProbeError.failed("prior_submission_requires_manual_inspection")
                }
                try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                try Data(requestID.utf8).write(to: marker, options: .withoutOverwriting)
                try coordinator.authorize(attachments: [attachment], worldID: world, residentScope: resident,
                                          authorizationID: authorization,
                                          source: .init(author: "gmgn internal evaluation", license: "self-generated reference; internal evaluation only"))
                job = try await coordinator.submit(requestID: requestID, authorizationID: authorization,
                                                   attachmentID: attachment.id, name: name, heightMeters: targetHeight,
                                                   worldID: world, residentScope: resident)
            }
            var lastState: String?
            while Date() < deadline {
                if let record = store.jobs.first(where: { $0.id == job.jobID }), let receipt = record.receipt {
                    remoteID = receipt.id
                }
                let state = job.stage.rawValue + ":" + (job.remoteState?.rawValue ?? "unconfirmed")
                if state != lastState { report(state); lastState = state }
                if job.stage == .ready { break }
                if [.failed, .cancelled, .interrupted, .submissionUncertain, .claimed].contains(job.stage) {
                    throw ProbeError.failed("terminal_" + job.stage.rawValue)
                }
                try await Task.sleep(for: .seconds(3))
                guard Date().addingTimeInterval(30) < deadline else { break }
                job = try await coordinator.refresh(id: job.id, worldID: world, residentScope: resident)
            }
            guard job.stage == .ready, let modelPath = job.modelPath,
                  let record = store.jobs.first(where: { $0.id == job.jobID }),
                  let receipt = record.receipt, let result = receipt.result else { throw ProbeError.failed("timed_out_or_not_ready") }
            remoteID = receipt.id
            guard receipt.name == name, record.name == name, receipt.heightMeters == targetHeight,
                  result.suggestedHeightMeters == targetHeight else { throw ProbeError.failed("validation_name_or_height") }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: modelPath))
            let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard bytes.count == result.inspection.bytes, sha256 == result.inspection.sha256,
                  bytes.count <= PropGenerationClient.maxModelBytes, bytes.prefix(4) == Data([0x67, 0x6c, 0x54, 0x46]) else {
                throw ProbeError.failed("validation_model_bytes_or_hash")
            }
            let minimum = result.inspection.bounds.min
            let maximum = result.inspection.bounds.max
            guard minimum.count == 3, maximum.count == 3 else { throw ProbeError.failed("validation_dimensions") }
            let dimensions = zip(minimum, maximum).map { $1 - $0 }
            guard dimensions.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw ProbeError.failed("validation_dimensions") }
            let events = coordinator.pendingEvents(worldID: world, residentScope: resident)
            guard events.filter({ $0.kind == .generationCompleted }).count == 1,
                  events.filter({ $0.kind == .outputReady }).count == 1,
                  events.allSatisfy({ $0.wishID == job.id && $0.worldID == world && $0.residentScope == resident }),
                  coordinator.readyOutputs(worldID: world).count == 1 else { throw ProbeError.failed("validation_completion_events") }
            let evidence: [String: Any] = ["jobID": receipt.id, "wishID": job.id.uuidString, "objectID": job.objectID,
                "state": "ready_not_claimed", "sha256": sha256, "bytes": bytes.count, "modelPath": modelPath,
                "targetHeightMeters": targetHeight, "modelDimensions": dimensions, "nameVerified": true,
                "generationCompletedEvents": 1, "outputReadyEvents": 1]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: proof.appendingPathComponent("receipt.json"), options: .atomic)
            report("ready_not_claimed", extra: ["sha256": sha256, "bytes": bytes.count,
                                               "targetHeightMeters": targetHeight, "modelDimensions": dimensions])
        } catch ProbeError.failed(let state) {
            report(state)
            exit(1)
        } catch {
            report("probe_failed_without_resubmission")
            exit(1)
        }
    }
}
