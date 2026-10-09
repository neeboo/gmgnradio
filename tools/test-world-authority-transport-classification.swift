// 世界权威传输层的**故障分类 / 重连 / 不误报**门禁。
//
// 它锁住真机上报的那条用户可见症状（"在空间里点播放器的上一首/下一首，会弹
// 暂时连不上空间服务"）背后的三处**折叠**：
//
//   1. `TaskdHTTPTransport.finish`：非 200 且 body 无 `error.code` → `.unavailable`；
//   2. `TaskdHTTPTransport.didCompleteWithError`：流式**正常 EOF** 被合成为
//      `.unavailable`（`error ?? (acceptingEvents ? .unavailable : nil)`）；
//   3. `WorldHTTPResponse.poll`：`.unavailable` / `.timedOut` 一律 `break` 到
//      `throw WorldAuthorityError.unreachable("HTTP connection ended")`。
//
// 三处叠在一起，于是「正常流结束 / 连接失败 / 非 200 无码」在日志与界面里
// **无法区分**，而且订阅流**自己**的超时也会被记成「权威不可达」。
//
// 真机证据（改动前）：
//   * 统一日志 12 小时：`HTTP connection ended` 11702 条、`HTTP endpoint unavailable`
//     224 条、`HTTP request timed out` 161 条 —— 全是同一句「世界状态权威不可达」；
//   * 每 ~40 秒一条 `HTTP connection ended` 其实来自**客户端自己**：订阅用的
//     `URLRequest.timeoutInterval` 只有 5 秒，而权威每 15 秒才发一次
//     `: heartbeat`（`services/gmgn-taskd/src/http.rs` 的 `Events::poll_next`），
//     于是健康的订阅流每 5 秒被自己掐断一次，退避 30 秒后重连 ⇒ 5 + ~35 = ~40 秒。
//     隔离 root 的真 daemon 复现：`timeout=2` → 2.11 秒断、`timeout=8` → 8.03 秒断、
//     `timeout=20` → 活过 40 秒探针上限；daemon 侧 `curl` 同一流 70 秒心跳不断。
//   * 用户可见那一刻：`Player.log` 里 `GPUI: host command not accepted.` 紧跟
//     `GMGN: 暂时连不上空间服务，这次没有保存。请稍后重试。`，而同一进程同一时段
//     唯一一条**非订阅线程**的不可达日志是 `HTTP request timed out`
//     （音乐链路 `RustMusicPlaybackClient` 的预算是 1 秒）。
//
// 运行：swift tools/test-world-authority-transport-classification.swift
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
func check(_ condition: Bool, _ message: String) { if !condition { fail(message) } }

// MARK: - 源码级：三处折叠点必须已经分开

let transportPath = "apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift"
let clientPath = "apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift"
let backoffPath = "apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift"
let transportSource = (try? String(contentsOf: URL(fileURLWithPath: transportPath), encoding: .utf8)) ?? ""
let clientSource = (try? String(contentsOf: URL(fileURLWithPath: clientPath), encoding: .utf8)) ?? ""
check(!transportSource.isEmpty && !clientSource.isEmpty, "读不到生产源码")

// 1) 三种故障各有自己的 case。
for required in ["case streamEnded", "case connectionFailed(code: Int)", "case httpStatus(Int)"] {
    check(transportSource.contains(required), "TaskdHTTPError 缺 `\(required)`：三种故障还是一句话")
}
check(!transportSource.contains("completion(TaskdHTTPError.unavailable)"),
      "非 200 无码还在合成 `.unavailable`（第 1 处折叠）")
check(!transportSource.contains("error ?? (acceptingEvents ? TaskdHTTPError.unavailable : nil)"),
      "正常 EOF 还在被合成 `.unavailable`（第 2 处折叠）")
check(clientSource.contains("case .streamEnded: return WorldAuthorityError.streamEnded()"),
      "正常流结束没有映射成 `.streamEnded`")
check(!clientSource.contains("throw WorldAuthorityError.unreachable(\"HTTP connection ended\")"),
      "折叠后那句 HTTP connection ended 还在（第 3 处折叠）")
check(!clientSource.contains("case .unavailable, .timedOut: break"),
      "`.unavailable` / `.timedOut` 还在被 `break` 吞掉后重贴成同一句")

// 2) 订阅流的空闲上限必须由**流式请求自己**决定，不能被 RPC 的短预算压过。
check(transportSource.contains("static let streamingIdleTimeout: TimeInterval = 60"),
      "没有给事件流单独的空闲上限：它会继续被 RPC 的短预算掐死")
check(transportSource.contains("if streaming { request.timeoutInterval = Self.streamingIdleTimeout }"),
      "流式请求没有盖掉调用方的 `timeoutInterval`（请求自己的值会压过会话配置）")

