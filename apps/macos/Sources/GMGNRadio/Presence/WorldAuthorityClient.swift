import CryptoKit
import Foundation
import WorldRuntime
import os

/// 世界状态权威（`gmgn-taskd`）的**同步**客户端。
///
/// 迁移后唯一写世界状态的进程是 `gmgn-taskd`（`services/gmgn-taskd/src/world.rs`）。
/// Swift 侧只剩两件事：
///
/// 1. **读**：启动时从权威取快照（`world_snapshot`），此后按事件推进投影；
/// 2. **发意图**：每次写带 `expectedRevision`（乐观并发）与 `requestID`（幂等），
///    冲突**可见地抛出**，绝不静默覆盖。
///
/// 为什么是同步阻塞：它替换掉的正是今天那条**同步的文件写**（`state.json` 的
/// `Data.write(.atomic)`），而一次本地 HTTP 往返（毫秒级）比一次原子文件写更便宜。
/// 调用点是"意图"（拖动结束、领取、每秒一次的检查点），不是渲染路径。
enum WorldAuthorityError: LocalizedError, Equatable {
    /// 权威不可达（HTTP 端点未就绪、启动失败、超时）。**不允许**降级成写本地文件。
    case unavailable(String)
    /// 权威原样透传的错误码（`revision_conflict` / `request_id_conflict` / ...）。
    case daemon(String)
    case invalidResponse
    case stateEncodeFailed
    /// 本地投影落后于权威：带上两侧的 revision，让调用方看得见"我在用旧数据"。
    case staleProjection(local: UInt64, authority: UInt64)
    /// 读不到权威记录、也没有遗留预像 —— 冷启动 fail-closed，绝不凭空空造一个世界。
    case noAuthorityRecord

    /// 界面只留**一句人话**；原始细节（原因、错误码、两侧 revision）一条不少地进日志。
    /// 失败在这里构造，所以日志在这里落 —— 调用方不必记得再打一行。
    static let diagnosticLog = Logger(subsystem: "ai.gmgn.radio", category: "WorldAuthority")

    static func unreachable(_ detail: String) -> WorldAuthorityError {
        diagnosticLog.error("世界状态权威不可达：\(detail, privacy: .public)")
        return .unavailable(detail)
    }

    static func daemonCode(_ code: String) -> WorldAuthorityError {
        diagnosticLog.error("世界状态权威拒绝：code=\(code, privacy: .public)")
        return .daemon(code)
    }

    static func projectionBehind(local: UInt64, authority: UInt64) -> WorldAuthorityError {
        diagnosticLog.error("本地投影落后于权威：local=\(local) authority=\(authority)")
        return .staleProjection(local: local, authority: authority)
    }

    /// 界面只留一句人话。关联值里的原始细节（原因、错误码、两侧 revision）在
    /// `unreachable` / `daemonCode` / `projectionBehind` 构造时已经落进日志。
    var errorDescription: String? {
        switch self {
        case .unavailable:
            "暂时连不上空间服务，这次没有保存。请稍后重试。"
        case .daemon:
            "空间服务拒绝了这次保存，请稍后重试。"
        case .invalidResponse:
            "空间服务返回了看不懂的数据，这次没有保存。"
        case .stateEncodeFailed:
            "空间数据保存失败，请稍后重试。"
        case .staleProjection:
            "空间数据不是最新的，这次没有保存。请稍后重试。"
        case .noAuthorityRecord:
            "找不到这个空间，请重新打开。"
        }
    }
}

/// 一条权威事实（`world_facts` 的一行）：`seq` 全局单调，`id` 是幂等键。
///
/// `@unchecked Sendable`：事实是不可变值，`payload` 是解码后的 JSON 对象
/// （`[String: Any]` 本身不是 Sendable，但这里没有任何共享可变状态）。
struct WorldAuthorityFact: @unchecked Sendable, Equatable {
    let sequence: UInt64
    let id: String
    let kind: String
    let subjectDomain: String
    let subjectKey: String
    let revision: UInt64
    let payload: [String: Any]
    let producer: String
    let atMilliseconds: UInt64

