import Foundation

final class CLIHTTP: @unchecked Sendable {
    let endpoint: URL
    init(_ endpoint: URL) { self.endpoint = endpoint }
    func call(_ method: String, _ data: Data) throws -> Data {
        var r = URLRequest(url: endpoint.appendingPathComponent(method)); r.httpMethod = "POST"; r.httpBody = data
        let box = CLIResultBox(); let signal = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: r) { data, _, error in box.set(data, error); signal.signal() }.resume()
        guard signal.wait(timeout: .now() + 5) == .success else { throw CLIError.failed }
        return try box.get()
    }
}
enum CLIError: Error { case failed }
final class CLIResultBox: @unchecked Sendable {
    let lock = NSLock(); var data: Data?; var error: (any Error)?
    func set(_ data: Data?, _ error: (any Error)?) { lock.lock(); defer { lock.unlock() }; self.data = data; self.error = error }
    func get() throws -> Data { lock.lock(); defer { lock.unlock() }; if let error { throw error }; guard let data else { throw CLIError.failed }; return data }
}
actor CLISink {
    var text = ""; var executions = 0
    func delta(_ value: String) { text += value }
    func execute() { executions += 1 }
    func check(_ scenario: String) {
        precondition(text == "hello" || text == "hello world")
        precondition(executions == (scenario == "cancel" || scenario == "wrongturn" || scenario == "unknown" ? 0 : 1))
    }
}
@main struct CLITest {
    static func main() async throws {
        let http = CLIHTTP(URL(string: CommandLine.arguments[1])!)
        let scenario = CommandLine.arguments[2]
        let client = RustCodexSessionClient(call: http.call)
        let id = RustCodexSessionClient.Identity(worldID: "w", residentScope: "s", hostSessionID: "h", runID: "r", eventID: "e")
        let sink = CLISink()
        let callbacks = RustCodexSessionClient.Callbacks(authorize: { tool in
            precondition(tool.phase == "authorize" && tool.operationID == nil)
            if scenario == "cancel" { try await client.cancel() }
            return "business-op"
        }, execute: { tool in
            precondition(tool.phase == "execute" && tool.operationID == "business-op")
            await sink.execute()
            return .init(identity: id, threadID: "thread", turnID: scenario == "wrongreceipt" ? "other" : "turn",
                         callID: tool.callID, operationID: "business-op", status: "completed", output: Data("{\"ok\":true}".utf8),
                         images: scenario == "images" ? [.init(bytes: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZAAAAABJRU5ErkJggg==")!, mediaType: "image/png")] : [])
        }, textDelta: { await sink.delta($0) }, state: { _ in })
        do {
            let result = try await client.run(identity: id,
                configuration: .init(executable: "/fixture/codex", arguments: try ResidentCodexPolicy.arguments(disabling: []), environment: ["LANG": "C"],
                                     root: "/fixture", cwd: "/fixture/work", resumeThreadID: "thread"),
                input: [.text("test"), .image(url: "data:image/png;base64,AQID"), .localImage(path: "/fixture/image.png")],
                tools: [.init(name: "move", description: "move", effect: "write", inputSchema: Data("{\"type\":\"object\"}".utf8))], callbacks: callbacks)
            precondition(scenario == "normal" || scenario == "cancel" || scenario == "images")
            precondition(result.state == (scenario == "cancel" ? "cancelled" : "completed"))
        } catch RustCodexSessionClient.ClientError.identityMismatch {
            precondition(scenario == "wrongreceipt" || scenario == "wrongturn")
        } catch RustCodexSessionClient.ClientError.unknownExecution {
            precondition(scenario == "unknown")
            do { _ = try await client.run(identity: id, configuration: .init(executable: "/x", arguments: [], environment: [:], root: "/x", cwd: "/x"), input: [], tools: [], callbacks: callbacks); preconditionFailure("unknown replay") }
            catch RustCodexSessionClient.ClientError.busy { }
        }
        await sink.check(scenario)
        print("PASS CLI \(scenario)")
    }
}