// 3) 正常收尾不许落「不可达」日志。
let streamEndedConstructor = clientSource
    .split(separator: "\n")
    .drop { !$0.contains("static func streamEnded()") }
    .prefix(2)
    .joined(separator: "\n")
check(!streamEndedConstructor.contains("diagnosticLog.error"),
      "正常流收尾还会打「世界状态权威不可达」日志")
check(streamEndedConstructor.contains(".streamEnded"),
      "`streamEnded()` 没有返回 `.streamEnded`")

// 4) 重发必须**只**依赖权威自己的幂等合同，并且有界。
let callSource = clientSource
    .split(separator: "\n")
    .drop { !$0.contains("func call(method: String, params: [String: Any]) throws") }
    .prefix(20)
    .joined(separator: "\n")
check(callSource.contains("let replayable = params[\"requestID\"] is String"),
      "重发没有挂在权威合同的幂等键 `requestID` 上")
check(clientSource.contains("private static let transportRetryAttempts = 1"),
      "重发次数不是有界的 1 次")

// MARK: - 行为级：真源码 + 进程内 HTTP 夹具

func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [FileManager.default.currentDirectoryPath + "/tools/world-runtime-harness-flags.sh"]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}

let driver = #"""
import Darwin
import Foundation

var checks = 0
var failures = 0
func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(label)") }
}

/// 进程内的最小 HTTP/1.1 夹具：只服务 /health、/rpc、/events，一条连接一个请求。
/// 用它才能把「正常流结束 / 连接失败 / 非 200 无码」三种故障**分别**造出来。
final class HarnessFixture: @unchecked Sendable {
    enum Behaviour: String {
        case ok
        case rpcAbortOnce
        case rpcAbortAlways
        case rpc503NoCode
        case healthAbortOnce
        case idleStream
    }
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var behaviour: Behaviour = .ok
    private var rpcCalls: [String?] = []
    private var rpcSeen = 0
    private var healthSeen = 0

    init() throws {
        // 先用局部量把监听套接字建好：闭包里引用 `self` 会触发"成员尚未全部初始化"。
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "fixture", code: 1) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw NSError(domain: "fixture", code: 2) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        listenFD = fd
        port = UInt16(bigEndian: actual.sin_port)
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func set(_ value: Behaviour) { lock.lock(); behaviour = value; lock.unlock() }
    /// 这次调用**真正到达**夹具的 /rpc 请求（含重发），用来证明重发的是同一个幂等键。
    func rpcRequests() -> [String?] { lock.lock(); defer { lock.unlock() }; return rpcCalls }
    func healthRequests() -> Int { lock.lock(); defer { lock.unlock() }; return healthSeen }
    func reset() { lock.lock(); rpcCalls.removeAll(); rpcSeen = 0; healthSeen = 0; lock.unlock() }

    func descriptor(at url: URL) throws {
        let json: [String: Any] = ["version": 2, "address": "127.0.0.1:\(port)", "token": UUID().uuidString.lowercased()]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            serve(fd)
        }
    }

    private func serve(_ fd: Int32) {
        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while raw.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { close(fd); return }
            raw.append(contentsOf: buffer[0..<n])
        }
        let head = String(decoding: raw, as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").components(separatedBy: " ")
        let method = parts.count > 1 ? parts[0] : ""
        let path = parts.count > 1 ? parts[1] : ""
        var length = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        var body = Data()
        if let end = raw.range(of: Data("\r\n\r\n".utf8)) { body = raw.subdata(in: end.upperBound..<raw.count) }
        while body.count < length {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            body.append(contentsOf: buffer[0..<n])
        }

        lock.lock(); let mode = behaviour; lock.unlock()

        if method == "GET" && path == "/health" {
            lock.lock(); healthSeen += 1; let seen = healthSeen; lock.unlock()
            if mode == .healthAbortOnce && seen == 1 { abort(fd); return }
            respond(fd, status: 200, contentType: "application/json",
                    body: Data(#"{"version":2,"transport":"http"}"#.utf8))
            return
        }
        var requestID: String?
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            requestID = (object["params"] as? [String: Any])?["requestID"] as? String
        }
        lock.lock(); rpcCalls.append(requestID); rpcSeen += 1; let rpcNumber = rpcSeen; lock.unlock()

        if path == "/events" {
            var head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
            head += "data: {\"id\":\"1\",\"result\":{\"subscribed\":true}}\n\n"
            writeAll(fd, Data(head.utf8))
            if mode == .idleStream { Thread.sleep(forTimeInterval: 4) }
            shutdown(fd, SHUT_RDWR); close(fd)
            return
        }
        switch mode {
        case .rpcAbortOnce where rpcNumber == 1, .rpcAbortAlways:
            abort(fd)
        case .rpc503NoCode:
            respond(fd, status: 503, contentType: "application/json",
                    body: Data(#"{"id":null,"error":{"message":"no code on purpose"}}"#.utf8))
        default:
            let id = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["id"] as? String ?? ""
            respond(fd, status: 200, contentType: "application/json",
                    body: Data("{\"id\":\"\(id)\",\"result\":{\"ok\":true}}".utf8))
        }
    }

    /// 不带任何响应地关闭：典型的连接层失败（真机上是 URLError=-1005）。
    private func abort(_ fd: Int32) { shutdown(fd, SHUT_RDWR); close(fd) }
    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, data.count) }
    }
    private func respond(_ fd: Int32, status: Int, contentType: String, body: Data) {
        let reason = status == 200 ? "OK" : "Service Unavailable"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        writeAll(fd, out)
        shutdown(fd, SHUT_RDWR); close(fd)
    }
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-authority-classification-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let descriptor = work.appendingPathComponent("taskd.endpoint.json")
let fixture = try HarnessFixture()
try fixture.descriptor(at: descriptor)