    static func == (lhs: WorldAuthorityFact, rhs: WorldAuthorityFact) -> Bool {
        lhs.sequence == rhs.sequence && lhs.id == rhs.id && lhs.kind == rhs.kind
            && lhs.subjectDomain == rhs.subjectDomain && lhs.subjectKey == rhs.subjectKey
            && lhs.revision == rhs.revision && lhs.producer == rhs.producer
            && lhs.atMilliseconds == rhs.atMilliseconds
    }
}

/// 权威里这个世界的一条记录（快照结果）。
struct WorldAuthorityRecord {
    let recordRevision: UInt64
    let boundarySeq: UInt64
    let stateSha256: String
    let state: WorldState
}

struct WorldAuthorityCommitResult {
    let revision: UInt64
    let sequence: UInt64
    let replayed: Bool
    let stateSha256: String
    let changedObjects: [String]
}

/// 本地投影：只由权威事件推进，永远带 `basedOnRevision`。
///
/// 陈旧判据（§4.4 第 5 条 / §4.6 D1）：
/// - `seq <= lastAppliedSequence` 的事件**丢弃**（重复/乱序保护）；
/// - `revision` 只在**同一个 subject**（`domain/key`）内比较：世界记录与每一件
///   物件各有自己的数轴，拿物件 revision 去比世界记录 revision 会把同一个提交里
///   先落的 `world.stateCommitted`(rev=4) 之后的 `object.placed`(rev=3) 永远丢掉；
/// - 同一 subject 的 revision 回退 = 协议错，单独计数（`revisionRegressions`）；
/// - **被拒的事实也推进游标**（"看见"与"应用"是两件事）：否则游标永远停在被拒的
///   那条前面，每次重连都从头重放、再拒一次，投影永远追不上权威；
/// - 写路径用的 `basedOnRevision` **只**跟随世界记录（`worlds/state`）前进，
///   它就是权威下一次 CAS 的 `expectedRevision`：投影陈旧 ⇒ 提交被拒，而不是拿旧数据覆盖。
struct WorldAuthorityProjection: Equatable, Sendable {
    /// 世界记录（`worlds/state`）的 revision 下界：写路径 CAS 的依据。
    private(set) var basedOnRevision: UInt64 = 0
    private(set) var lastAppliedSequence: UInt64 = 0
    private(set) var stateSha256: String?
    private(set) var appliedFacts: UInt64 = 0
    /// 因 `seq` 重复/乱序而丢弃的事实条数。
    private(set) var droppedStaleFacts: UInt64 = 0
    /// 因同一 `subject` 的 revision 回退（协议错）而丢弃的事实条数。
    private(set) var revisionRegressions: UInt64 = 0
    /// 每个 `subject`（`domain/key`）已应用到的最高 revision。
    private(set) var subjectRevisions: [String: UInt64] = [:]

    /// 世界记录在事实里的 subject：只有它推进 `basedOnRevision`。
    static let worldSubject = "worlds/state"

    /// 采纳一次快照：投影的世代号直接来自权威记录。
    mutating func adopt(recordRevision: UInt64, boundarySeq: UInt64, stateSha256: String) {
        basedOnRevision = max(basedOnRevision, recordRevision)
        subjectRevisions[Self.worldSubject] = max(
            subjectRevisions[Self.worldSubject] ?? 0, recordRevision)
        lastAppliedSequence = max(lastAppliedSequence, boundarySeq)
        self.stateSha256 = stateSha256
    }

    /// 采纳一个权威自身的成功提交。
    mutating func adoptCommit(revision: UInt64, sequence: UInt64, stateSha256: String) {
        basedOnRevision = max(basedOnRevision, revision)
        subjectRevisions[Self.worldSubject] = max(
            subjectRevisions[Self.worldSubject] ?? 0, revision)
        lastAppliedSequence = max(lastAppliedSequence, sequence)
        self.stateSha256 = stateSha256
    }

