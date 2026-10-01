import Foundation
import Combine
import Darwin

enum WishMachineStage: String, Codable, Sendable {
    case submitting, submissionUncertain, generating, generated, ready, failed, cancelled, interrupted, claimed
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
    // wrote — so `discardPausesWithoutUserIntent()` lifts it as soon as the backend is
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
extension WishMachineJob {
    var sizeIntentLine: String? {
        guard let sizeIntent else { return nil }
        return "尺寸：\(sizeIntent.summary)"
    }
}

struct WishMachineClaimEvidence {
    let worldID: String
    let activityID: String?
    let phase: String?
    let distanceMeters: Double
    let outputAvailable: Bool
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
    /// Compares through canonical Float coordinates so JSON-decimal doubles and Float
    /// round-trips (0.1, 0.3, ...) compare equal consistently.
    func canonicalEquals(_ other: WishPlacementTarget) -> Bool {
        surfaceID == other.surfaceID
            && Float(position.x) == Float(other.position.x)
            && Float(position.y) == Float(other.position.y)
            && Float(position.z) == Float(other.position.z)
            && Float(yaw) == Float(other.yaw)
    }
}

/// Structured destination carried by the submit tool when the user explicitly asks to place the result.
struct WishPlacementDestination: Equatable, Sendable {
    let surfaceIDs: [String]
    let explicitTarget: WishPlacementTarget?
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
        case .retryUnavailable: return "只能确认结果未明的原提交；新生成需要用户重新发起。"
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
    }
    @Published private(set) var jobs: [WishMachineJob] = []
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
    private var readable = true

