import Foundation
import Combine
import Darwin
import CryptoKit

enum WishMachineStage: String, Codable, Sendable {
    case submitting, submissionUncertain, generating, generated, ready, failed, cancelled, interrupted, claimed
}

/// `wishes.json` 里**一条解不出来的 job**。
///
/// 为什么它是档案的一部分而不是被丢掉：`wishes.json` 是**整份 decode** 的
/// （`WishMachineCoordinator.init`），一条坏 job 会让整份读不出来（`readable = false`），
/// 于是「我的物件」列表整个消失 —— 那正是这次要修的观感缺陷。现在改成**逐条降级**：
/// 坏的那一条进这里，其余照常；而且它的**原始 JSON 原样留在档案里**
/// （`Archive.unreadableJobs`），下一次 `persist()` 不会把它抹掉。
struct WishMachineUnreadableJob: Codable, Equatable, Sendable {
    /// 这一条在 `wishes.json` 里的原始 JSON（值逐字保留，格式可能被重排）。
    let rawJSON: String
    /// 能读出来的身份，只用来在界面上点名（读不出来就是 nil）。
    let jobID: String?
    let name: String?
    /// 为什么读不出来（字段级的原因，不是"解析失败"这种没信息量的话）。
    let reason: String
}

struct WishMachineJob: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let worldID: String
    let residentScope: String
    let authorizationID: UUID
    let attachmentID: UUID
    let requestID: String
    let name: String
    let heightMeters: Double
    /// 提交时声明的**尺寸意图**（守护进程 `sizeIntent`）。可选、纯增量：老档案里没有这个键
    /// ⇒ 解出 nil，行为与今天逐字相同（尺寸仍按请求高度自动推断）。
    ///
    /// 它随任务一起持久化，因为"这件东西该多大"是用户的意图：`retry`（复用原身份重放）
    /// 与托盘预览都必须看到**同一个**意图，不能一次重试把它丢掉。
    var sizeIntent: PropSizeIntent?
    let objectID: String
    var jobID: UUID?
    var stage: WishMachineStage
    var remoteState: PropGenerationState?
    var computeMayContinue = false
    var modelPath: String?
    var lastError: String?
    // Optional for histories written before this flag existed; absent means not paused.
    var autoContinuationPaused: Bool?
    // Provenance of `autoContinuationPaused`. Only a positive `true` here is evidence of
    // an explicit human stop, and only that may keep demanding a manual release. `nil`
    // means "no proven user intent" — older archives, and any pause another code path
    // wrote — so `await discardPausesWithoutUserIntent()` lifts it as soon as the backend is
    // healthy again. A network, submission, world-switch or availability failure must
    // never be able to produce a state only a human can clear.
    var autoContinuationStoppedByUser: Bool?
    var cancelRequested: Bool?
    // A stable owner ID alone is not evidence that Rust durably accepted the task.
    var daemonAccepted: Bool?
    // Each human resume grant is single-use across later stops and app restarts.
    var continuationResumeAuthorizationIDs: [UUID]?
}

/// 任务行/工具回执要显示的"这个任务的尺寸是怎么定的"一行。
///
/// **没有意图就是 `nil`**（老任务、以及只给了旧 `height_meters` 的调用）：任务行的
/// `detail` 因此与今天逐字相同，不因为本契约上线而多出任何一行。
///
/// 这一行**不再自己拼"尺寸："那个前缀**：前缀会让面板叠成
/// 「尺寸：你说的大小：1443 × 862 × 302 毫米」——两个标签压在同一句话上。
/// 那一句（含出处）由 `PropSizeIntent.summary` **一处**给出，这里只转交。
extension WishMachineJob {
    var sizeIntentLine: String? {
        guard let sizeIntent else { return nil }
        return sizeIntent.summary
    }
}

struct WishMachineClaimEvidence {
    let worldID: String
    let activityID: String?
    let phase: String?
    let distanceMeters: Double
    let outputAvailable: Bool
    var activityRequestID: String? = nil
    var activityGeneration: UInt64? = nil
    var phaseGeneration: UInt64? = nil
    var activityHostSessionID: String? = nil
    var objectID: String? = nil
}

/// Provenance of one resident-discovered public reference image. Kept beside the
/// grant so a chosen web image is never recorded as a user upload, and so the
/// source follows the exact attachment the resident selected.
struct ResidentWebReference: Codable, Equatable, Sendable {
    let attachmentID: UUID
    let imageURL: URL
    let source: PropGenerationSource
}

/// Absolute, persisted placement target in coordinator space (WorldRuntime-free).
struct WishMachineVector3: Codable, Equatable, Sendable {
    let x: Double; let y: Double; let z: Double
    var isFinite: Bool { [x, y, z].allSatisfy { $0.isFinite } }
}

struct WishPlacementTarget: Codable, Equatable, Sendable {
    let surfaceID: String
    let position: WishMachineVector3
    let yaw: Double
    var isFinite: Bool { position.isFinite && yaw.isFinite }
}

/// Structured destination carried by the submit tool when the user explicitly asks to place the result.
struct WishPlacementDestination: Equatable, Sendable {
    let surfaceIDs: [String]
    let explicitTarget: WishPlacementTarget?
}

/// 一次**还没提交**的人类委托：工具因为信息不足（例如用户没说尺寸）而没有发出提交，
/// 但把原授权、原工具调用编号和原参数记在这里，等用户回答之后**续上同一份委托**。
///
/// 为什么必须记原授权与原 `requestID`：`submit` 按 `authorizationID` 幂等
/// （下面 `submit()` 里 `jobs.first { $0.authorizationID == authorizationID }`）。
/// 用户回答的那一轮是**新的 run**、新的 `authorizationID` —— 若用它提交，那就是另一次
/// 委托：多出一份授权、多出一份摆放委托，而原来那一份永远悬空。记下 (authorityID,
/// requestID) 这一对并且只认这一对，"同一个委托"才是结构性的，而不是靠提示词自觉。
struct WishMachinePendingDraft: Identifiable, Codable, Equatable, Sendable {
    /// 草稿有效期：超过就不再可续。fail-closed 的方向是"让用户重说一次"，
    /// 绝不是"那就新建一次生成"。

    let id: UUID
    /// 原那一轮的人类授权（= 那一轮的 runID）。
    let authorityID: UUID
    /// 原那次工具调用编号：同一份委托的重放必须逐字相同，否则 `consumedAuthorization`。
    let requestID: String
    let attachmentID: UUID
    let name: String
    /// 原样的目的地参数（`WishPlacementDestination` 本身不是 Codable，这里存它的两个字段）。
    let destinationSurfaceIDs: [String]?
    let destinationTarget: WishPlacementTarget?
    let worldID: String
    let residentScope: String
    let createdAt: Date
    /// 还缺什么（`WishMachineContract.Need` 的 rawValue）。
    var needs: [String]
    /// 已经为这一份草稿问过几次。
    var attempt: Int
    /// 这一份委托**已经**提交出来的那个任务。非 nil 之后这份草稿不再参与"按名字+图自动续"，
    /// 只认显式 `pending_id`：对同一个 `pending_id` 的重试一律回同一个任务（幂等重放），
    /// 于是"重复提交"在任何时序下都长不出第二件产物。
    var submittedJobID: UUID?

