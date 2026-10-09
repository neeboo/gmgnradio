//
//  verify-product-settings-conflict-retry-support.swift
//  GMGNRadio
//
//  `RustProductSettingsClient.mutate` 的 **revision 冲突恢复** 离线行为验证。
//
//  真实执行链：真源码 `Sources/GMGNRadio/Presence/RustProductSettingsClient.swift`
//  → 内存假权威（只实现 `product_settings_read` / `product_settings_apply` 两个方法，
//  按真实权威的语义做 `expectedRevision` 乐观并发控制）。
//
//  无网络、无 taskd、无 Keychain、无 UI、无 AppleScript、无 xcodebuild test。
//
//  三个场景（任一不成立即 exit 1）：
//   1. 提交前另一个写者抢先 → 冲突一次 → 客户端 `reload()` 后用新 revision 重放
//      一次成功（这是本次修法）。
//   2. 每次都冲突 → 只重放一次，第二次的冲突**如实抛出**（不吞、不循环）。
//   3. 无冲突 → 只提交一次，不产生多余 `read`。
//
import Foundation

// MARK: - 被编译文件需要的宿主符号（最小替身）

enum WorldAuthorityError: Error, Equatable {
    case unavailable(String)
    case daemon(String)
    case invalidResponse
}

enum E2ERuntime {
    static let applicationSupportBase = URL(fileURLWithPath: NSTemporaryDirectory())
}

enum WorldAuthorityEndpoint {
    static func taskServiceRoot(applicationSupportBase: URL) -> URL { applicationSupportBase }
}

final class TaskdHTTPAuthorityClient: @unchecked Sendable {
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool = true, timeout: TimeInterval = 5) {}
    func call(method: String, params: [String: Any]) throws -> [String: Any] { [:] }
}

// MARK: - 假权威

final class FakeAuthority: @unchecked Sendable {
    enum Conflict {
        case never
        case once
        case always
    }

    private let lock = NSLock()
    private var revision: Int64 = 1
    private var reads = 0
    private var applies = 0
    private var conflict: Conflict = .never

    /// 只切换冲突模式；**不动计数器**——调用方在 `ensureLoaded()` 之后 arm，
    /// 于是之后的 read/apply 次数就是这次提交真实产生的往返。
    func arm(_ conflict: Conflict) {
        lock.lock(); defer { lock.unlock() }
        self.conflict = conflict
    }

    func counters() -> (reads: Int, applies: Int) {
        lock.lock(); defer { lock.unlock() }
        return (reads, applies)
    }

    func call(_ method: String, _ data: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let params = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch method {
        case "product_settings_read":
            reads += 1
            return try snapshot()
        case "product_settings_apply":
            applies += 1
            let expected = (params["expectedRevision"] as? NSNumber)?.int64Value
            let conflictNow: Bool
            switch conflict {
            case .never: conflictNow = false
            case .once: conflictNow = true; conflict = .never
            case .always: conflictNow = true
            }
            if conflictNow {
                // 另一个写者（另一个窗口 / Unity 宿主）先提交了：权威的 revision 前进，
                // 我们手里的 expectedRevision 就此过期。
                revision += 1
                throw WorldAuthorityError.daemon("product_settings_revision_conflict")
            }
            guard expected == revision else {
                throw WorldAuthorityError.daemon("product_settings_revision_conflict")
            }
            revision += 1
            return try snapshot()
        default:
            throw WorldAuthorityError.daemon("unexpected_method")
        }
    }

    private func snapshot() throws -> Data {
        let values = RustProductSettingsClient.Values(
            locale: "zh-Hans", residentPersona: "fixture", backgroundTurnsPerHour: 6,
            autoSpeak: true, autonomyEnabled: true, agentBackend: "dsh",
            selectedWorldID: nil, defaultSpace: "default", djHostPrompt: "", djTakeover: false,
            djPlanningModel: nil, ttsProvider: "bailian", ttsModel: "m", ttsVoice: "v",
            asrProvider: "bailian", asrModel: "am", microphoneDeviceID: nil,
            orbRed: 0, orbGreen: 0, orbBlue: 0, orbFlowIntensity: 0,
            remoteMotionCatalogURL: "", shortcutAssignments: [],
            globalShortcutsEnabled: false, mediaKeysEnabled: false, musicConnectedProviders: [],
            avatarPositions: [:], stagePointCloudChoice: "", stageParticleSizeMultiplier: 1,
            stageLegacyImported: false, stageLyricsMode: "luminous",
            stageLyricsResolvedMode: "luminous", stageLyricsTrackID: nil,
            stageLyricsLegacyImported: false)
        return try JSONEncoder().encode(
            RustProductSettingsClient.Snapshot(revision: revision, values: values, imported: true))
    }
}

// MARK: - 场景

@main
@MainActor
struct VerifyProductSettingsConflictRetry {
    static func main() async {
        var failures: [String] = []

        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "ok  " : "FAIL") \(label)")
            if !condition { failures.append(label) }
        }

        // 1) 冲突一次 → 重读 + 重放一次 → 成功。
        let recover = FakeAuthority()
        let recovering = RustProductSettingsClient(call: { try recover.call($0, $1) })
        try? await recovering.ensureLoaded()
        recover.arm(.once)
        let recovered = try? await recovering.apply(["autoSpeak": false])
        check(recovered?.revision == 3, "冲突一次后重放成功（revision 1→2 被抢，重读后 2→3）")
        check(recovered != nil, "冲突一次不再把用户的改动丢掉")
        check(recovering.confirmed?.revision == 3, "confirmed 落在权威的最新 revision 上")
        check(recover.counters().applies == 2, "只重放一次（apply 共 2 次）")
        check(recover.counters().reads == 2, "冲突后确实重读了一次（read 共 2 次：ensureLoaded + reload）")

        // 2) 每次都冲突 → 只重放一次，第二次冲突如实抛出。
        let stubborn = FakeAuthority()
        let failing = RustProductSettingsClient(call: { try stubborn.call($0, $1) })
        try? await failing.ensureLoaded()
        stubborn.arm(.always)
        var thrown: Error?
        do { _ = try await failing.apply(["autoSpeak": false]) } catch { thrown = error }
        check(thrown != nil, "第二次仍冲突时如实报错（不吞错）")
        check(
            (thrown as? WorldAuthorityError) == .daemon("product_settings_revision_conflict"),
            "抛出的是原样的 product_settings_revision_conflict")
        check(stubborn.counters().applies == 2, "绝不循环重试（apply 恰好 2 次）")

        // 3) 无冲突 → 不做多余的重读。
        let clean = FakeAuthority()
        let plain = RustProductSettingsClient(call: { try clean.call($0, $1) })
        try? await plain.ensureLoaded()
        clean.arm(.never)
        let ok = try? await plain.apply(["autoSpeak": false])
        check(ok?.revision == 2, "无冲突时一次提交成功")
        check(clean.counters().applies == 1 && clean.counters().reads == 1, "无冲突不产生多余往返")

        if failures.isEmpty {
            print("PRODUCT SETTINGS CONFLICT RETRY: ALL SCENARIOS PASS")
        } else {
            print("PRODUCT SETTINGS CONFLICT RETRY: \(failures.count) FAILED")
            for failure in failures { print("  - \(failure)") }
            exit(1)
        }
    }
}