func client(timeout: TimeInterval) -> TaskdHTTPAuthorityClient {
    TaskdHTTPAuthorityClient(endpointFile: descriptor.path, helperPath: "/nonexistent",
                             allowsLaunching: false, timeout: timeout)
}
/// 把一次调用压成「可诊断的字符串 + 是否成功」。
func describe(_ body: () throws -> Void) -> (ok: Bool, detail: String, error: Error?) {
    do { try body(); return (true, "", nil) }
    catch let error as WorldAuthorityError {
        if case let .unavailable(text) = error { return (false, text, error) }
        return (false, String(describing: error), error)
    } catch { return (false, "unexpected \(error)", error) }
}
func rpcDetail(_ method: String, _ params: [String: Any], timeout: TimeInterval) -> (ok: Bool, detail: String, error: Error?) {
    describe { _ = try client(timeout: timeout).call(method: method, params: params) }
}
func streamOutcome(_ timeout: TimeInterval, seconds: TimeInterval) -> (elapsed: TimeInterval, error: Error?) {
    let started = Date()
    var threw: Error?
    do {
        try client(timeout: timeout).stream(method: "world_subscribe",
                                            params: ["worldID": "w", "after": 0],
                                            stop: { false }, onFrame: { _ in })
    } catch { threw = error }
    return (Date().timeIntervalSince(started), threw)
}

// 0. 空闲上限数值：必须明显大于权威的心跳间隔（15 秒）。
let heartbeat = 15.0
check(TaskdHTTPTransport.streamingIdleTimeout > heartbeat,
      "事件流空闲上限 \(TaskdHTTPTransport.streamingIdleTimeout)s 不大于心跳 \(heartbeat)s")
check(TaskdHTTPTransport.streamingIdleTimeout >= 4 * heartbeat,
      "事件流空闲上限要容得下 4 次心跳抖动：\(TaskdHTTPTransport.streamingIdleTimeout)s")

// 1. 正常流结束必须是 `.streamEnded`，**不是**「服务不可达」。
fixture.reset(); fixture.set(.ok)
let ended = streamOutcome(5, seconds: 0)
check(ended.error as? WorldAuthorityError == .streamEnded,
      "正常流结束应当抛 .streamEnded，实际 \(String(describing: ended.error))")
check(ended.error as? WorldAuthorityError != .unavailable("HTTP connection ended"),
      "正常流结束又被折叠成 HTTP connection ended")

// 2. 事件流**不能**被调用方的短预算掐死：空闲上限独立于 RPC 预算。
fixture.reset(); fixture.set(.idleStream)
let idle = streamOutcome(1, seconds: 0)
check(idle.elapsed > 3.0,
      "客户端 1 秒预算把健康的空闲事件流在 \(String(format: "%.2f", idle.elapsed))s 掐断了（改动前是 1.0s）")
check(idle.error as? WorldAuthorityError == .streamEnded,
      "夹具 4 秒后正常收尾，应当抛 .streamEnded，实际 \(String(describing: idle.error))")

// 3. 非 200 且无 `error.code`：要说清 status 与是否 streaming。
fixture.reset(); fixture.set(.rpc503NoCode)
let noCode = rpcDetail("world_snapshot", ["worldID": "w"], timeout: 5)
check(noCode.detail.contains("503"), "非 200 无码的诊断里没有 status：\(noCode.detail)")
check(noCode.detail.contains("streaming=false"), "非 200 无码的诊断里没有 streaming 标志：\(noCode.detail)")
check(!noCode.detail.contains("HTTP connection ended"), "非 200 无码仍在说连接断了：\(noCode.detail)")