    var destination: WishPlacementDestination? {
        destinationSurfaceIDs.map { WishPlacementDestination(surfaceIDs: $0, explicitTarget: destinationTarget) }
    }

}

enum WishMachineDraftResolution: Equatable {
    case fresh
    case resume(WishMachinePendingDraft)
    case ambiguous([WishMachinePendingDraft])
}

enum WishPlacementDelegationState: String, Codable, Sendable {
    case awaitingSubmission, pending, placed, revoked, failed
}

/// Narrow persisted grant: only the eventual object on the allowed surfaces, at the explicit
/// absolute transform when provided. Object identity binds only after the submission is accepted.
struct WishPlacementDelegation: Identifiable, Codable, Sendable {
    let id: UUID
    let authorizationID: UUID
    let requestID: String
    let worldID: String
    let residentScope: String
    let allowedSurfaceIDs: [String]
    let explicitTarget: WishPlacementTarget?
    /// For surface-only grants: the absolute target selected by the completion round,
    /// persisted before any effect so a crash between commit and completion replays it.
    /// Overwritten per attempt; an invalid candidate never locks out a later legal spot.
    var boundTarget: WishPlacementTarget?
    var objectID: String?
    var state: WishPlacementDelegationState
    var lastError: String?
}

struct WishMachineEvent: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case stateChanged
        case generationCompleted, outputReady, failed, cancelled, interrupted, claimed, placed
    }
    let id: UUID
    let wishID: UUID
    let worldID: String
    let residentScope: String
    let objectID: String
    let kind: Kind
    let computeMayContinue: Bool
    var acknowledged = false
    var stage: WishMachineStage?
    var remoteState: PropGenerationState?
    var message: String?
    var cancelRequested: Bool?
    var forwardedToDaemon: Bool?
    var failureSource: String?
    var autoContinuationPaused: Bool?
    var continuationResumeAuthorizationID: UUID?
}

enum WishMachineError: LocalizedError {
    case unauthorized, unknownAttachment, consumedAuthorization, conflictingCall, wrongScope, unavailable, busy, notReady, notAtMachine, retryUnavailable, pauseNotPersisted, automaticContinuationPaused, placementRevoked
    case continuationResumeUnavailable, continuationResumeUnauthorized, continuationResumeReadbackRequired, continuationAlreadyPlaced
    case imageLimitReached
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "本轮没有用户授权的图片生成请求。"
        case .unknownAttachment: return "找不到本次消息登记的图片，请使用附件编号。"
        case .consumedAuthorization: return "这次授权已有生成任务，请查询原任务；新生成需要用户再次发起。"
        case .conflictingCall: return "同一次工具请求不能改为另一件物品。"
        case .wrongScope: return "该许愿任务属于另一个空间或居民。"
        case .unavailable: return "许愿任务记录无法读取或保存，已停止操作以保留记录。"
        case .busy: return "另一项生成请求仍在处理中，本次操作尚未发送，请稍后重试。"
        case .notReady: return "物品还未完成下载检查，暂时不能领取。"
        case .notAtMachine: return "请先走到许愿机领取位置；托盘实际显示物品后才能领取。"
        case .retryUnavailable: return "只有已经在后台存在的任务才能重试（复用原身份和原图，不会新建任务、也不会再消耗一次生成授权）。"
        case .pauseNotPersisted: return "当前运行已暂停自动领取，但暂停状态保存失败；重启后可能恢复，请先解决存储问题。"
        case .automaticContinuationPaused: return "该任务的自动续办已停止，后台不能自行领取或摆放；本轮人类明确下令的领取不受影响。"
        case .placementRevoked: return "该摆放委托已停止，需要用户新的摆放委托才能重试。"
        case .continuationResumeUnavailable: return "该任务当前不能恢复自动续办；已取消、失败或完成的操作不会自动重试。"
        case .continuationResumeUnauthorized: return "需要本轮用户明确恢复该许愿任务；旧恢复授权不能在再次停止后复用。"
        case .continuationResumeReadbackRequired: return "请先核实原物件已在当前空间库存中且尚未摆放，暂未恢复自动摆放。"
        case .continuationAlreadyPlaced: return "原物件已摆放，无需恢复自动摆放；不会重复移动或生成。"
        case .imageLimitReached: return "本轮最多登记 4 张参考图；已登记图片不能被新图片替换或扩展。"
        }
    }
}

private enum WishMutationScope {
    @TaskLocal static var owner: UUID?
}

/// Owns user grants and world associations, not resident reasoning or world movement.
@MainActor final class WishMachineCoordinator: ObservableObject {
    private struct Authorization: Codable {
        let id: UUID
        var attachments: [ResidentImageAttachment]
        let worldID: String
        let residentScope: String
        let source: PropGenerationSource
    }
    private struct ImageRegistration: Codable {
        let attachment: ResidentImageAttachment
        let worldID: String
        let residentScope: String
        let conversationID: String
    }
    private struct Archive: Codable {
        var authorizations: [Authorization]
        var jobs: [WishMachineJob]
        var events: [WishMachineEvent]
        var imageRegistrations: [ImageRegistration]?
        var delegations: [WishPlacementDelegation]?
        var webReferences: [ResidentWebReference]?
        /// 可选 ⇒ 旧档案照常解码（读到 nil 就是"没有草稿"，行为与今天逐位相同）。
        var pendingDrafts: [WishMachinePendingDraft]?
        /// 逐条降级时保留下来的坏 job。旧构建忽略这个键（合成的 `Codable` 不认识它），
        /// 所以档案仍然向后兼容。
        var unreadableJobs: [WishMachineUnreadableJob]?
    }
    @Published private(set) var jobs: [WishMachineJob] = []
    private var workingJobs: [WishMachineJob] = []
    /// **一条坏 job 不许让整个列表消失**：解不出来的那些在这里，原始 JSON 仍在档案里。
    @Published private(set) var unreadableJobs: [WishMachineUnreadableJob] = []
    @Published private(set) var errorMessage: String?
    var onChange: (@MainActor () -> Void)?
    private let store: PropGenerationStore
    private let directory: URL
    private let archiveFileManager: FileManager
    private let canClaim: @MainActor (WishMachineJob) -> WishMachineClaimEvidence?
    private var authorizations: [Authorization] = []
    private var events: [WishMachineEvent] = []
    private var imageRegistrations: [ImageRegistration] = []
    private var delegations: [WishPlacementDelegation] = []
    private var webReferences: [ResidentWebReference] = []
    private var pendingDrafts: [WishMachinePendingDraft] = []
    private var readable = true
    typealias ControlCall = @Sendable (String, Data) async throws -> Data
    private let controlCall: ControlCall
    private let controlOwnerID: String
    private let controlSessionID: String
    private var controlRevision = 0
    @Published private(set) var isLoadingAuthority = true
    private var readinessTask: Task<Void, Error>?
    private var mutationOwner: UUID?
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var committedArchive: Archive?