    /// 应用一条事件。返回 false 表示**被拒**（重复/乱序，或同一 subject 的
    /// revision 回退），调用方必须丢弃它 —— 但游标已经越过它。
    @discardableResult
    mutating func apply(_ fact: WorldAuthorityFact) -> Bool {
        guard fact.sequence > lastAppliedSequence else {
            droppedStaleFacts += 1
            return false
        }
        // 看见了就推进游标，**包括马上要被拒的事实**：否则一条被拒的 fact 会让
        // 游标永远停在它前面，每次重连都从头重放、再拒一次。
        lastAppliedSequence = fact.sequence
        let subject = "\(fact.subjectDomain)/\(fact.subjectKey)"
        if let recorded = subjectRevisions[subject], fact.revision < recorded {
            // 同一 subject 的 revision 回退 = 协议错，不是"陈旧"。
            revisionRegressions += 1
            return false
        }
        subjectRevisions[subject] = max(subjectRevisions[subject] ?? 0, fact.revision)
        if subject == Self.worldSubject {
            basedOnRevision = max(basedOnRevision, fact.revision)
        }
        appliedFacts += 1
        return true
    }

    /// 写路径的准入判据：投影必须与权威在同一个 revision 上。
    func admitsWrite(at authorityRevision: UInt64) -> Bool {
        authorityRevision == basedOnRevision
    }
}

