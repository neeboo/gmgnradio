import Foundation
import CryptoKit

final class HTTPTransport: @unchecked Sendable {
    let endpoint: URL
    init(_ endpoint: URL) { self.endpoint = endpoint }
    func call(_ method: String, _ data: Data) throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent(method))
        request.httpMethod = "POST"; request.httpBody = data
        let result = ResultBox()
        let wait = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            result.set(data: data, error: error); wait.signal()
        }.resume()
        guard wait.wait(timeout: .now() + 5) == .success else { throw TestError.failed }
        return try result.get()
    }
}
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var error: (any Error)?
    func set(data: Data?, error: (any Error)?) { lock.lock(); defer { lock.unlock() }; self.data = data; self.error = error }
    func get() throws -> Data { lock.lock(); defer { lock.unlock() }; if let error { throw error }; guard let data else { throw TestError.failed }; return data }
}
enum TestError: Error { case failed }
actor Counts {
    var authorizations = 0; var executions = 0; var texts = 0
    func authorize() { authorizations += 1 }
    func execute() { executions += 1 }
    func text() { texts += 1 }
    func verify() { precondition(authorizations == 1 && executions == 1 && texts == 1) }
}
@main struct TestMain {
    static func main() async throws {
        let endpoint = URL(string: CommandLine.arguments[1])!
        let scenario = CommandLine.arguments[2]
        let transport = HTTPTransport(endpoint)
        let client = RustAgentRuntimeClient(call: transport.call)
        let identity = RustAgentRuntimeClient.Identity(worldID: "world", residentScope: "scope", hostSessionID: "host", runID: "run", eventID: "event")
        let provider: RustAgentRuntimeClient.Provider
        if scenario == "images" {
            provider = .init(backend: "fake", endpoint: "https://invalid.test", model: "fake", apiKey: "test-only", imageInput: true)
        } else {
            provider = .init(backend: "fake", endpoint: "https://invalid.test", model: "fake", apiKey: "test-only")
        }
        try await client.configure(identity: identity,
            provider: provider,
            systemPrompt: "test", tools: [.init(name: "move", description: "", effect: "write", inputSchema: Data("{\"type\":\"object\"}".utf8))])
        let counts = Counts()
        let callbacks = RustAgentRuntimeClient.Callbacks(authorize: { tool in
            precondition(tool.phase == "authorize" && tool.operationID == nil)
            await counts.authorize()
            if scenario == "cancel" { try await client.cancel() }
            if scenario == "steer" {
                let text = "change target"
                let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                do {
                    _ = try await client.steer(identity: identity, messageID: "guide", text: text, inputSHA256: "wrong")
                    preconditionFailure("invalid hash accepted")
                } catch RustAgentRuntimeClient.ClientError.invalidProtocol { }
                let first = try await client.steer(identity: identity, messageID: "guide", text: text, inputSHA256: hash)
                let second = try await client.steer(identity: identity, messageID: "guide", text: text, inputSHA256: hash)
                precondition(first.delivery == .delivered && !first.duplicate)
                precondition(second.delivery == .delivered && second.duplicate)
            }
            return "business-operation"
        }, execute: { tool in
            precondition(tool.phase == "execute" && tool.operationID == "business-operation")
            await counts.execute()
            return .init(identity: identity, callID: scenario == "wrong" ? "other" : tool.callID,
                         operationID: "business-operation", status: "completed", output: Data("{\"ok\":true}".utf8),
                         images: scenario == "images" ? [.init(bytes: Data([255, 0, 1, 128]), mimeType: "image/jpeg")] : [])
        }, text: { _ in await counts.text() }, terminal: { _ in })
        do {
            try await client.run(input: "test", images: [.init(bytes: Data([1, 2, 3]), mimeType: "image/png")], callbacks: callbacks)
            precondition(scenario != "wrong")
        } catch RustAgentRuntimeClient.ClientError.receiptMismatch {
            precondition(scenario == "wrong")
        }
        if scenario == "normal" || scenario == "steer" { await counts.verify() }
        print("PASS \(scenario)")
    }
}