// 4. 连接失败：要有 URLError 码；**没有**幂等键时一次都不重发。
fixture.reset(); fixture.set(.rpcAbortAlways)
let refused = rpcDetail("world_snapshot", ["worldID": "w"], timeout: 5)
check(refused.detail.contains("URLError="), "连接失败的诊断里没有 URLError 码：\(refused.detail)")
check(refused.detail.contains("streaming=false"), "连接失败的诊断里没有 streaming 标志：\(refused.detail)")
check(fixture.rpcRequests().count == 1,
      "没有幂等键的请求被重发了 \(fixture.rpcRequests().count) 次（应当 1 次）")

// 5. 带权威合同的幂等键：瞬时连接失败重发**一次**，且逐字同键（权威据此回放）。
fixture.reset(); fixture.set(.rpcAbortOnce)
let key = "harness-fixed-idempotency-key"
let replayed = rpcDetail("world_snapshot", ["worldID": "w", "requestID": key], timeout: 5)
check(replayed.ok, "瞬时连接失败没有被重发救回来：\(replayed.detail)")
check(fixture.rpcRequests().count == 2,
      "重发次数应当恰好 1 次（共 2 个请求），实际 \(fixture.rpcRequests().count)")
check(fixture.rpcRequests().allSatisfy { $0 == key },
      "重发没有逐字复用同一个幂等键：\(fixture.rpcRequests().map { $0 ?? "nil" })")

// 6. 权威**答复过**的失败一次都不重发（503 无码也是答复）。
fixture.reset(); fixture.set(.rpc503NoCode)
_ = rpcDetail("world_snapshot", ["worldID": "w", "requestID": "answered-not-retried"], timeout: 5)
check(fixture.rpcRequests().count == 1,
      "权威答复过的失败被重发了 \(fixture.rpcRequests().count) 次（应当 1 次）")

// 7. 存活探针的瞬时失败要重探一次，而不是直接报「空间服务不可达」。
fixture.reset(); fixture.set(.healthAbortOnce)
let probed = rpcDetail("world_snapshot", ["worldID": "w"], timeout: 5)
check(probed.ok, "存活探针的瞬时失败没有被重探救回来：\(probed.detail)")
check(fixture.healthRequests() == 2, "存活探针应当恰好重探一次（共 2 次），实际 \(fixture.healthRequests())")

print(failures == 0 ? "PASS: 世界权威传输层分类/重连/不误报（\(checks) 条断言）"
                    : "FAILED: \(failures)/\(checks)")
exit(failures == 0 ? 0 : 1)
"""#

let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-authority-harness-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let driverURL = work.appendingPathComponent("main.swift")
try driver.write(to: driverURL, atomically: true, encoding: .utf8)

let binary = work.appendingPathComponent("harness")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-O", "-o", binary.path, driverURL.path,
                     transportPath, clientPath, backoffPath] + worldRuntimeHarnessFlags()
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { fail("行为探针没编过（见上面的 swiftc 输出）") }

let run = Process()
run.executableURL = binary
try run.run()
run.waitUntilExit()
guard run.terminationStatus == 0 else { fail("行为探针报了红") }

// MARK: - 注入负对照：行为断言必须抓得住「改回旧行为」

/// 只把**流式空闲上限**那一行改回旧行为（其余不动），行为探针必须变红：
/// 这证明第 2 条断言（事件流不被调用方短预算掐死）不是摆设。
let injected = transportSource.replacingOccurrences(
    of: "if streaming { request.timeoutInterval = Self.streamingIdleTimeout }",
    with: "// injected negative control: streaming request keeps the caller's short budget")
check(injected != transportSource, "负对照注入点没找到（流式空闲上限那一行已改）")

let injectedURL = work.appendingPathComponent("TaskdHTTPTransport.injected.swift")
try injected.write(to: injectedURL, atomically: true, encoding: .utf8)
let negativeBinary = work.appendingPathComponent("harness-negative")
let negativeCompile = Process()
negativeCompile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
negativeCompile.arguments = ["-O", "-o", negativeBinary.path, driverURL.path,
                             injectedURL.path, clientPath, backoffPath] + worldRuntimeHarnessFlags()
try negativeCompile.run()
negativeCompile.waitUntilExit()
guard negativeCompile.terminationStatus == 0 else { fail("负对照探针没编过") }

let negativeRun = Process()
let negativePipe = Pipe()
negativeRun.executableURL = negativeBinary
negativeRun.standardOutput = negativePipe
negativeRun.standardError = negativePipe
try negativeRun.run()
negativeRun.waitUntilExit()
let negativeOutput = String(decoding: negativePipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
check(negativeRun.terminationStatus != 0,
      "负对照没红：把流式空闲上限改回旧行为之后行为探针仍然通过 ⇒ 这条门禁抓不住那个 bug")
check(negativeOutput.contains("掐断") || negativeOutput.contains("streaming"),
      "负对照红得不是地方：\(negativeOutput.suffix(400))")

print("PASS: 世界权威传输层分类/重连/不误报（源码门禁 + 真源码行为探针 + 注入负对照）")