/// Local HTTP authority transport, configured by the authenticated endpoint descriptor.
final class TaskdHTTPAuthorityClient: @unchecked Sendable {
    static let maximumFrame = 12 * 1024 * 1024
    private struct Endpoint: Decodable { let version: Int; let address: String; let token: String }
    let endpointFile: String
    let helperPath: String
    let allowsLaunching: Bool
    let timeout: TimeInterval
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool = true, timeout: TimeInterval = 5) {
        self.endpointFile = endpointFile; self.helperPath = helperPath
        self.allowsLaunching = allowsLaunching; self.timeout = timeout
    }
    private func validatedEndpoint(_ endpoint: Endpoint) throws -> Endpoint {
        let parts = endpoint.address.split(separator: ":")
        guard endpoint.version == 2, parts.count == 2, parts[0] == "127.0.0.1",
              let port = UInt16(parts[1]), port > 0,
              let token = UUID(uuidString: endpoint.token), token.uuidString.dropFirst(14).first == "4" else {
            throw WorldAuthorityError.invalidResponse
        }
        return endpoint
    }
    /// Descriptor-only inspection for the native plugin. No launch, health
    /// request, or credentials are returned; authenticated RPC remains here.
    func validatedControlURL() throws -> URL {
        let endpoint = try validatedEndpoint(JSONDecoder().decode(Endpoint.self,
            from: Data(contentsOf: URL(fileURLWithPath: endpointFile))))
        guard let url = URL(string: "http://\(endpoint.address)/rpc") else { throw WorldAuthorityError.invalidResponse }
        return url
    }
    private func endpoint() throws -> Endpoint {
        for attempt in 0..<(allowsLaunching ? 50 : 1) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: endpointFile)),
               let decoded = try? JSONDecoder().decode(Endpoint.self, from: data) {
                let endpoint = try validatedEndpoint(decoded)
                if try isHealthy(endpoint) { return endpoint }
            }
            if attempt == 1 { launchHelper() }
            if allowsLaunching { Thread.sleep(forTimeInterval: 0.1) }
        }
        throw WorldAuthorityError.unreachable("HTTP endpoint unavailable")
    }
    private func isHealthy(_ endpoint: Endpoint) throws -> Bool {
        let response = WorldHTTPResponse()
        let transport = TaskdHTTPTransport(streaming: false, maximumBytes: 64 * 1024,
            receive: { response.receive($0) }, completion: { response.finish($0) })
        var request = URLRequest(url: URL(string: "http://\(endpoint.address)/health")!, timeoutInterval: min(timeout, 1))
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        transport.start(request); defer { transport.cancel() }
        let data: Data
        do { data = try response.wait(timeout: min(timeout, 1)) }
        catch WorldAuthorityError.unavailable { return false }
        guard let health = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              health["version"] as? Int == 2, health["transport"] as? String == "http" else {
            throw WorldAuthorityError.invalidResponse
        }
        return true
    }
    private func request(path: String, method: String, params: [String: Any]) throws -> (URLRequest, String) {
        let endpoint = try endpoint()
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        guard data.count <= Self.maximumFrame else { throw WorldAuthorityError.invalidResponse }
        var request = URLRequest(url: URL(string: "http://\(endpoint.address)/\(path)")!, timeoutInterval: timeout)
        request.httpMethod = "POST"; request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        return (request, id)
    }
    /// Delegate callbacks run outside the main actor, including when a legacy synchronous caller is on it.
    func call(method: String, params: [String: Any]) throws -> [String: Any] {
        let (request, id) = try request(path: "rpc", method: method, params: params)
        let response = WorldHTTPResponse()
        let transport = TaskdHTTPTransport(streaming: false, receive: { response.receive($0) }, completion: { response.finish($0) })
        transport.start(request)
        defer { transport.cancel() }
        let data = try response.wait(timeout: timeout)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] as? String == id else { throw WorldAuthorityError.invalidResponse }
        if let error = object["error"] as? [String: Any], let code = error["code"] as? String { throw WorldAuthorityError.daemonCode(code) }
        guard let result = object["result"] as? [String: Any] else { throw WorldAuthorityError.invalidResponse }
        return result
    }
    func stream(method: String, params: [String: Any], stop: () -> Bool, onFrame: ([String: Any]) -> Void) throws {
        let (request, _) = try request(path: "events", method: method, params: params)
        let response = WorldHTTPResponse()
        let transport = TaskdHTTPTransport(streaming: true, receive: { response.receive($0) }, completion: { response.finish($0) })
        transport.start(request)
        defer { transport.cancel() }
        var event = Data()
        while !stop() {
            guard var line = try response.poll(timeout: 0.1) else { continue }
            if line.last == 13 { line.removeLast() }
            if line.isEmpty {
                if !event.isEmpty {
                    guard let object = try JSONSerialization.jsonObject(with: event) as? [String: Any] else { throw WorldAuthorityError.invalidResponse }
                    onFrame(object); event.removeAll()
                }
            } else if line.starts(with: Data("data:".utf8)) {
                var value = line.dropFirst(5)
                if value.first == 32 { value = value.dropFirst() }
                if !event.isEmpty { event.append(10) }
                event.append(contentsOf: value)
                guard event.count <= Self.maximumFrame else { throw WorldAuthorityError.invalidResponse }
            }
        }
    }
    private func launchHelper() {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ["--root", URL(fileURLWithPath: endpointFile).deletingLastPathComponent().path,
                             "--endpoint-file", endpointFile, "--concurrency", "2"]
            + TaskdBundledMediaConfiguration.arguments(nextTo: URL(fileURLWithPath: helperPath))
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
private final class WorldHTTPResponse: @unchecked Sendable {
    private let condition = NSCondition()
    private var frames: [Data] = []
    private var bytes = 0
    private var complete = false
    private var error: Error?
    func receive(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        guard !complete else { return }
        guard bytes + data.count <= TaskdHTTPAuthorityClient.maximumFrame else {
            error = WorldAuthorityError.invalidResponse; complete = true; condition.broadcast(); return
        }
        frames.append(data); bytes += data.count; condition.signal()
    }
    func finish(_ error: Error?) {
        condition.lock(); self.error = self.error ?? error; complete = true; condition.broadcast(); condition.unlock()
    }
    func poll(timeout: TimeInterval) throws -> Data? {
        condition.lock(); defer { condition.unlock() }
        if frames.isEmpty && !complete { _ = condition.wait(until: Date().addingTimeInterval(timeout)) }
        if !frames.isEmpty { let data = frames.removeFirst(); bytes -= data.count; return data }
        if complete {
            if let error = error as? WorldAuthorityError { throw error }
            if let error = error as? TaskdHTTPError {
                switch error {
                case .rejected(let code): throw WorldAuthorityError.daemonCode(code)
                case .invalidFrame: throw WorldAuthorityError.invalidResponse
                case .unavailable, .timedOut: break
                }
            }
            throw WorldAuthorityError.unreachable("HTTP connection ended")
        }
        return nil
    }
    func wait(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try poll(timeout: max(0, deadline.timeIntervalSinceNow)) { return data }
        }
        throw WorldAuthorityError.unreachable("HTTP request timed out")
    }
}

/// 世界状态权威的门面：快照、意图提交、一次性导入、事件追赶。
final class WorldAuthorityClient: @unchecked Sendable {
    static let residentScope = "world"
    static let producer = "swift"

    let worldID: String
    private let transport: TaskdHTTPAuthorityClient
    private let lock = NSLock()
    private var _projection = WorldAuthorityProjection()