    init(store: PropGenerationStore, directory: URL? = nil, archiveFileManager: FileManager = .default,
         canClaim: @escaping @MainActor (WishMachineJob) -> WishMachineClaimEvidence?) {
        self.store = store
        self.archiveFileManager = archiveFileManager
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gmgn radio/WishMachine", isDirectory: true)
        self.canClaim = canClaim
        let file = self.directory.appendingPathComponent("wishes.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard Set(archive.jobs.map(\.id)).count == archive.jobs.count,
                      Set(archive.authorizations.map(\.id)).count == archive.authorizations.count,
                      Set((archive.delegations ?? []).map(\.id)).count == (archive.delegations ?? []).count,
                      Set((archive.imageRegistrations ?? []).map(\.attachment.id)).count == (archive.imageRegistrations ?? []).count,
                      Set((archive.webReferences ?? []).map(\.attachmentID)).count == (archive.webReferences ?? []).count else { throw WishMachineError.unavailable }
                jobs = archive.jobs; authorizations = archive.authorizations; events = archive.events
                imageRegistrations = archive.imageRegistrations ?? []
                delegations = archive.delegations ?? []
                webReferences = archive.webReferences ?? []
                // An interrupted local submit is never automatically repeated. Its grant stays consumed.
                for index in jobs.indices where jobs[index].stage == .submitting {
                    jobs[index].stage = .submissionUncertain
                    jobs[index].lastError = "提交结果未确认，可确认原提交；不会自动再次生成。"
                    emit(index: index, kind: .stateChanged)
                }
                try persist()
            } catch { readable = false; errorMessage = WishMachineError.unavailable.localizedDescription }
        }
        store.onChange = { [weak self] in self?.synchronizeBackendSnapshot() }
        synchronizeBackendSnapshot()
    }

    /// Host-only: call for an explicit user generation request, never for an autonomous wakeup.
    func authorize(attachments: [ResidentImageAttachment], worldID: String, residentScope: String,
                   authorizationID: UUID, source: PropGenerationSource) throws {
        guard readable else { throw WishMachineError.unavailable }
        guard !worldID.isEmpty, !residentScope.isEmpty, !attachments.isEmpty, attachments.count <= 4,
              attachments.allSatisfy({ $0.url.isFileURL }), Set(attachments.map(\.id)).count == attachments.count else { throw WishMachineError.unknownAttachment }
        if let existing = authorizations.first(where: { $0.id == authorizationID }) {
            guard existing.worldID == worldID, existing.residentScope == residentScope,
                  existing.attachments == attachments, existing.source == source else { throw WishMachineError.conflictingCall }
            return
        }
        authorizations.append(.init(id: authorizationID, attachments: attachments, worldID: worldID, residentScope: residentScope, source: source))
        try persist()
    }

    /// Host-only: register image attachments scoped to one conversation/resident/world.
    /// Re-registering the same attachment in the same scope is idempotent.
    func registerImages(_ attachments: [ResidentImageAttachment], worldID: String, residentScope: String, conversationID: String) throws {
        guard readable else { throw WishMachineError.unavailable }
        guard !worldID.isEmpty, !residentScope.isEmpty, !conversationID.isEmpty else { throw WishMachineError.wrongScope }
        guard !attachments.isEmpty, attachments.allSatisfy({ $0.url.isFileURL }) else { throw WishMachineError.unknownAttachment }
        var changed = false
        for attachment in attachments {
            if let existing = imageRegistrations.firstIndex(where: { $0.attachment.id == attachment.id }) {
                guard imageRegistrations[existing].worldID == worldID, imageRegistrations[existing].residentScope == residentScope,
                      imageRegistrations[existing].conversationID == conversationID,
                      imageRegistrations[existing].attachment == attachment else { throw WishMachineError.wrongScope }
                continue
            }
            imageRegistrations.append(.init(attachment: attachment, worldID: worldID, residentScope: residentScope, conversationID: conversationID))
            changed = true
        }
        if changed { try persist() }
    }

    func registeredImages(worldID: String, residentScope: String, conversationID: String, ids: [UUID]? = nil) -> [ResidentImageAttachment] {
        guard readable else { return [] }
        let scoped = imageRegistrations.filter { $0.worldID == worldID && $0.residentScope == residentScope && $0.conversationID == conversationID }
        if let ids { return ids.compactMap { id in scoped.first { $0.attachment.id == id }?.attachment } }
        return scoped.map(\.attachment)
    }

    /// Host-only: a later current user instruction reuses images registered in the same scope.
    func authorize(registeredImageIDs: [UUID], worldID: String, residentScope: String, conversationID: String,
                   authorizationID: UUID, source: PropGenerationSource) throws {
        let attachments = registeredImages(worldID: worldID, residentScope: residentScope, conversationID: conversationID, ids: registeredImageIDs)
        guard !registeredImageIDs.isEmpty, attachments.count == registeredImageIDs.count else { throw WishMachineError.unknownAttachment }
        try authorize(attachments: attachments, worldID: worldID, residentScope: residentScope, authorizationID: authorizationID, source: source)
    }

    /// Host-only: append one resident-discovered public reference image to the current human
    /// turn's generation grant. A text-only turn has no grant yet, so the first registration
    /// creates it; a consumed grant can never grow, and a grant never crosses worlds/residents.
    /// The model supplies neither the authorization ID, the world nor a local path.
    @discardableResult
    func registerWebReference(_ attachment: ResidentImageAttachment, imageURL: URL, authorizationID: UUID,
                              worldID: String, residentScope: String,
                              source: PropGenerationSource) throws -> ResidentWebReference {
        guard readable else { throw WishMachineError.unavailable }
        guard !worldID.isEmpty, !residentScope.isEmpty, attachment.url.isFileURL else { throw WishMachineError.wrongScope }
        guard Self.isPublicReferenceURL(imageURL) else { throw WishMachineError.unknownAttachment }
        guard !jobs.contains(where: { $0.authorizationID == authorizationID }) else { throw WishMachineError.consumedAuthorization }
        let reference = ResidentWebReference(attachmentID: attachment.id, imageURL: imageURL, source: source)
        // Validate every input against current state before mutating anything so a rejected
        // call can never leave a partial grant in memory.
        if let existing = webReferences.firstIndex(where: { $0.attachmentID == attachment.id }) {
            guard webReferences[existing] == reference else { throw WishMachineError.conflictingCall }
        }
        var candidateAuthorizations = authorizations
        if let index = candidateAuthorizations.firstIndex(where: { $0.id == authorizationID }) {
            guard candidateAuthorizations[index].worldID == worldID, candidateAuthorizations[index].residentScope == residentScope else {
                throw WishMachineError.wrongScope
            }
            if let existingAttachment = candidateAuthorizations[index].attachments.first(where: { $0.id == attachment.id }) {
                // The stable attachment id must describe the exact same image; a different
                // URL or name is a conflict, never a silent replacement of the registered one.
                guard existingAttachment == attachment else { throw WishMachineError.conflictingCall }
            } else {
                guard candidateAuthorizations[index].attachments.count < 4 else { throw WishMachineError.imageLimitReached }
                candidateAuthorizations[index].attachments.append(attachment)
            }
        } else {
            candidateAuthorizations.append(.init(id: authorizationID, attachments: [attachment], worldID: worldID,
                residentScope: residentScope, source: source))
        }
        var candidateWebReferences = webReferences
        if !candidateWebReferences.contains(where: { $0.attachmentID == attachment.id }) {
            candidateWebReferences.append(reference)
        }
        let priorAuthorizations = authorizations, priorWebReferences = webReferences
        authorizations = candidateAuthorizations
        webReferences = candidateWebReferences
        do { try persist() }
        catch {
            // A failed durable write must never leave the new in-memory grant visible.
            authorizations = priorAuthorizations
            webReferences = priorWebReferences
            throw error
        }
        return reference
    }

    /// Read-only provenance lookup for the read-discovery projection.
    func webReference(attachmentID: UUID) -> ResidentWebReference? {
        readable ? webReferences.first { $0.attachmentID == attachmentID } : nil
    }

    /// Host-only: narrow destination grant beside the generation authorization.
    @discardableResult
    func authorizePlacement(authorizationID: UUID, worldID: String, residentScope: String,
                            allowedSurfaceIDs: [String], explicitTarget: WishPlacementTarget? = nil) throws -> WishPlacementDelegation {
        guard readable else { throw WishMachineError.unavailable }
        guard authorizations.contains(where: { $0.id == authorizationID && $0.worldID == worldID && $0.residentScope == residentScope }) else { throw WishMachineError.unauthorized }
        let surfaces = try Self.validatedSurfaceIDs(allowedSurfaceIDs, explicitTarget: explicitTarget)
        if let existing = delegations.first(where: { $0.authorizationID == authorizationID }) {
            guard existing.allowedSurfaceIDs == surfaces, existing.explicitTarget == explicitTarget else { throw WishMachineError.conflictingCall }
            return existing
        }
        let delegation = WishPlacementDelegation(id: UUID(), authorizationID: authorizationID,
            requestID: "placement." + UUID().uuidString.lowercased(), worldID: worldID, residentScope: residentScope,
            allowedSurfaceIDs: surfaces, explicitTarget: explicitTarget, objectID: nil,
            state: .awaitingSubmission, lastError: nil)
        delegations.append(delegation)
        try persist()
        return delegation
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
                                  surfaceID: String, target: WishPlacementTarget?) throws -> WishPlacementDelegation {
        return try resolvePlacementGrant(worldID: worldID, residentScope: residentScope, objectID: objectID,
            surfaceID: surfaceID, target: target)
    }

    /// Host marks durable placement complete after the world commit succeeded. Idempotent by the
    /// stable persisted requestID: a crash between the world commit and this record replays without error.
    @discardableResult
    func recordPlacementCompletion(worldID: String, residentScope: String, objectID: String, requestID: String,
                                   surfaceID: String, target: WishPlacementTarget?) throws -> WishPlacementDelegation {
        guard readable else { throw WishMachineError.unavailable }
        guard let index = delegations.firstIndex(where: { $0.worldID == worldID && $0.residentScope == residentScope && $0.objectID == objectID && $0.requestID == requestID }) else { throw WishMachineError.unauthorized }
        switch delegations[index].state {
        case .placed: return delegations[index]
        case .pending:
            guard delegations[index].allowedSurfaceIDs.contains(surfaceID) else { throw WishMachineError.conflictingCall }
            if let explicit = delegations[index].explicitTarget {
                guard let target, explicit.canonicalEquals(target) else { throw WishMachineError.conflictingCall }
            } else {
                guard let target, let bound = delegations[index].boundTarget, bound.canonicalEquals(target) else { throw WishMachineError.conflictingCall }
            }
            delegations[index].state = .placed
            delegations[index].lastError = nil
            if let jobIndex = jobs.firstIndex(where: { $0.objectID == objectID && $0.worldID == worldID && $0.residentScope == residentScope }) {
                emit(index: jobIndex, kind: .placed)
            }
            try persist()
            return delegations[index]
        case .revoked: throw WishMachineError.placementRevoked
        case .awaitingSubmission, .failed: throw WishMachineError.unauthorized
        }
    }

    /// Dynamic grant resolution for the background bridge. Validates persisted world/resident/
    /// object/state/surface against the requested placement; requires the job to be claimed.
    /// Surface-only grants persist the selected absolute target before any effect (overwritable).
    @discardableResult
    func resolvePlacementGrant(worldID: String, residentScope: String, objectID: String,
                               surfaceID: String, target: WishPlacementTarget?) throws -> WishPlacementDelegation {
        guard readable else { throw WishMachineError.unavailable }
        guard let index = delegations.firstIndex(where: { $0.worldID == worldID && $0.residentScope == residentScope && $0.objectID == objectID }) else { throw WishMachineError.unauthorized }
        switch delegations[index].state {
        case .pending: break
        case .revoked: throw WishMachineError.placementRevoked
        case .awaitingSubmission, .placed, .failed: throw WishMachineError.unauthorized
        }
        guard jobs.contains(where: { $0.objectID == objectID && $0.worldID == worldID && $0.residentScope == residentScope && $0.stage == .claimed }) else { throw WishMachineError.unauthorized }
        guard delegations[index].allowedSurfaceIDs.contains(surfaceID) else { throw WishMachineError.conflictingCall }
        guard let target, target.isFinite, target.surfaceID == surfaceID else { throw WishMachineError.conflictingCall }
        if let explicit = delegations[index].explicitTarget {
            guard explicit.canonicalEquals(target) else { throw WishMachineError.conflictingCall }
        } else if delegations[index].boundTarget != target {
            delegations[index].boundTarget = target
            try persist()
        }
        return delegations[index]
    }

    /// Host records that no legal spot exists; the item stays safely in inventory and only a
    /// fresh human placement instruction may retry.
    func markPlacementFailed(worldID: String, residentScope: String, objectID: String, reason: String) throws {
        guard readable else { throw WishMachineError.unavailable }
        guard let index = delegations.firstIndex(where: { $0.worldID == worldID && $0.residentScope == residentScope && $0.objectID == objectID }) else { throw WishMachineError.unauthorized }
        guard delegations[index].state == .pending else { return }
        delegations[index].state = .failed
        delegations[index].lastError = reason
        try persist()
    }

    func submit(requestID: String, authorizationID: UUID, attachmentID: UUID, name: String,
                heightMeters: Double, sizeIntent: PropSizeIntent? = nil,
                worldID: String, residentScope: String,
                destination: WishPlacementDestination? = nil) async throws -> WishMachineJob {
        guard readable else { throw WishMachineError.unavailable }
        try Task.checkCancellation()
        guard let authorization = authorizations.first(where: { $0.id == authorizationID }),
              authorization.worldID == worldID, authorization.residentScope == residentScope else { throw WishMachineError.unauthorized }
        guard let image = authorization.attachments.first(where: { $0.id == attachmentID }) else { throw WishMachineError.unknownAttachment }
        if let existing = jobs.first(where: { $0.authorizationID == authorizationID }) {
            guard existing.requestID == requestID else { throw WishMachineError.consumedAuthorization }
            // 尺寸意图也要一致，但**老档案没有它**（升级前受理的任务）：
            // 只要有一侧没说过意图，就按"没有意图"放过这次重放，不把合法重放判成冲突。
            guard existing.attachmentID == attachmentID, existing.name == name,
                  existing.heightMeters == heightMeters,
                  existing.sizeIntent == sizeIntent || existing.sizeIntent == nil || sizeIntent == nil
            else { throw WishMachineError.conflictingCall }
            if let destination {
                guard let grant = delegations.first(where: { $0.authorizationID == authorizationID }),
                      grant.allowedSurfaceIDs == destination.surfaceIDs, grant.explicitTarget == destination.explicitTarget else { throw WishMachineError.conflictingCall }
            }
            return existing
        }
        if let destination {
            let surfaces = try Self.validatedSurfaceIDs(destination.surfaceIDs, explicitTarget: destination.explicitTarget)
            if let existingGrant = delegations.first(where: { $0.authorizationID == authorizationID }) {
                guard existingGrant.allowedSurfaceIDs == surfaces, existingGrant.explicitTarget == destination.explicitTarget else { throw WishMachineError.conflictingCall }
            } else {
                delegations.append(.init(id: UUID(), authorizationID: authorizationID,
                    requestID: "placement." + UUID().uuidString.lowercased(), worldID: worldID, residentScope: residentScope,
                    allowedSurfaceIDs: surfaces, explicitTarget: destination.explicitTarget, objectID: nil,
                    state: .awaitingSubmission, lastError: nil))
                try persist()
            }
        }
        guard !requestID.isEmpty, (1...100).contains(name.count), heightMeters.isFinite, (0.01...3).contains(heightMeters) else { throw PropGenerationError.invalidInput }
        // 尺寸意图**存在时必须合法**，而且与请求高度不矛盾：轴是高度时两者就是同一件事。
        // 非法/矛盾一律拒绝（`invalidInput` 的文案会说明范围），不静默按"没有意图"处理。
        if let sizeIntent {
            guard sizeIntent.isValid else { throw PropGenerationError.invalidInput }
            if sizeIntent.axis == .height, sizeIntent.meters != heightMeters { throw PropGenerationError.invalidInput }
        }
        let id = UUID()
        jobs.append(.init(id: id, worldID: worldID, residentScope: residentScope, authorizationID: authorizationID,
            attachmentID: attachmentID, requestID: requestID, name: name, heightMeters: heightMeters,
            sizeIntent: sizeIntent,
            objectID: "wish-prop-" + id.uuidString.lowercased(), jobID: id, stage: .submitting))
        emit(index: jobs.count - 1, kind: .stateChanged)
        try persist() // Owner, grant and stable core identity precede both core persistence and network submission.
        // This awaits only local image adaptation and the Rust daemon's durable queue ACK.
        // Remote submission, observation and download belong exclusively to that process.
        let generationSource = webReferences.first { $0.attachmentID == attachmentID }?.source ?? authorization.source
        let coreID = await store.create(imageURL: image.url, name: name, author: generationSource.author,
            license: generationSource.license, heightMeters: heightMeters, sizeIntent: sizeIntent, id: id,
            context: PropTaskContext(worldID: worldID, residentScope: residentScope))
        let index = try index(id: id, worldID: worldID, residentScope: residentScope)
        if coreID == nil {
            jobs[index].stage = .submissionUncertain
            jobs[index].lastError = store.errorMessage ?? "后台受理结果未确认，请按原任务编号核实。"
            emit(index: index, kind: .stateChanged)
        } else {
            reconcile(index: index)
            if jobs[index].cancelRequested == true { await store.cancel(id: id); reconcile(index: index) }
        }
        try persist()
        return jobs[index]
    }

    func read(id: UUID, worldID: String, residentScope: String) throws -> WishMachineJob {
        jobs[try index(id: id, worldID: worldID, residentScope: residentScope)]
    }

    /// Only durable, scope-matched scene failures may influence presentation selection.
    func outputRenderFailure(id: UUID, worldID: String, residentScope: String) -> WishMachineEvent? {
        guard readable else { return nil }
        return events.first { $0.wishID == id && $0.worldID == worldID && $0.residentScope == residentScope
            && $0.kind == .failed && $0.failureSource == "renderer" }
    }

    /// A local scene-loading failure preserves the valid downloaded task and its asset.
    func recordOutputRenderFailure(id: UUID, worldID: String, residentScope: String, message: String) throws {
        let job = jobs[try index(id: id, worldID: worldID, residentScope: residentScope)]
        guard job.stage == .ready, let path = job.modelPath, FileManager.default.fileExists(atPath: path) else {
            throw WishMachineError.notReady
        }
        guard !events.contains(where: { $0.wishID == id && $0.kind == .failed && $0.failureSource == "renderer" }) else { return }
        events.append(.init(id: UUID(), wishID: id, worldID: worldID, residentScope: residentScope,
            objectID: job.objectID, kind: .failed, computeMayContinue: job.computeMayContinue,
            stage: job.stage, remoteState: job.remoteState,
            message: "成品场景加载失败：" + message, cancelRequested: job.cancelRequested, failureSource: "renderer"))
        try persist()
    }

    func residentJobs(worldID: String, residentScope: String) -> [WishMachineJob] {
        readable ? jobs.filter { $0.worldID == worldID && $0.residentScope == residentScope } : []
    }

    func attachmentChoices(authorizationID: UUID, worldID: String, residentScope: String) -> [(id: UUID, displayName: String)] {
        guard readable, let authorization = authorizations.first(where: { $0.id == authorizationID && $0.worldID == worldID && $0.residentScope == residentScope }) else { return [] }
        return authorization.attachments.map { (id: $0.id, displayName: $0.displayName) }
    }

    func claimEvidence(id: UUID, worldID: String, residentScope: String) throws -> WishMachineClaimEvidence? {
        canClaim(try read(id: id, worldID: worldID, residentScope: residentScope))
    }

    /// Explicit confirmation only. A persisted core request is replayed with its original image and key.
    @discardableResult func retry(id: UUID, worldID: String, residentScope: String) async throws -> WishMachineJob {
        let index = try index(id: id, worldID: worldID, residentScope: residentScope)
        guard let coreID = jobs[index].jobID else { throw WishMachineError.retryUnavailable }
        // A reopened app may not have received its first subscription snapshot yet.
        // Resolve the durable daemon identity before choosing retry versus local submission.
        await store.refreshSnapshot()
        if let record = store.jobs.first(where: { $0.id == coreID }), record.receipt != nil,
           !(record.receipt?.state == .completed && record.localModelPath == nil) {
            reconcile(index: index)
            try persist()
            return jobs[index]
        }
        guard [.submissionUncertain, .submitting, .generated].contains(jobs[index].stage) else { throw WishMachineError.retryUnavailable }
        try Task.checkCancellation()
        if store.jobs.contains(where: { $0.id == coreID }) {
            await store.retrySubmission(id: coreID)
        } else {
            // Reuse the stable UUID even if the local ACK was lost; the daemon owns deduplication.
            let job = jobs[index]
            guard let authorization = authorizations.first(where: { $0.id == job.authorizationID && $0.worldID == worldID && $0.residentScope == residentScope }),
                  let image = authorization.attachments.first(where: { $0.id == job.attachmentID }) else { throw WishMachineError.unknownAttachment }
            let generationSource = webReferences.first { $0.attachmentID == job.attachmentID }?.source ?? authorization.source
            // 重放必须带上**原任务的**尺寸意图：换一次身份不等于换一个尺寸。
            _ = await store.create(imageURL: image.url, name: job.name, author: generationSource.author,
                license: generationSource.license, heightMeters: job.heightMeters, sizeIntent: job.sizeIntent, id: coreID,
                context: PropTaskContext(worldID: worldID, residentScope: residentScope))
        }
        reconcile(index: index)
        jobs[index].lastError = store.errorMessage
        try persist()
        return jobs[index]
    }

    @discardableResult func refresh(id: UUID, worldID: String, residentScope: String) async throws -> WishMachineJob {
        let index = try index(id: id, worldID: worldID, residentScope: residentScope)
        guard let coreID = jobs[index].jobID, jobs[index].stage != .claimed else { return jobs[index] }
        await store.refresh(id: coreID) // One local daemon snapshot; never a remote model poll.
        reconcile(index: index)
        try persist()
        return jobs[index]
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
    static let maximumNetworkConfirmationsPerJob = 3
    /// Two automatic confirmations of the same task are at least this far apart, so a
    /// still-broken remote endpoint cannot be hammered by the host's 5-second refresh.
    static let minimumNetworkConfirmationInterval: TimeInterval = 30

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

    private var networkConfirmationAttempts: [UUID: Int] = [:]
    private var lastNetworkConfirmationAt: [UUID: Date] = [:]

    @discardableResult
    func confirmNetworkUncertainSubmissions() async -> Int {
        guard readable, store.errorMessage == nil else { return 0 }
        let date = now()
        let pending = jobs.filter { job in
            guard job.stage == .submissionUncertain,
                  Self.isNetworkClassSubmissionError(job.lastError),
                  (networkConfirmationAttempts[job.id] ?? 0) < Self.maximumNetworkConfirmationsPerJob
            else { return false }
            guard let last = lastNetworkConfirmationAt[job.id] else { return true }
            return date.timeIntervalSince(last) >= Self.minimumNetworkConfirmationInterval
        }
        var confirmed = 0
        for job in pending {
            networkConfirmationAttempts[job.id, default: 0] += 1
            lastNetworkConfirmationAt[job.id] = date
            _ = try? await retry(id: job.id, worldID: job.worldID, residentScope: job.residentScope)
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            try? persist()
            if jobs[index].stage != .submissionUncertain || jobs[index].lastError != job.lastError { confirmed += 1 }
        }
        return confirmed
    }

    func refreshPending(limit: Int = 2) async {
        guard readable, limit > 0 else { return }
        await store.refreshSnapshot()
        synchronizeBackendSnapshot()
        // 暂停的重新校验**不依赖后端**：它纯本地、幂等，唯一的判据是"有没有用户意图证据"。
        // 后端没配好时，遗留的非用户暂停同样必须自愈，而不是继续要求人工解除——那正是
        // 用户抱怨的多余一步。run 级用户停止与"奉命轮"规则仍然各自把住每一次自主领取。
        discardPausesWithoutUserIntent()
        // 网络类未知提交的自动确认必须等后端真的可达：它要复用原幂等身份去确认/重发，
        // 门槛之外只会制造无效请求。所以健康判定只留给这一条。
        let healthy = store.errorMessage == nil
        guard healthy else { return }
        await confirmNetworkUncertainSubmissions()
    }

    @discardableResult func cancel(id: UUID, worldID: String, residentScope: String) async throws -> WishMachineJob {
        let index = try index(id: id, worldID: worldID, residentScope: residentScope)
        guard let coreID = jobs[index].jobID else { throw WishMachineError.notReady }
        if [.claimed, .cancelled, .failed, .interrupted, .ready, .generated].contains(jobs[index].stage) { return jobs[index] }
        jobs[index].cancelRequested = true
        jobs[index].computeMayContinue = true
        emit(index: index, kind: .stateChanged)
        try persist()
        await store.cancel(id: coreID)
        reconcile(index: index)
        try persist()
        return jobs[index]
    }

    func claim(id: UUID, worldID: String, residentScope: String) throws -> WishMachineJob {
        let index = try index(id: id, worldID: worldID, residentScope: residentScope)
        let job = jobs[index]
        if job.stage == .claimed { return job }
        guard job.stage == .ready, let path = job.modelPath, FileManager.default.fileExists(atPath: path) else { throw WishMachineError.notReady }
        guard let evidence = canClaim(job), evidence.worldID == worldID, evidence.activityID == "wish_machine.collect",
              evidence.phase == "loop", evidence.distanceMeters.isFinite, (0...0.25).contains(evidence.distanceMeters),
              evidence.outputAvailable else { throw WishMachineError.notAtMachine }
        jobs[index].stage = .claimed
        emit(index: index, kind: .claimed)
        try persist()
        return jobs[index]
    }

    func readyOutputs(worldID: String) -> [WishMachineOutputDescriptor] {
        guard readable else { return [] }
        return jobs.compactMap { job in
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
        return events.filter { !$0.acknowledged && $0.worldID == worldID && $0.residentScope == residentScope }
    }

    /// Local fact outbox only. Rust owns delivery and separate world/UI/agent acknowledgements.
    /// Previously acknowledged legacy events must not be broadcast again during migration.
    func unpublishedEvents(worldID: String, residentScope: String) -> [WishMachineEvent] {
        guard readable else { return [] }
        return events.filter {
            !$0.acknowledged && $0.forwardedToDaemon != true && $0.worldID == worldID && $0.residentScope == residentScope
        }
    }

    /// Call only after publish_message returned its durable acknowledgement for this same event ID.
    func markEventPublished(id: UUID) throws {
        guard readable else { throw WishMachineError.unavailable }
        guard let index = events.firstIndex(where: { $0.id == id }), events[index].forwardedToDaemon != true else { return }
        events[index].forwardedToDaemon = true
        try persist()
    }

    func automaticContinuationEvents(worldID: String, residentScope: String) -> [WishMachineEvent] {
        pendingEvents(worldID: worldID, residentScope: residentScope).filter { event in
            guard let job = jobs.first(where: { $0.id == event.wishID }) else { return false }
            if let grant = event.continuationResumeAuthorizationID,
               job.continuationResumeAuthorizationIDs?.last != grant { return false }
            return job.autoContinuationPaused != true
        }
    }

    /// A current human turn may renew only this wish's original follow-through.
    /// The host supplies claimed-item readback; provider state and world effects are untouched.
    @discardableResult
    func resumeContinuations(id: UUID, worldID: String, residentScope: String, authorizationID: UUID,
                             placementAlreadyCompleted: Bool? = nil) throws -> WishMachineJob {
        let index = try index(id: id, worldID: worldID, residentScope: residentScope)
        let job = jobs[index]
        guard job.cancelRequested != true,
              ![.failed, .cancelled, .interrupted].contains(job.stage),
              job.remoteState.map({ ![.failed, .cancelled, .interrupted, .cancelRequested].contains($0) }) ?? true,
              outputRenderFailure(id: id, worldID: worldID, residentScope: residentScope) == nil else {
            throw WishMachineError.continuationResumeUnavailable
        }
        let delegationIndex = delegations.firstIndex {
            $0.authorizationID == job.authorizationID && $0.worldID == worldID && $0.residentScope == residentScope
        }
        if let delegationIndex {
            guard delegations[delegationIndex].state != .placed else { throw WishMachineError.continuationAlreadyPlaced }
            guard delegations[delegationIndex].state != .failed else { throw WishMachineError.continuationResumeUnavailable }
        }
        if job.stage == .claimed {
            guard let placementAlreadyCompleted else { throw WishMachineError.continuationResumeReadbackRequired }
            guard !placementAlreadyCompleted else { throw WishMachineError.continuationAlreadyPlaced }
            guard delegationIndex != nil else { throw WishMachineError.continuationResumeUnavailable }
        }
        let needsResume = job.autoContinuationPaused == true || delegationIndex.map { delegations[$0].state == .revoked } == true
        guard needsResume else { return job }
        guard !(job.continuationResumeAuthorizationIDs ?? []).contains(authorizationID) else {
            throw WishMachineError.continuationResumeUnauthorized
        }
        let priorDelegations = delegations, priorEvents = events
        jobs[index].autoContinuationPaused = false
        jobs[index].autoContinuationStoppedByUser = nil
        jobs[index].continuationResumeAuthorizationIDs = (job.continuationResumeAuthorizationIDs ?? []) + [authorizationID]
        if let delegationIndex, delegations[delegationIndex].state == .revoked {
            delegations[delegationIndex].state = delegations[delegationIndex].objectID == nil ? .awaitingSubmission : .pending
        }
        events.append(.init(id: UUID(), wishID: id, worldID: worldID, residentScope: residentScope,
            objectID: job.objectID, kind: .stateChanged, computeMayContinue: job.computeMayContinue,
            stage: job.stage, remoteState: job.remoteState, message: "原许愿任务的自动续办权限已恢复。",
            cancelRequested: job.cancelRequested, autoContinuationPaused: false, continuationResumeAuthorizationID: authorizationID))
        do { try persist() }
        catch {
            // A failed durable grant must remain paused even to direct in-process readers.
            jobs[index] = job; delegations = priorDelegations; events = priorEvents
            throw error
        }
        return jobs[index]
    }

    /// Stop automatic follow-through for existing commissions only. Keep their facts and assets intact.
    ///
    /// Host contract: call this **only** for an explicit user stop (the interface's stop
    /// control). Everything else — a network/submission failure, a backend becoming
    /// unavailable, a world switch, an app quit — must not write this pause, because the
    /// only way back is a human action and the user never asked for one. The pause records
    /// its own user-intent provenance so a pause written by an older build (or by any other
    /// path) can be re-validated and lifted by `discardPausesWithoutUserIntent()`.
    func pauseContinuations(worldID: String, residentScope: String) throws {
        let indices = jobs.indices.filter { jobs[$0].worldID == worldID && jobs[$0].residentScope == residentScope }
        let delegationIndices = delegations.indices.filter { delegations[$0].worldID == worldID && delegations[$0].residentScope == residentScope && delegations[$0].state == .pending }
        guard !indices.isEmpty || !delegationIndices.isEmpty else { return }
        // Block in this process before touching disk; a failed save must not resume actions in memory.
        for index in indices {
            jobs[index].autoContinuationPaused = true
            jobs[index].autoContinuationStoppedByUser = true
        }
        // Stop revokes incomplete placement delegations in the same durable record.
        for index in delegationIndices { delegations[index].state = .revoked }
        do { try persist() }
        catch {
            errorMessage = WishMachineError.pauseNotPersisted.localizedDescription
            throw WishMachineError.pauseNotPersisted
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
    func discardPausesWithoutUserIntent() -> Int {
        guard readable else { return 0 }
        let indices = jobs.indices.filter {
            jobs[$0].autoContinuationPaused == true && jobs[$0].autoContinuationStoppedByUser != true
        }
        guard !indices.isEmpty else { return 0 }
        let priorJobs = jobs, priorEvents = events, priorDelegations = delegations
        for index in indices {
            jobs[index].autoContinuationPaused = false
            jobs[index].autoContinuationStoppedByUser = nil
            events.append(.init(id: UUID(), wishID: jobs[index].id, worldID: jobs[index].worldID,
                residentScope: jobs[index].residentScope, objectID: jobs[index].objectID, kind: .stateChanged,
                computeMayContinue: jobs[index].computeMayContinue, stage: jobs[index].stage,
                remoteState: jobs[index].remoteState,
                message: "自动续办已恢复：此前的停止不是一次人工操作，不需要手动解除。",
                cancelRequested: jobs[index].cancelRequested, autoContinuationPaused: false))
        }
        // A placement revoked by that same non-user pause is reopened with it. Delegations
        // revoked explicitly (`revokePlacementDelegations`) belong to tasks that are not
        // released here, so they stay revoked.
        for index in delegations.indices where delegations[index].state == .revoked
            && indices.contains(where: {
                jobs[$0].authorizationID == delegations[index].authorizationID
                    && jobs[$0].worldID == delegations[index].worldID
                    && jobs[$0].residentScope == delegations[index].residentScope
            }) {
            delegations[index].state = delegations[index].objectID == nil ? .awaitingSubmission : .pending
        }
        do { try persist() }
        catch {
            jobs = priorJobs; events = priorEvents; delegations = priorDelegations
            return 0
        }
        return indices.count
    }
    /// Stop revokes incomplete delegations durably; revocation never revives on restart or world switch.
    func revokePlacementDelegations(worldID: String, residentScope: String) throws {
        var changed = false
        for index in delegations.indices where delegations[index].worldID == worldID && delegations[index].residentScope == residentScope
            && delegations[index].state == .pending {
            delegations[index].state = .revoked; changed = true
        }
        guard changed else { return }
        try persist()
    }
    func acknowledgeEvent(id: UUID) throws {
        guard readable else { throw WishMachineError.unavailable }
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].acknowledged = true
        try persist()
    }

    /// Durable backend subscription updates drive the same world/UI/agent facts as a manual read.
    private func synchronizeBackendSnapshot() {
        guard readable else { return }
        let previousJobs = jobs, previousEvents = events
        for index in jobs.indices { reconcile(index: index) }
        guard jobs != previousJobs || events != previousEvents else { return }
        do { try persist() } catch { errorMessage = error.localizedDescription }
    }

    private func reconcile(index: Int) {
        guard jobs[index].stage != .claimed,
              let record = store.jobs.first(where: { $0.id == jobs[index].jobID }) else { return }
        jobs[index].daemonAccepted = true
        jobs[index].lastError = record.lastError
        if record.cancelRequested == true { jobs[index].cancelRequested = true }
        jobs[index].remoteState = record.receipt?.state
        jobs[index].computeMayContinue = record.receipt?.computeMayContinue
            ?? (jobs[index].cancelRequested == true && record.backendStage != "cancelled")
        switch record.backendStage {
        case "cancelled":
            jobs[index].stage = .cancelled
            emit(index: index, kind: .cancelled)
            return
        case "interrupted":
            jobs[index].stage = .interrupted
            emit(index: index, kind: .interrupted)
            return
        case "failed" where record.receipt?.state != .completed:
            jobs[index].stage = .failed
            emit(index: index, kind: .failed)
            return
        case let stage? where ["queued", "submitting", "awaiting_configuration", "cancel_requested"].contains(stage) && record.receipt == nil:
            jobs[index].stage = .submitting
            if record.backendStage == "awaiting_configuration", jobs[index].lastError == nil {
                jobs[index].lastError = "后台等待服务配置。"
            }
            emit(index: index, kind: .stateChanged)
            return
        default: break
        }
        guard let receipt = record.receipt else {
            jobs[index].stage = .submissionUncertain
            emit(index: index, kind: .stateChanged)
            return
        }
        bindPlacementIfAccepted(index: index)
        switch receipt.state {
        case .completed:
            if ![.ready, .claimed].contains(jobs[index].stage) { jobs[index].stage = .generated }
            emit(index: index, kind: .generationCompleted)
            if record.backendStage == "ready", let path = record.localModelPath,
               FileManager.default.fileExists(atPath: path) {
                jobs[index].modelPath = path
                jobs[index].stage = .ready
                jobs[index].lastError = nil
                emit(index: index, kind: .outputReady)
            }
        case .failed: jobs[index].stage = .failed; emit(index: index, kind: .failed)
        case .cancelled: jobs[index].stage = .cancelled; emit(index: index, kind: .cancelled)
        case .interrupted: jobs[index].stage = .interrupted; emit(index: index, kind: .interrupted)
        default: jobs[index].stage = .generating
        }
        emit(index: index, kind: .stateChanged)
    }
    /// Object identity binds to a destination grant only after the remote submission is accepted.
    private func bindPlacementIfAccepted(index: Int) {
        for delegationIndex in delegations.indices where delegations[delegationIndex].authorizationID == jobs[index].authorizationID
            && delegations[delegationIndex].objectID == nil {
            guard delegations[delegationIndex].worldID == jobs[index].worldID,
                  delegations[delegationIndex].residentScope == jobs[index].residentScope else { continue }
            delegations[delegationIndex].objectID = jobs[index].objectID
            if jobs[index].autoContinuationPaused == true || delegations[delegationIndex].state == .revoked {
                delegations[delegationIndex].state = .revoked
            } else { delegations[delegationIndex].state = .pending }
        }
    }
    private func emit(index: Int, kind: WishMachineEvent.Kind) {
        let job = jobs[index]
        guard !events.contains(where: { event in
            guard event.wishID == job.id && event.kind == kind && event.failureSource == nil else { return false }
            if kind != .stateChanged { return true }
            return event.stage == job.stage && event.remoteState == job.remoteState
                && event.message == job.lastError && event.cancelRequested == job.cancelRequested
        }) else { return }
        events.append(.init(id: UUID(), wishID: job.id, worldID: job.worldID, residentScope: job.residentScope,
            objectID: job.objectID, kind: kind, computeMayContinue: job.computeMayContinue,
            stage: job.stage, remoteState: job.remoteState, message: job.lastError, cancelRequested: job.cancelRequested))
    }
    private func index(id: UUID, worldID: String, residentScope: String) throws -> Int {
        guard readable else { throw WishMachineError.unavailable }
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].worldID == worldID,
              jobs[index].residentScope == residentScope else { throw WishMachineError.wrongScope }
        return index
    }
    private func persist() throws {
        guard readable else { throw WishMachineError.unavailable }
        let temporary = directory.appendingPathComponent(".wishes-" + UUID().uuidString + ".tmp")
        defer { try? archiveFileManager.removeItem(at: temporary) }
        do {
            try archiveFileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("wishes.json")
            try JSONEncoder().encode(Archive(authorizations: authorizations, jobs: jobs, events: events,
                imageRegistrations: imageRegistrations, delegations: delegations, webReferences: webReferences))
                .write(to: temporary, options: .withoutOverwriting)
            try archiveFileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            // Preparation may fail without changing the old archive. Rename is the sole
            // commit point; nothing that can report a failure follows a successful replace.
            guard Darwin.rename(temporary.path, file.path) == 0 else { throw WishMachineError.unavailable }
            onChange?()
        } catch { readable = false; errorMessage = WishMachineError.unavailable.localizedDescription; throw WishMachineError.unavailable }
    }
    private static func validatedSurfaceIDs(_ surfaceIDs: [String], explicitTarget: WishPlacementTarget?) throws -> [String] {
        guard !surfaceIDs.isEmpty, surfaceIDs.count <= 8,
              surfaceIDs.allSatisfy({ !$0.isEmpty && $0.count <= 256 }), Set(surfaceIDs).count == surfaceIDs.count else { throw PropGenerationError.invalidInput }
        if let target = explicitTarget {
            guard surfaceIDs.contains(target.surfaceID), target.isFinite else { throw PropGenerationError.invalidInput }
        }
        return surfaceIDs
    }

    /// Only public HTTPS on the standard port; credentials, other schemes and
    /// alternate ports are rejected before any download is attempted.
    private static func isPublicReferenceURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return url.port == nil || url.port == 443
    }
}