    private func withMutation<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        try await waitUntilReady()
        if let owner = WishMutationScope.owner, owner == mutationOwner {
            return try await operation()
        }
        while mutationOwner != nil {
            await withCheckedContinuation { mutationWaiters.append($0) }
        }
        try Task.checkCancellation()
        let owner = UUID()
        mutationOwner = owner
        defer {
            mutationOwner = nil
            if !mutationWaiters.isEmpty { mutationWaiters.removeFirst().resume() }
        }
        return try await WishMutationScope.$owner.withValue(owner) {
            do { return try await operation() }
            catch {
                if let archive = committedArchive { installArchive(archive) }
                throw error
            }
        }
    }

    init(store: PropGenerationStore, directory: URL? = nil, archiveFileManager: FileManager = .default,
         wishControlCall: ControlCall? = nil,
         wishControlHostSessionID: String = UUID().uuidString,
         canClaim: @escaping @MainActor (WishMachineJob) -> WishMachineClaimEvidence?) {
        self.store = store
        self.archiveFileManager = archiveFileManager
        let resolvedDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gmgn radio/WishMachine", isDirectory: true)
        self.directory = resolvedDirectory
        self.controlOwnerID = SHA256.hash(data: Data(resolvedDirectory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.controlCall = wishControlCall ?? { try await store.wishControlRequest(method: $0, params: $1) }
        self.controlSessionID = wishControlHostSessionID
        self.canClaim = canClaim
        readinessTask = Task { [weak self] in
            guard let self else { return }
            try await self.loadAuthority()
        }
        store.onChange = { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                await WishMutationScope.$owner.withValue(nil) {
                    try? await self.waitUntilReady()
                    await self.synchronizeBackendSnapshot()
                }
            }
        }
    }

    func waitUntilReady() async throws {
        try await readinessTask?.value
        guard readable, !isLoadingAuthority else { throw WishMachineError.unavailable }
    }

    private func loadAuthority() async throws {
        defer { isLoadingAuthority = false }
        let file = self.directory.appendingPathComponent("wishes.json")
        do {
                var open: [String: Any] = [:]
                let legacyData = try await Task.detached {
                    guard FileManager.default.fileExists(atPath: file.path) else { return Optional<Data>.none }
                    return try Data(contentsOf: file)
                }.value
                if let legacyData {
                    let archive = try Self.loadArchive(from: legacyData)
                    open["legacyArchive"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(archive))
                }
                try applyControlReceipt(await controlRequest("wish_control_open", open))
                let archive = Archive(authorizations: authorizations, jobs: workingJobs, events: events,
                    imageRegistrations: imageRegistrations, delegations: delegations, webReferences: webReferences,
                    pendingDrafts: pendingDrafts, unreadableJobs: unreadableJobs)
                guard Set(archive.jobs.map(\.id)).count == archive.jobs.count,
                      Set(archive.authorizations.map(\.id)).count == archive.authorizations.count,
                      Set((archive.delegations ?? []).map(\.id)).count == (archive.delegations ?? []).count,
                      Set((archive.imageRegistrations ?? []).map(\.attachment.id)).count == (archive.imageRegistrations ?? []).count,
                      Set((archive.webReferences ?? []).map(\.attachmentID)).count == (archive.webReferences ?? []).count else { throw WishMachineError.unavailable }
                workingJobs = archive.jobs; authorizations = archive.authorizations; events = archive.events
                imageRegistrations = archive.imageRegistrations ?? []
                delegations = archive.delegations ?? []
                webReferences = archive.webReferences ?? []
                pendingDrafts = archive.pendingDrafts ?? []
                unreadableJobs = archive.unreadableJobs ?? []
                _ = try await controlCommand("recover",[:])
        } catch {
            readable = false; errorMessage = WishMachineError.unavailable.localizedDescription
            throw error
        }
    }

    /// 逐条降级地读 `wishes.json`（G6）。
    ///
    /// - 第一遍是**整份严格解码**：绝大多数档案一次成功，行为与改造前逐字相同。
    /// - 只有整份解不出来时才走第二遍：`workingJobs` 逐条解码，坏的那一条进 `unreadableJobs`
    ///   （原始 JSON 原样留着，`persist()` 会把它写回去，**不丢数据**）；其余各段仍然
    ///   是"整段成立，否则整份读不出来" —— 授权/事件/委托的完整性是整个档案的前提。
    private static func loadArchive(from data: Data) throws -> Archive {
        let decoder = JSONDecoder()
        if let archive = try? decoder.decode(Archive.self, from: data) { return archive }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WishMachineError.unavailable
        }
        func payload(_ value: Any) throws -> Data {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value) else {
                throw WishMachineError.unavailable
            }
            return data
        }
        func section<T: Decodable>(_ key: String, _ type: T.Type) throws -> T {
            guard let value = root[key] else { throw WishMachineError.unavailable }
            return try decoder.decode(T.self, from: try payload(value))
        }
        func optionalSection<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            guard let value = root[key] else { return nil }
            guard let data = try? payload(value) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
        var decoded: [WishMachineJob] = []
        var unreadable = optionalSection("unreadableJobs", [WishMachineUnreadableJob].self) ?? []
        for element in (root["jobs"] as? [Any]) ?? [] {
            let object = element as? [String: Any]
            let raw = (try? payload(element)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
            do {
                decoded.append(try decoder.decode(WishMachineJob.self, from: Data(raw.utf8)))
            } catch {
                unreadable.append(.init(rawJSON: raw, jobID: object?["id"] as? String,
                                        name: object?["name"] as? String,
                                        reason: Self.readableDecodingReason(error)))
            }
        }
        return Archive(authorizations: try section("authorizations", [Authorization].self),
                       jobs: decoded,
                       events: try section("events", [WishMachineEvent].self),
                       imageRegistrations: optionalSection("imageRegistrations", [ImageRegistration].self),
                       delegations: optionalSection("delegations", [WishPlacementDelegation].self),
                       webReferences: optionalSection("webReferences", [ResidentWebReference].self),
                       pendingDrafts: optionalSection("pendingDrafts", [WishMachinePendingDraft].self),
                       unreadableJobs: unreadable.isEmpty ? nil : unreadable)
    }

    /// 「为什么这条读不出来」必须说得出**字段**，不是一句"解析失败"。
    private static func readableDecodingReason(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let name = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
                .joined(separator: ".")
            return name.isEmpty ? "（根）" : name
        }
        switch error {
        case let .keyNotFound(key, context): return "缺少字段 \(path(context)).\(key.stringValue)"
        case let .typeMismatch(_, context): return "字段 \(path(context)) 的类型不对"
        case let .valueNotFound(_, context): return "字段 \(path(context)) 没有值"
        case let .dataCorrupted(context): return "数据损坏：\(context.debugDescription)"
        @unknown default: return "解析失败"
        }
    }

    /// 档案现在读得出来吗（读不出来时列表**仍然**显示世界那一半，并顶一条横幅）。
    var isReadable: Bool { readable && !isLoadingAuthority }

    /// 「有几条 job 坏了、被跳过」那一句可见说明（没有坏的就是 nil）。
    ///
    /// 只报数量与名字：编号是内部标识（UUID），文件名是工程细节，都不上屏。
    var unreadableJobNotice: String? {
        guard !unreadableJobs.isEmpty else { return nil }
        let named = unreadableJobs.prefix(3).map { $0.name ?? "未命名" }
        let tail = unreadableJobs.count > named.count ? " 等" : ""
        return "有 \(unreadableJobs.count) 条记录读不出来，已经跳过："
            + named.joined(separator: "、") + tail
    }

    /// Host-only: call for an explicit user generation request, never for an autonomous wakeup.
    func authorize(attachments: [ResidentImageAttachment], worldID: String, residentScope: String,
                   authorizationID: UUID, source: PropGenerationSource) async throws {
        return try await withMutation {

        _ = try await controlCommand("authorize_images", ["worldID":worldID,"residentScope":residentScope,
            "authorizationID":authorizationID.uuidString,"attachments":try Self.controlJSON(attachments),
            "source":try Self.controlJSON(source)])

        }
    }

    /// Host-only: register image attachments scoped to one conversation/resident/world.
    /// Re-registering the same attachment in the same scope is idempotent.
    func registerImages(_ attachments: [ResidentImageAttachment], worldID: String, residentScope: String, conversationID: String) async throws {
        return try await withMutation {

        _ = try await controlCommand("register_images", ["worldID":worldID,"residentScope":residentScope,
            "conversationID":conversationID,"attachments":try Self.controlJSON(attachments)])

        }
    }

    func registeredImages(worldID: String, residentScope: String, conversationID: String, ids: [UUID]? = nil) -> [ResidentImageAttachment] {
        guard readable else { return [] }
        let scoped = imageRegistrations.filter { $0.worldID == worldID && $0.residentScope == residentScope && $0.conversationID == conversationID }
        if let ids { return ids.compactMap { id in scoped.first { $0.attachment.id == id }?.attachment } }
        return scoped.map(\.attachment)
    }

    /// Host-only: a later current user instruction reuses images registered in the same scope.
    func authorize(registeredImageIDs: [UUID], worldID: String, residentScope: String, conversationID: String,
                   authorizationID: UUID, source: PropGenerationSource) async throws {
        return try await withMutation {

        _ = try await controlCommand("authorize_registered", ["worldID":worldID,"residentScope":residentScope,
            "conversationID":conversationID,"registeredImageIDs":registeredImageIDs.map(\.uuidString),
            "authorizationID":authorizationID.uuidString,"source":try Self.controlJSON(source)])

        }
    }

    /// Host-only: append one resident-discovered public reference image to the current human
    /// turn's generation grant. A text-only turn has no grant yet, so the first registration
    /// creates it; a consumed grant can never grow, and a grant never crosses worlds/residents.
    /// The model supplies neither the authorization ID, the world nor a local path.
    @discardableResult
    func registerWebReference(_ attachment: ResidentImageAttachment, imageURL: URL, authorizationID: UUID,
                              worldID: String, residentScope: String,
                              source: PropGenerationSource) async throws -> ResidentWebReference {
        return try await withMutation {

        return try await controlDecision("register_web_reference",["worldID":worldID,"residentScope":residentScope,
            "authorizationID":authorizationID.uuidString,"attachment":try Self.controlJSON(attachment),
            "imageURL":imageURL.absoluteString,"source":try Self.controlJSON(source)],as:ResidentWebReference.self)

        }
    }

    /// Read-only provenance lookup for the read-discovery projection.
    func webReference(attachmentID: UUID) -> ResidentWebReference? {
        readable ? webReferences.first { $0.attachmentID == attachmentID } : nil
    }

    /// Host-only: narrow destination grant beside the generation authorization.
    @discardableResult
    func authorizePlacement(authorizationID: UUID, worldID: String, residentScope: String,
                            allowedSurfaceIDs: [String], explicitTarget: WishPlacementTarget? = nil) async throws -> WishPlacementDelegation {
        return try await withMutation {

        var fields: [String: Any] = ["authorizationID":authorizationID.uuidString,"worldID":worldID,
            "residentScope":residentScope,"allowedSurfaceIDs":allowedSurfaceIDs]
        if let explicitTarget { fields["explicitTarget"] = try Self.controlJSON(explicitTarget) }
        return try await controlDecision("delegation_authorize",fields,as:WishPlacementDelegation.self)

        }
    }

    func placementDelegations(worldID: String, residentScope: String) -> [WishPlacementDelegation] {
        guard readable else { return [] }
        return delegations.filter { $0.worldID == worldID && $0.residentScope == residentScope }
    }

    func placementDelegation(worldID: String, residentScope: String, objectID: String) -> WishPlacementDelegation? {
        guard readable else { return nil }
        return delegations.first { $0.worldID == worldID && $0.residentScope == residentScope && $0.objectID == objectID }
    }

    /// Dynamic pre-await validation against persisted delegation state. The host calls this
    /// before starting a delegated placement commit; it never depends on a live session lease.
    /// Surface-only grants bind the requested absolute target before any effect.
    func validatePlacementCommand(worldID: String, residentScope: String, objectID: String,
                                  surfaceID: String, target: WishPlacementTarget?) async throws -> WishPlacementDelegation {
        return try await withMutation {

        return try await resolvePlacementGrant(worldID: worldID, residentScope: residentScope, objectID: objectID,
            surfaceID: surfaceID, target: target)

        }
    }

    /// Host marks durable placement complete after the world commit succeeded. Idempotent by the
    /// stable persisted requestID: a crash between the world commit and this record replays without error.
    @discardableResult
    func recordPlacementCompletion(worldID: String, residentScope: String, objectID: String, requestID: String,
                                   surfaceID: String, target: WishPlacementTarget?) async throws -> WishPlacementDelegation {
        return try await withMutation {

        var fields: [String: Any] = ["worldID":worldID,"residentScope":residentScope,"objectID":objectID,
            "requestID":requestID,"surfaceID":surfaceID]
        if let target { fields["target"] = try Self.controlPlacementJSON(target) }
        return try await controlDecision("delegation_complete",fields,as:WishPlacementDelegation.self)

        }
    }

    /// Dynamic grant resolution for the background bridge. Validates persisted world/resident/
    /// object/state/surface against the requested placement; requires the job to be claimed.
    /// Surface-only grants persist the selected absolute target before any effect (overwritable).
    @discardableResult
    func resolvePlacementGrant(worldID: String, residentScope: String, objectID: String,
                               surfaceID: String, target: WishPlacementTarget?) async throws -> WishPlacementDelegation {
        return try await withMutation {

        var fields: [String: Any] = ["worldID":worldID,"residentScope":residentScope,"objectID":objectID,"surfaceID":surfaceID]
        if let target { fields["target"] = try Self.controlPlacementJSON(target) }
        return try await controlDecision("delegation_resolve",fields,as:WishPlacementDelegation.self)

        }
    }

    /// Host records that no legal spot exists; the item stays safely in inventory and only a
    /// fresh human placement instruction may retry.
    func markPlacementFailed(worldID: String, residentScope: String, objectID: String, reason: String) async throws {
        return try await withMutation {

        _ = try await controlCommand("delegation_fail",["worldID":worldID,"residentScope":residentScope,
            "objectID":objectID,"reason":reason])

        }
    }

    func submit(requestID: String, authorizationID: UUID, attachmentID: UUID, name: String,
                heightMeters: Double, sizeIntent: PropSizeIntent? = nil,
                worldID: String, residentScope: String,
                destination: WishPlacementDestination? = nil) async throws -> WishMachineJob {
        return try await withMutation {

        try Task.checkCancellation()
        var fields: [String: Any] = ["requestID":requestID,"authorizationID":authorizationID.uuidString,
            "attachmentID":attachmentID.uuidString,"name":name,"heightMeters":heightMeters,
            "worldID":worldID,"residentScope":residentScope]
        if let sizeIntent {fields["sizeIntent"] = try Self.controlJSON(sizeIntent)}
        if let destination {
            fields["destinationSurfaceIDs"] = destination.surfaceIDs
            if let target = destination.explicitTarget {fields["destinationTarget"] = try Self.controlJSON(target)}
        }
        let directive = try await controlDecision("submit_prepare",fields,as:SubmissionDirective.self)
        guard directive.action == "create" else {
            guard directive.action == "none" else {throw WishMachineError.unavailable}
            return directive.job
        }
        return try await executeSubmission(directive)

        }
    }

    func read(id: UUID, worldID: String, residentScope: String) throws -> WishMachineJob {
        workingJobs[try index(id: id, worldID: worldID, residentScope: residentScope)]
    }

    /// Only durable, scope-matched scene failures may influence presentation selection.
    ///
    /// ⚠️ 它返回的是**记录**（上一次推导说了什么），不是权威。可见性判据是
    /// `WishMachineOutputReachability`（读**现场**推导），记录只在还没有现场结论时
    /// 供出同一句具名原因。真机 2026-10-02「超大荧幕电视」就是把它当权威用的后果。
    func outputRenderFailure(id: UUID, worldID: String, residentScope: String) -> WishMachineEvent? {
        guard readable else { return nil }
        return events.first { $0.wishID == id && $0.worldID == worldID && $0.residentScope == residentScope
            && $0.kind == .failed && $0.failureSource == "renderer" }
    }

    /// A local scene-loading failure preserves the valid downloaded task and its asset.
    ///
    /// 这条记录是**最近一次推导**的结论，所以每一次推导都要能改写它：
    /// 旧行为是"已经有记录了就不再记"，于是修复前那句没有字段/数值的旧文案会永久留在盘上，
    /// 重新推导**仍然失败**时用户也读不到是哪一条判据、哪个数（新纪律要求具名）。
    /// 同一件产物永远只有一条 `failureSource == "renderer"` 的记录（幂等：同一句话不写第二遍）。
    func recordOutputRenderFailure(id: UUID, worldID: String, residentScope: String, message: String) async throws {
        return try await withMutation {

        _ = try await controlCommand("renderer_failure",["wishID":id.uuidString,"worldID":worldID,
            "residentScope":residentScope,"message":message])

        }
    }

    /// 现场推导**成功**了 ⇒ 那条陈旧结论必须消失：记录不是权威，推导才是。
    ///
    /// 判据**只能是**"重新推导成功"（调用方读的就是现场 `WishMachineOutputStatus.ready`）——
    /// 无条件清会把真失败也抹掉，那是另一种假话（新纪律）。
    /// 幂等：没有记录时一次写入都不发生，所以重复读取/重放不产生多余状态变更。
    @discardableResult
    func clearOutputRenderFailure(id: UUID, worldID: String, residentScope: String) async throws -> Bool {
        return try await withMutation {

        return try await controlDecision("renderer_clear",["wishID":id.uuidString,"worldID":worldID,
            "residentScope":residentScope],as:Bool.self)

        }
    }

    func residentJobs(worldID: String, residentScope: String) -> [WishMachineJob] {
        readable ? workingJobs.filter { $0.worldID == worldID && $0.residentScope == residentScope } : []
    }

    func attachmentChoices(authorizationID: UUID, worldID: String, residentScope: String) -> [(id: UUID, displayName: String)] {
        guard readable, let authorization = authorizations.first(where: { $0.id == authorizationID && $0.worldID == worldID && $0.residentScope == residentScope }) else { return [] }
        return authorization.attachments.map { (id: $0.id, displayName: $0.displayName) }
    }
    func isGenerationAuthorized(authorizationID:UUID,worldID:String,residentScope:String)->Bool {
        readable && controlViews.availableAuthorizations.contains {$0.id == authorizationID && $0.worldID == worldID && $0.residentScope == residentScope}
    }

    // MARK: - 还没提交的委托（信息不足 ⇒ 问一句 ⇒ 续同一份）

    /// 记下/更新一份"还没提交"的委托：原授权、原 `requestID`、原参数。
    ///
    /// 同一份委托只有一条：按 `id` 或 `(authorityID, requestID)` 命中即更新（并让 `attempt` +1）。
    /// 过期草稿顺手清掉 —— 过期之后不再可续，方向是"请用户重说一次"，不是"那就新建一次生成"。
    @discardableResult
    func recordPendingDraft(id: UUID = UUID(), authorityID: UUID, requestID: String, attachmentID: UUID,
                            name: String, destination: WishPlacementDestination?, needs: [String],
                            worldID: String, residentScope: String, now: Date = Date()) async throws -> WishMachinePendingDraft {
        return try await withMutation {

        var fields: [String: Any] = ["id":id.uuidString,"authorityID":authorityID.uuidString,"requestID":requestID,
            "attachmentID":attachmentID.uuidString,"name":name,"needs":needs,"worldID":worldID,"residentScope":residentScope]
        if let destination {
            fields["destinationSurfaceIDs"] = destination.surfaceIDs
            if let target = destination.explicitTarget {fields["destinationTarget"] = try Self.controlJSON(target)}
        }
        // The compatibility `now` argument is never sent to the production
        // authority. Expiry and creation are decided by Rust's wall clock.
        return try await controlDecision("draft_record",fields,as:WishMachinePendingDraft.self)

        }
    }

    /// 本 scope 里还没过期的草稿。读不到记录时返回空（不是"猜一份"）。
    func pendingDrafts(worldID: String, residentScope: String, now: Date = Date()) async throws -> [WishMachinePendingDraft] {
        try await withMutation {
            try await controlDecision("draft_list",["worldID":worldID,"residentScope":residentScope],as:[WishMachinePendingDraft].self)
        }
    }

    func resolvePendingDrafts(pendingID: UUID?, attachmentID: UUID, name: String,
                             worldID: String, residentScope: String) async throws -> WishMachineDraftResolution {
        try await withMutation {
            var fields: [String: Any] = ["attachmentID":attachmentID.uuidString,"name":name,
                "worldID":worldID,"residentScope":residentScope]
            if let pendingID {fields["pendingID"] = pendingID.uuidString}
            let value = try await controlCommand("draft_resolve",fields)
            guard let result = value as? [String: Any], let resolution = result["resolution"] as? String else {
                throw WishMachineError.unavailable
            }
            switch resolution {
            case "fresh": return .fresh
            case "resume": return .resume(try Self.controlDecode(WishMachinePendingDraft.self,from:result["draft"]))
            case "ambiguous": return .ambiguous(try Self.controlDecode([WishMachinePendingDraft].self,from:result["drafts"]))
            default: throw WishMachineError.unavailable
            }
        }
    }

    /// 提交成功之后把这一份草稿标成"已提交"并**留着**：同一个 `pending_id` 的再次调用
    /// 会被解析成同一个任务（幂等重放），而不是新建一件。崩在标记之前也没关系 ——
    /// 复核看的是"这份授权下有没有任务"，标记只是让**自动**续办不再重复命中它。
    func markPendingDraftSubmitted(id: UUID, jobID: UUID, now: Date = Date()) async throws {
        return try await withMutation {

        _ = try await controlCommand("draft_submit",["id":id.uuidString,"jobID":jobID.uuidString])

        }
    }

    func claimEvidence(id: UUID, worldID: String, residentScope: String) throws -> WishMachineClaimEvidence? {
        canClaim(try read(id: id, worldID: worldID, residentScope: residentScope))
    }

    /// 允许重试的阶段 —— **唯一一份**：`retry()` 的 guard 与界面上那一枚按钮读的是它，
    /// 于是"按钮亮了却重试不了"与"按钮灰着其实能重试"在结构上都不可能。
    ///
    /// `.failed` 在里面（见 `retry()` 里那段说明）：重试照旧只复用**原身份**重放原提交。
    static let retryableStages: Set<WishMachineStage> = [.submissionUncertain, .submitting, .generated, .failed]

    /// Explicit confirmation only. A persisted core request is replayed with its original image and key.
    @discardableResult func retry(id: UUID, worldID: String, residentScope: String) async throws -> WishMachineJob {
        return try await withMutation {

        await store.refreshSnapshot()
        try Task.checkCancellation()
        let fields: [String: Any] = ["wishID":id.uuidString,"worldID":worldID,"residentScope":residentScope]
        let directive = try await controlDecision("retry_prepare",fields,as:SubmissionDirective.self)
        switch directive.action {
        case "none": return directive.job
        case "create": return try await executeSubmission(directive)
        case "retry":
            guard let coreID = directive.job.jobID else {throw WishMachineError.unavailable}
            await store.retrySubmission(id:coreID)
            return try await controlDecision("submit_finish",fields,as:WishMachineJob.self)
        default: throw WishMachineError.unavailable
        }

        }
    }

    @discardableResult func refresh(id: UUID, worldID: String, residentScope: String) async throws -> WishMachineJob {
        return try await withMutation {
        await store.refreshSnapshot()
        return try await controlDecision("observe",["wishID":id.uuidString,"worldID":worldID,
            "residentScope":residentScope],as:WishMachineJob.self)
        }
    }

    /// Bounded automatic confirmation of a network-class unknown submission.
    ///
    /// Why this exists: the daemon deliberately stops scheduling a submission whose outcome
    /// is unknown (`submission_uncertain` is excluded from its due stages), so `last_error`
    /// stays `network_unavailable` forever and the panel keeps showing a network failure long
    /// after the network is back. Confirmation reuses the original identity (same wish, same
    /// daemon job, same image, same idempotency key) through the exact `retry` path the
    /// explicit `retry_wish_generation` tool uses: it never creates a second generation and
    /// never consumes another authorization. Only genuinely network-class errors qualify —
    /// a rejected or unauthenticated submission is a real outcome and is never reissued.
    /// 次数与间隔都来自**唯一**的策略定义（`RetryBackoff.swift` 的
    /// `RetryBackoffSite.generationConfirmation`）：既有 3 次 / 30 秒逐位不变，
    /// 之后的等待翻倍、带抖动、封顶。复用原幂等身份这条语义不搬进策略。
    static var maximumNetworkConfirmationsPerJob: Int {
        RetryBackoffSite.generationConfirmation.policy.maximumAttempts
    }
    /// Two automatic confirmations of the same task are at least this far apart, so a
    /// still-broken remote endpoint cannot be hammered by the host's 5-second refresh.
    static var minimumNetworkConfirmationInterval: TimeInterval {
        RetryBackoffSite.generationConfirmation.policy.baseDelay
    }

    static func isNetworkClassSubmissionError(_ message: String?) -> Bool {
        guard let message else { return false }
        // 「什么算连通性事实」只有**一份**判据（`ResidentConnectivityFact.vocabulary`）：
        // 这里委托过去，不再各存一套词汇表 —— 否则"是不是网络类"会有两个答案，
        // 而呈现侧（全局横幅）与判定侧（自愈确认）正好会因此互相矛盾。
        return ResidentConnectivityFact.isConnectivityLine(message)
    }

    /// Injectable clock (same seam the resident loop uses) so the confirmation backoff is
    /// deterministic in harnesses instead of depending on wall time.
    var now: () -> Date = { Date() }

    @discardableResult
    func confirmNetworkUncertainSubmissions() async -> Int {
        do { return try await withMutation {
        guard readable, store.errorMessage == nil else { return 0 }
        let pending = try await controlDecision("confirmation_prepare",[:],as:[SubmissionDirective].self)
        var confirmed = 0
        for directive in pending {
            let original = directive.job
            let result: WishMachineJob
            switch directive.action {
            case "none": result = original
            case "create": result = try await executeSubmission(directive)
            case "retry":
                guard let coreID = original.jobID else {throw WishMachineError.unavailable}
                await store.retrySubmission(id:coreID)
                result = try await controlDecision("submit_finish",["wishID":original.id.uuidString,
                    "worldID":original.worldID,"residentScope":original.residentScope],as:WishMachineJob.self)
            default: throw WishMachineError.unavailable
            }
            if result.stage != .submissionUncertain || result.lastError != original.lastError {confirmed += 1}
        }
        return confirmed
        } } catch { return 0 }
    }

    func refreshPending(limit: Int = 2) async {
        guard (try? await waitUntilReady()) != nil else { return }
        guard readable, limit > 0 else { return }
        await store.refreshSnapshot()
        await synchronizeBackendSnapshot()
        // 暂停的重新校验**不依赖后端**：它纯本地、幂等，唯一的判据是"有没有用户意图证据"。
        // 后端没配好时，遗留的非用户暂停同样必须自愈，而不是继续要求人工解除——那正是
        // 用户抱怨的多余一步。run 级用户停止与"奉命轮"规则仍然各自把住每一次自主领取。
        await discardPausesWithoutUserIntent()
        // 网络类未知提交的自动确认必须等后端真的可达：它要复用原幂等身份去确认/重发，
        // 门槛之外只会制造无效请求。所以健康判定只留给这一条。
        let healthy = store.errorMessage == nil
        guard healthy else { return }
        await confirmNetworkUncertainSubmissions()
    }

    @discardableResult func cancel(id: UUID, worldID: String, residentScope: String) async throws -> WishMachineJob {
        return try await withMutation {
        let fields: [String: Any] = ["wishID":id.uuidString,"worldID":worldID,"residentScope":residentScope]
        let directive = try await controlDecision("cancel_prepare",fields,as:SubmissionDirective.self)
        if directive.action == "none" {return directive.job}
        guard directive.action == "cancel", let coreID = directive.job.jobID else {throw WishMachineError.unavailable}
        await store.cancel(id: coreID)
        return try await controlDecision("observe",fields,as:WishMachineJob.self)
        }
    }

    /// 「这一件现在能不能领」——**唯一**一份判据。
    ///
    /// `claim()` 自己与界面上那一枚「领取」按钮读的是**同一个表达式**，所以
    /// "按钮亮了却领不到"与"按钮灰着其实能领"在结构上都不可能。判据本身**一个字都没改**：
    /// 仍然要求 `activityID == "wish_machine.collect"`、`phase == "loop"`、
    /// `distanceMeters ∈ 0...0.25`、`outputAvailable`（`WishMachineCoordinator.claim` 的原文）。
    func claimAvailability(id: UUID, worldID: String, residentScope: String) -> Result<WishMachineJob, WishMachineError> {
        guard let index = try? index(id: id, worldID: worldID, residentScope: residentScope) else {
            return .failure(.wrongScope)
        }
        let job = workingJobs[index]
        if job.stage == .claimed { return .success(job) }
        guard job.stage == .ready, let path = job.modelPath, FileManager.default.fileExists(atPath: path) else { return .failure(.notReady) }
        guard let evidence = canClaim(job), evidence.worldID == worldID, evidence.activityID == "wish_machine.collect",
              evidence.phase == "loop", evidence.distanceMeters.isFinite, (0...0.25).contains(evidence.distanceMeters),
              evidence.outputAvailable else { return .failure(.notAtMachine) }
        return .success(job)
    }

    func claim(id: UUID, worldID: String, residentScope: String) async throws -> WishMachineJob {
        return try await withMutation {

        let job = try read(id:id,worldID:worldID,residentScope:residentScope)
            if job.stage == .claimed { return job }
            guard let evidence=canClaim(job) else {throw WishMachineError.notAtMachine}
            var observation:[String:Any]=["worldID":evidence.worldID,"distanceMeters":evidence.distanceMeters,
                "outputAvailable":evidence.outputAvailable]
            observation["activityID"]=evidence.activityID;observation["phase"]=evidence.phase
            observation["activityRequestID"]=evidence.activityRequestID;observation["activityGeneration"]=evidence.activityGeneration
            observation["phaseGeneration"]=evidence.phaseGeneration;observation["activityHostSessionID"]=evidence.activityHostSessionID
            observation["objectID"]=evidence.objectID
            do {try applyControlReceipt(await controlRequest("wish_control_claim", [
                "wishID": id.uuidString, "worldID": worldID, "residentScope": residentScope,"observation":observation]))}
            catch PropTaskDaemonError.requestRejectedWith(let code) {
                switch code {
                case "wish_control_not_at_machine": throw WishMachineError.notAtMachine
                case "wish_control_not_ready": throw WishMachineError.notReady
                case "wish_control_wrong_scope": throw WishMachineError.wrongScope
                case "wish_control_unauthorized": throw WishMachineError.unauthorized
                default: throw WishMachineError.unavailable
                }
            }
            notifyChange()
            return try read(id: id, worldID: worldID, residentScope: residentScope)
        }
    }

    func readyOutputs(worldID: String) -> [WishMachineOutputDescriptor] {
        guard readable else { return [] }
        return workingJobs.compactMap { job in
            guard job.worldID == worldID, job.stage == .ready, let path = job.modelPath,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            // `height_meters` 是**生成请求**的高度：托盘上这一件还没登记，所以必须带上
            // "这是请求高度"这个事实，渲染端才会先过一遍尺度策略（细长物件按最长边归一）。
            // 真机 2026-10-01 那把剑就是在这里按高度归一的：0.133 m 的"高度"被拉到 1.1 m，
            // 于是 1.005 m 长的剑变成 8.285 m，横跨整个舱室。
            return .init(id: job.objectID, worldID: worldID, modelURL: URL(fileURLWithPath: path),
                         targetHeightMeters: Float(job.heightMeters),
                         heightIsGenerationRequest: true, sizeIntent: job.sizeIntent)
        }
    }
    func pendingEvents(worldID: String, residentScope: String) -> [WishMachineEvent] {
        guard readable else { return [] }
        return controlViews.pendingEvents.filter {$0.worldID == worldID && $0.residentScope == residentScope}
    }

    /// Local fact outbox only. Rust owns delivery and separate world/UI/agent acknowledgements.
    /// Previously acknowledged legacy events must not be broadcast again during migration.
    func unpublishedEvents(worldID: String, residentScope: String) -> [WishMachineEvent] {
        guard readable else { return [] }
        return controlViews.unpublishedEvents.filter {$0.worldID == worldID && $0.residentScope == residentScope}
    }

    /// Call only after publish_message returned its durable acknowledgement for this same event ID.
    func markEventPublished(id: UUID) async throws {
        return try await withMutation {

        _ = try await controlCommand("event_published",["eventID":id.uuidString])

        }
    }

    func automaticContinuationEvents(worldID: String, residentScope: String) -> [WishMachineEvent] {
        guard readable else {return []}
        return controlViews.continuationEvents.filter {$0.worldID == worldID && $0.residentScope == residentScope}
    }

    /// A current human turn may renew only this wish's original follow-through.
    /// The host supplies claimed-item readback; provider state and world effects are untouched.
    @discardableResult
    func resumeContinuations(id: UUID, worldID: String, residentScope: String, authorizationID: UUID,
                             placementAlreadyCompleted: Bool? = nil) async throws -> WishMachineJob {
        return try await withMutation {

        _ = try index(id: id, worldID: worldID, residentScope: residentScope)
        var params: [String: Any] = ["wishID": id.uuidString, "worldID": worldID,
                                    "residentScope": residentScope, "authorizationID": authorizationID.uuidString]
        if let placementAlreadyCompleted { params["placementAlreadyCompleted"] = placementAlreadyCompleted }
        let previousRevision = controlRevision
        try applyControlReceipt(await controlRequest("wish_control_resume", params))
        if controlRevision != previousRevision { notifyChange() }
        return try read(id: id, worldID: worldID, residentScope: residentScope)

        }
    }

    /// Stop automatic follow-through for existing commissions only. Keep their facts and assets intact.
    ///
    /// Host contract: call this **only** for an explicit user stop (the interface's stop
    /// control). Everything else — a network/submission failure, a backend becoming
    /// unavailable, a world switch, an app quit — must not write this pause, because the
    /// only way back is a human action and the user never asked for one. The pause records
    /// its own user-intent provenance so a pause written by an older build (or by any other
    /// path) can be re-validated and lifted by `await discardPausesWithoutUserIntent()`.
    func pauseContinuations(worldID: String, residentScope: String) async throws {
        return try await withMutation {

        guard readable else { throw WishMachineError.unavailable }
        do {
            try applyControlReceipt(await controlRequest("wish_control_pause", ["worldID": worldID, "residentScope": residentScope]))
            notifyChange()
        } catch {
            // A lost durable receipt must not permit in-process follow-through.
            readable = false
            errorMessage = WishMachineError.pauseNotPersisted.localizedDescription
            throw WishMachineError.pauseNotPersisted
        }

        }
    }

    /// Re-validate every persisted task-level pause against its provenance: a pause may only
    /// keep demanding a manual release when an explicit user stop wrote it. Pauses written by
    /// an older build (or by any non-user path) carry no such evidence, so they are lifted
    /// here, together with the placements revoked by that same pause, and the change is
    /// emitted as a durable fact. This is deliberately narrow: the run-level user stop
    /// (`ResidentAgentLoop`) and the "human-ordered turn" rule still gate every autonomous
    /// claim, so lifting a task pause can never start an unsupervised pickup.
    ///
    /// Returns how many tasks were released. Called only while the backend is healthy.
    @discardableResult
    func discardPausesWithoutUserIntent() async -> Int {
        do { return try await withMutation {
        guard readable else { return 0 }
        let count = workingJobs.filter { $0.autoContinuationPaused == true && $0.autoContinuationStoppedByUser != true }.count
        guard count > 0 else { return 0 }
        do {
            try applyControlReceipt(await controlRequest("wish_control_discard_unproven_pauses", [:]))
            notifyChange()
            return count
        } catch { return 0 }
        } } catch { return 0 }
    }

    /// Stop revokes incomplete delegations durably; revocation never revives on restart or world switch.
    func revokePlacementDelegations(worldID: String, residentScope: String) async throws {
        return try await withMutation {

        _ = try await controlCommand("delegation_revoke",["worldID":worldID,"residentScope":residentScope])

        }
    }
    func acknowledgeEvent(id: UUID) async throws {
        return try await withMutation {

        guard readable else { throw WishMachineError.unavailable }
        guard let event = events.first(where: { $0.id == id }), !event.acknowledged else { return }
        try applyControlReceipt(await controlRequest("wish_control_event_ack", [
            "eventID": id.uuidString, "worldID": event.worldID, "residentScope": event.residentScope]))
        notifyChange()

        }
    }

    func isEventAcknowledged(id: UUID, worldID: String, residentScope: String) -> Bool {
        guard readable else { return false }
        return events.contains { $0.id == id && $0.worldID == worldID
            && $0.residentScope == residentScope && $0.acknowledged }
    }

    func acknowledgeEvent(id: UUID, worldID: String, residentScope: String) async throws {
        return try await withMutation {

        guard readable else { throw WishMachineError.unavailable }
        guard events.contains(where: { $0.id == id && $0.worldID == worldID
            && $0.residentScope == residentScope }) else { throw WishMachineError.wrongScope }
        try await acknowledgeEvent(id: id)

        }
    }

    /// Durable backend subscription updates drive the same world/UI/agent facts as a manual read.
    private func synchronizeBackendSnapshot() async {
        do {
            try await withMutation {
                _ = try await controlCommand("observe_all",[:])
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func index(id: UUID, worldID: String, residentScope: String) throws -> Int {
        guard readable, !isLoadingAuthority else { throw WishMachineError.unavailable }
        guard let index = workingJobs.firstIndex(where: { $0.id == id }), workingJobs[index].worldID == worldID,
              workingJobs[index].residentScope == residentScope else { throw WishMachineError.wrongScope }
        return index
    }

    private static func controlJSON<T: Encodable>(_ value: T) throws -> Any {
        do {return try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))}
        catch {throw PropGenerationError.invalidInput}
    }
    private static func controlPlacementJSON(_ value: WishPlacementTarget) throws -> Any {
        do {return try controlJSON(value)}
        catch {throw WishMachineError.conflictingCall}
    }
    private static func controlDecode<T: Decodable>(_ type: T.Type, from value: Any?) throws -> T {
        guard let value else {throw WishMachineError.unavailable}
        return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed))
    }
    private func controlDecision<T: Decodable>(_ command: String, _ fields: [String: Any], as type: T.Type) async throws -> T {
        try Self.controlDecode(type,from:try await controlCommand(command,fields))
    }
    private struct SubmissionDirective: Decodable {
        let job: WishMachineJob
        let action: String
        let imageURL: URL?
        let source: PropGenerationSource?
    }
    private struct ControlViews: Decodable {
        var pendingEvents: [WishMachineEvent] = []
        var unpublishedEvents: [WishMachineEvent] = []
        var continuationEvents: [WishMachineEvent] = []
        var availableAuthorizations: [Authorization] = []
    }
    private var controlViews = ControlViews()
    private func executeSubmission(_ directive: SubmissionDirective) async throws -> WishMachineJob {
        let job = directive.job
        guard let coreID = job.jobID, let imageURL = directive.imageURL, let source = directive.source else {
            throw WishMachineError.unavailable
        }
        _ = await store.create(imageURL:imageURL,name:job.name,author:source.author,license:source.license,
            heightMeters:job.heightMeters,sizeIntent:job.sizeIntent,id:coreID,
            context:PropTaskContext(worldID:job.worldID,residentScope:job.residentScope))
        var fields: [String: Any] = ["wishID":job.id.uuidString,"worldID":job.worldID,"residentScope":job.residentScope]
        if let error = store.errorMessage {fields["nativePreparationError"] = error}
        return try await controlDecision("submit_finish",fields,as:WishMachineJob.self)
    }
    private func controlCommand(_ command: String, _ fields: [String: Any]) async throws -> Any {
        guard readable else {throw WishMachineError.unavailable}
        var fields = fields; fields["command"] = command
        do {
            let previousRevision = controlRevision
            let receipt = try await controlRequest("wish_control_command",fields)
            try applyControlReceipt(receipt)
            if controlRevision != previousRevision {notifyChange()}
            guard let result = receipt["result"] else {throw WishMachineError.unavailable}
            return result
        } catch PropTaskDaemonError.requestRejectedWith(let code) {
            switch code {
            case "wish_control_wrong_scope": throw WishMachineError.wrongScope
            case "wish_control_unauthorized": throw WishMachineError.unauthorized
            case "wish_control_conflicting_call": throw WishMachineError.conflictingCall
            case "wish_control_placement_revoked": throw WishMachineError.placementRevoked
            case "wish_control_invalid_request": throw PropGenerationError.invalidInput
            case "wish_control_unknown_attachment": throw WishMachineError.unknownAttachment
            case "wish_control_consumed_authorization": throw WishMachineError.consumedAuthorization
            case "wish_control_image_limit": throw WishMachineError.imageLimitReached
            case "wish_control_retry_unavailable": throw WishMachineError.retryUnavailable
            case "wish_control_not_ready": throw WishMachineError.notReady
            default:
                readable = false; errorMessage = WishMachineError.unavailable.localizedDescription
                throw WishMachineError.unavailable
            }
        } catch {
            readable = false; errorMessage = WishMachineError.unavailable.localizedDescription
            throw WishMachineError.unavailable
        }
    }

    private func controlRequest(_ method: String, _ fields: [String: Any]) async throws -> [String: Any] {
        var params = fields
        params["ownerID"] = controlOwnerID; params["hostSessionID"] = controlSessionID
        params["expectedRevision"] = controlRevision
        let data = try JSONSerialization.data(withJSONObject: params)
        let response = try await controlCall(method, data)
        guard let receipt = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw WishMachineError.unavailable
        }
        return receipt
    }

    private func applyControlReceipt(_ receipt: [String: Any]) throws {
        guard let revision = receipt["revision"] as? Int, revision >= 0,
              let value = receipt["archive"] else { throw WishMachineError.unavailable }
        let archive = try Self.loadArchive(from: JSONSerialization.data(withJSONObject: value))
        let views = try Self.controlDecode(ControlViews.self,from:receipt["views"])
        controlRevision = revision
        committedArchive = archive
        installArchive(archive)
        controlViews = views
    }

    private func installArchive(_ archive: Archive) {
        // Observer-created tasks must queue as new requests, not inherit this mutation's lease.
        WishMutationScope.$owner.withValue(nil) {
        workingJobs = archive.jobs; authorizations = archive.authorizations; events = archive.events
        imageRegistrations = archive.imageRegistrations ?? []; delegations = archive.delegations ?? []
        webReferences = archive.webReferences ?? []; pendingDrafts = archive.pendingDrafts ?? []
        unreadableJobs = archive.unreadableJobs ?? []
        jobs = archive.jobs
        }
    }

    private func notifyChange() {
        WishMutationScope.$owner.withValue(nil) { onChange?() }
    }
    /// Only public HTTPS on the standard port; credentials, other schemes and
    /// alternate ports are rejected before any download is attempted.
    private static func isPublicReferenceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return url.port == nil || url.port == 443
    }
}