    var projection: WorldAuthorityProjection {
        lock.lock()
        defer { lock.unlock() }
        return _projection
    }

    /// 订阅参数是**闭包**：每次重连都从投影当前游标继续，掉线期间的事实不丢。
    private lazy var subscription = WorldAuthoritySubscription(
        transport: transport,
        params: { [weak self] in
            ["worldID": self?.worldID ?? "", "after": Double(self?.projection.lastAppliedSequence ?? 0)]
        },
        onFact: { [weak self] fact in self?.apply(fact) })

    init(worldID: String, endpointFile: String, helperPath: String, allowsLaunching: Bool = true) {
        self.worldID = worldID
        self.transport = TaskdHTTPAuthorityClient(endpointFile: endpointFile, helperPath: helperPath,
                                              allowsLaunching: allowsLaunching)
    }

    // MARK: - 读

    /// 权威快照；`nil` = 权威里还没有这个世界（不是错误）。
    func snapshot() throws -> WorldAuthorityRecord? {
        let response = try transport.call(method: "world_snapshot",
                                          params: ["worldID": worldID, "includeState": true])
        guard let record = response["record"] else { throw WorldAuthorityError.invalidResponse }
        if record is NSNull { return nil }
        guard let object = record as? [String: Any],
              let revision = Self.unsigned(object["recordRevision"]),
              let boundary = Self.unsigned(object["boundarySeq"]),
              let stateSha256 = object["stateSha256"] as? String,
              let stateObject = object["state"] as? [String: Any] else {
            throw WorldAuthorityError.invalidResponse
        }
        let state = try Self.decodeState(stateObject)
        lock.lock()
        _projection.adopt(recordRevision: revision, boundarySeq: boundary, stateSha256: stateSha256)
        lock.unlock()
        return WorldAuthorityRecord(recordRevision: revision, boundarySeq: boundary,
                                    stateSha256: stateSha256, state: state)
    }

    /// 事件追赶（冷启动与断线恢复都走它）。返回的 `nextCursor` 是最后一条的 seq。
    func facts(after: UInt64, limit: Int = 200) throws -> (facts: [WorldAuthorityFact], nextCursor: UInt64) {
        let response = try transport.call(method: "world_facts_read",
                                          params: ["worldID": worldID, "after": Double(after),
                                                   "limit": Double(limit)])
        guard let entries = response["facts"] as? [[String: Any]],
              let next = Self.unsigned(response["nextCursor"]) else {
            throw WorldAuthorityError.invalidResponse
        }
        var facts: [WorldAuthorityFact] = []
        for entry in entries {
            guard let fact = Self.fact(from: entry) else { throw WorldAuthorityError.invalidResponse }
            facts.append(fact)
        }
        return (facts, next)
    }

    static func fact(from entry: [String: Any]) -> WorldAuthorityFact? {
        guard let sequence = unsigned(entry["seq"]),
              let id = entry["id"] as? String,
              let kind = entry["kind"] as? String,
              let subject = entry["subject"] as? [String: Any],
              let domain = subject["domain"] as? String,
              let key = subject["key"] as? String,
              let revision = unsigned(entry["revision"]),
              let payload = entry["payload"] as? [String: Any],
              let producer = entry["producer"] as? String,
              let at = unsigned(entry["atMs"]) else { return nil }
        return WorldAuthorityFact(sequence: sequence, id: id, kind: kind,
                                  subjectDomain: domain, subjectKey: key,
                                  revision: revision, payload: payload,
                                  producer: producer, atMilliseconds: at)
    }

