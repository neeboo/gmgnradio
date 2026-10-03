import CryptoKit
import Foundation
import WorldRuntime

/// 世界状态迁移（S3）之后 **Swift 不再持久化世界状态**。
///
/// 这个类型把旧的 `state.json` 通道收敛成**只读预像**：它只能被读（一次性导入
/// 权威、出事时回滚），任何 `save` 都是一次**可见的失败**，而不是一次静默写盘。
/// 于是"Swift 侧不存在世界状态持久化路径"这句话有一个机械判据：
/// `AtomicJSONWorldStatePersistence.save` 在生产里不可达，而这里的 `save` 抛错。
enum WorldStatePersistenceRetired: LocalizedError {
    case writeRetired

    var errorDescription: String? {
        "空间数据由后台服务统一写入，这里只读。"
    }
}

/// 遗留 `state.json` 预像：只读、一次性导入、可回滚。
struct LegacyWorldStatePreImage: WorldStatePersisting {
    /// 旧版版本化档案（1.2 优先、可回退 1.1）——只用于 `load()` 与导入。
    ///
    /// **private**：这是"只读预像"这条纪律的机械保障。若它可被外部读到，
    /// 任何 app 文件都能写 `preImage.archive.save(state)`，绕过唯一的只读入口，
    /// 第二份真相立刻长回来（评审门禁 R1 的负对照就是注入这一行）。
    private let archive: any WorldStatePersisting
    /// 迁移导入要读的**真实**候选文件，按优先级排序（存在的第一个即预像）。
    private let candidateURLs: [URL]

    init(archive: any WorldStatePersisting, candidateURLs: [URL]) {
        self.archive = archive
        self.candidateURLs = candidateURLs
    }

    func load() throws -> WorldState? {
        try archive.load()
    }

    /// 唯一的写入口在这里被永久关闭。绝不写、绝不删、绝不改 mtime。
    func save(_ state: WorldState) throws {
        throw WorldStatePersistenceRetired.writeRetired
    }

    /// 读取预像原文（导入用）。文件不存在返回 nil —— 只读，绝不创建。
    func rawPreImage() -> (url: URL, text: String, sha256: String)? {
        for url in candidateURLs {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (url, text, digest)
        }
        return nil
    }
}

/// 权威支撑的世界状态持久化：**读**来自 `gmgn-taskd`，**写**是带
/// `expectedRevision` + `requestID` 的意图提交。
///
/// 降级规则（设计 §8.1「只读降级」）：权威不可达时
///
/// - 有遗留预像 ⇒ 用它把世界**渲染出来**（只读），`save` 抛 `unavailable`，
///   世界照常可见但任何写意图都被明确拒绝；
/// - 没有预像（首次冷启动且权威不在）⇒ fail-closed，不凭空空造一个世界。
///
/// 两条都**不写任何文件**，所以不会长出第二份真相。
final class AuthorityWorldStatePersistence: WorldStatePersisting, @unchecked Sendable {
    private let client: WorldAuthorityClient
    private let preImage: LegacyWorldStatePreImage
    private let packageID: String
    private let packageVersion: String
    private let lock = NSLock()
    private var authorityRevision: UInt64 = 0
    /// 权威不可达时的只读降级标记：一旦置位，写路径全部拒绝。
    private var readOnlyReason: String?