    /// 推进投影；返回 false 表示该事实**被拒**（陈旧或乱序）。
    @discardableResult
    func apply(_ fact: WorldAuthorityFact) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _projection.apply(fact)
    }

    /// 启动**推送**订阅：权威一变就推进投影的 `basedOnRevision`。
    /// 它不参与渲染（渲染路径永不同步 RPC，设计 §4.1），只保证写路径
    /// 的准入 revision 不会因为别人的写入而陈旧。
    func startEventSubscription() {
        subscription.start()
    }

    var subscriptionIsRunning: Bool { subscription.isRunning }

    /// 把权威事件推进本地投影；陈旧/乱序的事件**被拒**（丢弃并计数）。
    /// 返回真正被采纳的事实条数。
    @discardableResult
    func applyPendingFacts() throws -> UInt64 {
        var cursor = projection.lastAppliedSequence
        var applied: UInt64 = 0
        while true {
            let (facts, next) = try facts(after: cursor)
            if facts.isEmpty { return applied }
            for fact in facts {
                lock.lock()
                let accepted = _projection.apply(fact)
                lock.unlock()
                if accepted { applied += 1 }
            }
            if next <= cursor { return applied }
            cursor = next
        }
    }

    // MARK: - 写（意图）

    /// 一次 `replaceState` 提交：Swift 的 `WorldSimulation` 仍然是**变更语义**的唯一
    /// 出处（回执、撤销、revision 都由它算），权威负责记录、版本仲裁与传播。
    func commit(state: WorldState, expectedRevision: UInt64, intent: [String: Any]) throws -> WorldAuthorityCommitResult {
        let document = try Self.encodeDocument(state)
        // 幂等键必须覆盖**权威用来判重的整份请求**：Rust 的 request hash 含
        // `expectedRevision`，所以"同内容 + 新 revision"是一次**新**请求；只用内容
        // 当幂等键会撞 `request_id_conflict`（同一 requestID、不同 hash）。
        // 带上 expectedRevision 后：同一 revision 上的同内容重发 = 权威幂等回放
        // （不推进 revision）；revision 前进后的同内容重发 = 一次无害的新提交。
        let requestID = "world-save:\(expectedRevision):" + Self.digest(document)
        let params: [String: Any] = [
            "worldID": worldID,
            "requestID": requestID,
            "expectedRevision": Double(expectedRevision),
            "producer": Self.producer,
            "intent": intent,
            "ops": [["op": "replaceState", "state": document]],
        ]
        do {
            let response = try transport.call(method: "world_commit", params: params)
            return try Self.commitResult(response, state: state, client: self)
        } catch let error as WorldAuthorityError {
            // 「提交成功但回执丢了」与「别人先写了」必须分开：前者不能报冲突，
            // 否则用户会看到一次假的失败并可能重复操作。判据是**内容**相等。
            if case let .daemon(code) = error, code == "revision_conflict",
               let record = try? snapshot(), record.state == state {
                let result = WorldAuthorityCommitResult(revision: record.recordRevision,
                                                        sequence: record.boundarySeq,
                                                        replayed: true,
                                                        stateSha256: record.stateSha256,
                                                        changedObjects: [])
                lock.lock()
                _projection.adoptCommit(revision: record.recordRevision, sequence: record.boundarySeq,
                                        stateSha256: record.stateSha256)
                lock.unlock()
                return result
            }
            if case let .daemon(code) = error, code == "revision_conflict" {
                let authority = (try? snapshot())?.recordRevision ?? expectedRevision
                throw WorldAuthorityError.projectionBehind(local: expectedRevision, authority: authority)
            }
            throw error
        }
    }

    static func commitResult(_ response: [String: Any], state: WorldState,
                             client: WorldAuthorityClient) throws -> WorldAuthorityCommitResult {
        guard let revision = unsigned(response["revision"]),
              let sequence = unsigned(response["seq"]),
              let replayed = response["replayed"] as? Bool,
              let stateSha256 = response["stateSha256"] as? String else {
            throw WorldAuthorityError.invalidResponse
        }
        let changed = (response["changedObjects"] as? [String]) ?? []
        client.lock.lock()
        client._projection.adoptCommit(revision: revision, sequence: sequence, stateSha256: stateSha256)
        client.lock.unlock()
        return WorldAuthorityCommitResult(revision: revision, sequence: sequence, replayed: replayed,
                                          stateSha256: stateSha256, changedObjects: changed)
    }

    /// 一次性导入遗留 `state.json`（**只读预像**，绝不改写它）。
    /// `stateSha256` 必须是被导入原文的 sha256：权威先校验字节，再采纳。
    @discardableResult
    func importLegacy(packageID: String, packageVersion: String, rawText: String,
                      sha256: String) throws -> WorldAuthorityCommitResult {
        let params: [String: Any] = [
            "worldID": worldID,
            "requestID": "migration:" + sha256,
            "producer": "import",
            "packageID": packageID,
            "packageVersion": packageVersion,
            "stateSha256": sha256,
            "stateJson": rawText,
        ]
        let response = try transport.call(method: "world_import", params: params)
        guard let revision = Self.unsigned(response["revision"]),
              let sequence = Self.unsigned(response["seq"]),
              let replayed = response["replayed"] as? Bool,
              let stateSha256 = response["stateSha256"] as? String else {
            throw WorldAuthorityError.invalidResponse
        }
        lock.lock()
        _projection.adoptCommit(revision: revision, sequence: sequence, stateSha256: stateSha256)
        lock.unlock()
        return WorldAuthorityCommitResult(revision: revision, sequence: sequence, replayed: replayed,
                                          stateSha256: stateSha256, changedObjects: [])
    }

    // MARK: - 编解码

    static func unsigned(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let number = value as? UInt64 { return number }
        if let number = value as? Int, number >= 0 { return UInt64(number) }
        return nil
    }

    /// `WorldState` → 权威合同的 JSON 对象（毫秒时间戳，与 `state.json` 同一口径）。
    static func encodeDocument(_ state: WorldState) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = []
        let data: Data
        do { data = try encoder.encode(state) } catch { throw WorldAuthorityError.stateEncodeFailed }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorldAuthorityError.stateEncodeFailed
        }
        return object
    }

    static func decodeState(_ object: [String: Any]) throws -> WorldState {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw WorldAuthorityError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(WorldState.self, from: data) }
        catch { throw WorldAuthorityError.invalidResponse }
    }

    /// 内容哈希：键排序后的规范 JSON。同一份状态恒得同一个 `requestID`
    /// ⇒ 重复提交是权威幂等回放，不会推进 revision。
    static func digest(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}


/// 权威事件通道的推送订阅（`world_subscribe`）。
///
/// 一个专用线程做阻塞读；断线后退避重连，重连时**从投影的游标继续**
/// （`after = projection.lastAppliedSequence`），所以掉线期间的事实不会丢，
/// 已经应用过的也不会二次应用（投影按 seq 去重）。
final class WorldAuthoritySubscription: @unchecked Sendable {
    private let transport: TaskdHTTPAuthorityClient
    private let params: @Sendable () -> [String: Any]
    private let onFact: @Sendable (WorldAuthorityFact) -> Void
    private let lock = NSLock()
    private var running = false
    private var stopped = false

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    init(transport: TaskdHTTPAuthorityClient, params: @escaping @Sendable () -> [String: Any],
         onFact: @escaping @Sendable (WorldAuthorityFact) -> Void) {
        self.transport = transport
        self.params = params
        self.onFact = onFact
    }

    func start() {
        lock.lock()
        if running || stopped {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "gmgn-world-authority-subscription"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        running = false
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        // 断线重连的等待来自**唯一**的策略定义（`RetryBackoff.swift` 的
        // `RetryBackoffSite.authorityReconnect`）：第一跳与既有 1 秒同值，之后递增、
        // 带抖动、封顶。重连仍**从投影游标续**（那是本处的语义，不搬进策略）。
        var reconnectFailures = 0
        while !isStopped {
            do {
                try transport.stream(method: "world_subscribe", params: params(),
                                     stop: { [weak self] in self?.isStopped ?? true }) { [weak self] frame in
                    // 事件帧是 {"worldFact": {...}}；错误帧在这里只结束这一轮。
                    // 投影只前进不后退：陈旧事件由投影自己丢弃并计数。
                    guard let self,
                          let entry = frame["worldFact"] as? [String: Any],
                          let fact = WorldAuthorityClient.fact(from: entry) else { return }
                    self.onFact(fact)
                }
            } catch {
                // 权威不可达：按共享策略退避后重试（只影响投影新鲜度，不影响渲染）。
                if isStopped { return }
                reconnectFailures += 1
                let policy = RetryBackoffSite.authorityReconnect.policy
                Thread.sleep(forTimeInterval: policy.delay(
                    afterFailure: reconnectFailures, jitterUnit: RetryJitter.uniform.unit()
                ))
                continue
            }
            reconnectFailures = 0
            if isStopped { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        lock.lock()
        running = false
        lock.unlock()
    }
}