    var lastAppliedRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return authorityRevision
    }

    var projection: WorldAuthorityProjection { client.projection }

    var downgradedReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return readOnlyReason
    }

    init(manifest: WorldManifest, preImage: LegacyWorldStatePreImage,
         socketPath: String, helperPath: String, allowsLaunching: Bool = true) {
        self.packageID = manifest.packageID
        self.packageVersion = manifest.packageVersion
        self.preImage = preImage
        self.client = WorldAuthorityClient(worldID: manifest.worldID, socketPath: socketPath,
                                           helperPath: helperPath, allowsLaunching: allowsLaunching)
    }

    // MARK: - 读

    func load() throws -> WorldState? {
        do {
            if let record = try client.snapshot() {
                lock.lock()
                authorityRevision = record.recordRevision
                readOnlyReason = nil
                lock.unlock()
                return record.state
            }
            // 权威里还没有这个世界：把遗留预像**一次性**导入（幂等：同一份内容
            // 重复导入是回放，不产生第二份）。
            if let raw = preImage.rawPreImage() {
                let imported = try client.importLegacy(packageID: packageID,
                                                       packageVersion: packageVersion,
                                                       rawText: raw.text, sha256: raw.sha256)
                lock.lock()
                authorityRevision = imported.revision
                readOnlyReason = nil
                lock.unlock()
                return try client.snapshot()?.state
            }
            // 权威没有记录、也没有预像：冷启动 fail-closed。
            return nil
        } catch let error as WorldAuthorityError {
            // 只读降级：世界能看，写意图被拒（可见），并且什么都不落盘。
            if let legacy = try preImage.load() {
                lock.lock()
                readOnlyReason = error.localizedDescription
                authorityRevision = 0
                lock.unlock()
                return legacy
            }
            throw error
        }
    }

    // MARK: - 写（意图）

    func save(_ state: WorldState) throws {
        lock.lock()
        let reason = readOnlyReason
        let expected = authorityRevision
        lock.unlock()
        if let reason {
            throw WorldAuthorityError.unavailable(reason)
        }
        let result = try client.commit(state: state, expectedRevision: expected,
                                       intent: ["kind": "world.checkpoint",
                                                "packageID": packageID,
                                                "packageVersion": packageVersion])
        lock.lock()
        authorityRevision = max(authorityRevision, result.revision)
        lock.unlock()
    }

    /// 把权威事件推进本地投影（`basedOnRevision` 随之前进）。
    /// 陈旧/乱序事件在这里被丢弃，永远不会用来做写准入。
    @discardableResult
    func refreshProjection() throws -> UInt64 {
        try client.applyPendingFacts()
    }

    /// 启动推送订阅（`world_subscribe`）：权威一变就推进投影。
    /// 只影响写准入用的 `basedOnRevision`，不参与渲染（渲染读内存投影）。
    func startEventSubscription() {
        client.startEventSubscription()
    }

    var subscriptionIsRunning: Bool { client.subscriptionIsRunning }
}

/// 生产接线用的路径解析：与 `PropTaskDaemonClient` 的默认值**同一口径**
/// （Application Support/gmgn radio/TaskService/taskd.sock + 应用内 helper）。
///
/// `applicationSupportBase` 只给测试/夹具换根用；生产传 nil。
///
/// **唯一根**：`taskServiceRoot` 是 taskd 状态/socket 根的唯一拼接口。世界权威端点、
/// `PropTaskDaemonClient` 的 E2E 显式注入都从这里取。上一轮 E2E 的拒收项正是这里：
/// 端点以为传进来的 base 已经是 `.../gmgn radio`，于是把 socket 落在
/// `<base>/TaskService/taskd.sock`，而 `PropTaskDaemonClient(root:)` 落在
/// `<base>/gmgn radio/TaskService/taskd.sock` —— 同一个测试根里出现两个 taskd，
/// 世界权威与生成服务各连各的。现在只有一个函数能拼这个根。
struct WorldAuthorityEndpoint {
    let socketPath: String
    let helperPath: String

    /// taskd 的 socket/状态根：`<Application Support>/gmgn radio/TaskService`。
    /// 传 nil 时用真实用户 Application Support（生产）；传 base 时只换最外层根。
    static func taskServiceRoot(
        applicationSupportBase: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let support: URL
        if let applicationSupportBase {
            support = applicationSupportBase
        } else {
            support = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
        return support
            .appendingPathComponent("gmgn radio", isDirectory: true)
            .appendingPathComponent("TaskService", isDirectory: true)
    }

    init(applicationSupportBase: URL? = nil, bundle: Bundle = .main) {
        let root = Self.taskServiceRoot(applicationSupportBase: applicationSupportBase)
        socketPath = root.appendingPathComponent("taskd.endpoint.json").path
        helperPath = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers/gmgn-taskd").path
    }
}
