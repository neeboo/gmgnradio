import Foundation
import simd
import WorldRuntime

/// 物件挂在角色的**哪个挂点**上：右手（既有）、背后、腰间。
///
/// **候选骨名、默认偏移、默认朝向、净空判据全部在 `PropAttachmentSlot.swift` 的挂点表里**
/// （`PropAttachmentSlots`，含真机静止坐标的证据）。这里只有"有哪几个挂点"这一件事 ——
/// 于是挂点定义只有一处，而这一份离渲染最近的文件只留一个类型。
enum PropAttachmentPoint: String, CaseIterable, Equatable, Sendable {
    case rightHand
    case back
    case waist
}

struct ResidentHeldPropDescriptor: Equatable, Sendable {
    let objectID: String
    let worldID: String
    let assetID: String
    let modelURL: URL
    let targetHeightMeters: Float
    let attachmentPoint: PropAttachmentPoint
    let calibration: WorldPropGripCalibration
    /// **资产级**摆正旋转（`WorldGeneratedProp.orientationRotation`）。
    ///
    /// 手里的这一件与地上那一件是同一份网格：躺着生成的东西必须两处都转正，
    /// 否则会出现"放在地上立着、拿在手里躺着"。缺省 = 单位四元数 ⇒ 与改造前逐字节相同。
    var orientation: WorldQuaternion = .identity
    /// 世界里那一份**逐轴**目标尺寸（米）= `WorldGeneratedProp.effectiveSize`。
    ///
    /// `nil`（缺省）= 只有高度轴（等比，与改造前逐位相同）；非 nil 且不是这份网格的等比像
    /// ⇒ 手里这一件也**逐轴**缩放 —— 与地上那一件、碰撞盒、承托判据读的是同一组数字，
    /// 所以"放在地上是三轴、拿在手里变回等比"这种分叉在结构上不可能。
    var targetSizeMeters: WorldVector3? = nil

    var assetKey: String {
        assetID + "|" + modelURL.standardizedFileURL.path
    }
}

enum PropAttachmentError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedAvatar
    case avatarMismatch
    case missingBone(PropAttachmentPoint)
    case invalidHandPose
    case assetNotPrepared
    /// 空间这一刻不可见（世界没推上台、舞台窗口被收起/最小化）。
    ///
    /// 为什么要把这四种从 `.assetNotPrepared` / `.unsupportedAvatar` 里**分出来**：
    /// 真机 2026-10-02 的"剑挂不到背后"里，这一层的八条判据原来塌成同一句话
    /// （"物件还没有准备好" / "当前角色还不能拿起物件"），而角色明明是受支持的 2B、
    /// 资产明明已经备好 —— 用户在屏幕上看不出是哪一条，统一日志里也一条都没有。
    /// **每一次拒绝都必须能指名道姓**（哪条判据、看着哪个世界/资产），否则"挂不上"
    /// 就永远只能靠猜。
    case worldNotVisible(worldID: String?)
    case rendererNotActive(worldID: String?)
    case assetNotRenderable(assetID: String)
    case validationHandlerUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedAvatar:
            "当前角色还不能拿起物件。首版仅支持已适配的 2B 角色。"
        case .avatarMismatch:
            "拿取记录属于另一个角色，请先把物件放回。"
        case .missingBone(let point):
            // 找不到**这个挂点**的骨头必须是可见失败（绝不是"没拿着"），而且要说清是哪个挂点、
            // 找过哪些骨名 —— 换模型之后骨名对不上时，这句话就是唯一能直接读的线索。
            switch point {
            case .rightHand:
                "当前 2B 模型缺少右手骨骼，暂时无法拿起物件。（找过：\(Self.candidatesText(point))）"
            case .back:
                "这个角色没有可用的背后骨骼，暂时无法把物件挂到背后。（找过：\(Self.candidatesText(point))）"
            case .waist:
                "这个角色没有可用的腰部骨骼，暂时无法把物件挂到腰间。（找过：\(Self.candidatesText(point))）"
            }
        case .invalidHandPose:
            "当前挂点姿势无效，暂时无法显示物件。"
        case .assetNotPrepared:
            "物件还没有准备好，暂时无法拿起。"
        case .worldNotVisible(let worldID):
            "这个空间现在不在舞台上（世界 \(worldID ?? "未知") 没有在显示），暂时挂不上东西。请把空间窗口切到前台再试。"
        case .rendererNotActive(let worldID):
            "这个空间的显示还没接管（世界 \(worldID ?? "未知") 的渲染器这一刻不活动），暂时挂不上东西。请等空间画面出现后重试。"
        case .assetNotRenderable(let assetID):
            "这件物件的模型这一刻没有在渲染器里备好（资产 \(assetID)），暂时挂不上。请等它显示出来再试。"
        case .validationHandlerUnavailable:
            "空间显示还没有把挂点检查接上（渲染器尚未接管），暂时挂不上东西。请等空间画面出现后重试。"
        }
    }

    /// 失败文案里那串"找过哪些骨名"。只有一个出处：挂点表那张候选骨名表。
    static func candidatesText(_ point: PropAttachmentPoint) -> String {
        PropAttachmentSlots.candidatesText(for: point)
    }
}

enum ResidentPropAttachmentEligibility {
    static let supportedAvatarID = "pmx.2b-miss-0414-standard"

    /// 能拿在手里的最长边（米）≈ 身高 / 臂展。判据、拒绝文案、系统提示词、面板注释全部读它。
    /// 1.6 m 依据：2B 身高约 1.68 m；真机那把「2B 白色长剑」最长边 1.1 m 必须拿得起来。
    ///
    /// **这是这个上限在仓库里唯一一处定义。** 放在这里而不是 `WorldPropSizePolicy`：
    /// 那个包被 harness 以 SwiftPM 产物链接，`make build` 不刷新它，新符号在 harness 里看不见。
    static let holdableLongestEdgeMeters: Float = 1.6

    /// 同一份上限的**人话**版本。拒绝文案与系统提示词都插值它 ——
    /// 于是不可能出现"判据是一个数、嘴上说的是另一个数"这种两种真相。
    static var holdableLongestEdgeText: String { String(format: "%.1f 米", holdableLongestEdgeMeters) }

    static func rejectionReason(for avatar: StageAvatarAsset?) -> String? {
        guard let avatar else {
            return "请先选择支持拿取物件的角色。"
        }
        guard avatar.format == .pmx else {
            return "当前仅支持 PMX 角色拿取物件。"
        }
        guard avatar.id == supportedAvatarID else {
            return "首版仅支持已适配的 2B 角色拿取物件。"
        }
        return nil
    }

    static func isEligible(_ avatar: StageAvatarAsset?) -> Bool {
        rejectionReason(for: avatar) == nil
    }

    /// 握点的**唯一**来源：`PropGripInference`。这里只负责把"当前居民"补上。
    ///
    /// 改造前这里是硬编码的 `(0.5, 0.2, 0.5)` / 单位旋转 —— 对细长物件（真机那把白色长剑，
    /// 原始 AABB 1.005 × 0.133 × 0.057 m）等于**握在剑身正中间**，屏幕上一眼能看出那不是
    /// "用手拿"而是"穿在手上"。现在由网格主轴推断（`PropGripInference.suggestion(for:)`）；
    /// 物件不细长时它交回来的就是**同一组数字**，既有物件的手感逐字节不变。
    /// 缺省挂点是**右手**：既有调用点一行都不用改，手那条路也逐字节不变。
    /// 背后/腰间的默认偏移与朝向由 `PropAttachmentSlots` 的挂点表给出（**不套用手那套默认值**）。
    static func suggestedCalibration(
        for prop: WorldGeneratedProp,
        avatar: StageAvatarAsset?,
        point: PropAttachmentPoint = .rightHand
    ) -> WorldPropGripCalibration? {
        guard prop.isValid, isEligible(avatar), let avatar else { return nil }
        return PropAttachmentSlots.calibration(avatarAssetID: avatar.id, prop: prop, point: point)
    }

    /// 握点那句给用户看的话的**唯一**出口（就是 `PropGripSuggestion.notice`）。
    ///
    /// 为什么必须有这个方法：`PropGripInference` 算出了 notice，而握点标定那条路
    /// （`suggestedCalibration`）只要三个字段 —— notice 在那里被丢掉，于是
    /// "推断不出 grip ⇒ 有可见说明"在生产路径上本来**不成立**。入库那一处
    /// （`synchronizeOwnedResidentProps`）用这个方法把它接回**既有**的可见通道。
    static func suggestedGripNotice(for prop: WorldGeneratedProp) -> String? {
        PropGripInference.suggestion(for: prop).notice
    }
}

/// 一次**已经发生过**的字节校验的收据：准备路径当时量到的字节数与 sha256。
///
/// 为什么要留这张收据，而不是在挂载那一刻重新读文件算哈希：
/// - 「资产未验证」的具名原因要说清**期望值 vs 实际值**，而期望值就是这次校验量到的那两个数；
/// - 挂点可用性是**每帧级**的查询（面板快照对每件物件 × 三个挂点各问一次），
///   在热路径上重读 2 MB 文件算哈希是不可接受的代价。
///
/// 它就是"这条资产曾经通过过文件 + 哈希两条腿"的证据，不是第二份真相：
/// 值全部来自准备路径（`residentOwnedPropAssets[...] = ...` 那一处）实际校验过的那一份。
struct ResidentPropAssetByteReceipt: Equatable, Sendable {
    let modelURL: String
    let bytes: Int
    /// 小写十六进制，不带 `sha256:` 前缀（与 `WorldGeneratedProp.assetID` 的后半段同一份写法）。
    let sha256: String
}

/// 「资产未验证」到底是**哪一步**没过 —— 五条腿各自回答"过没过、期望什么、实际什么"。
///
/// 为什么必须有它：真机 2026-10-02 12:28:21 用户让居民"把 2B 白色长剑挂到背后"，
/// 统一日志里那两行只说：
///
///     挂点拒绝 step=asset-unverified 挂点=右手 物件=wish-prop-4210db95-…
///     挂件拒绝 step=grip-calibration … 原因=物件尚未完成本地显示检查，所有权已保留，请稍后重试。
///
/// 最后那句说的是**后果**（"还没检查完"），不是原因。真机上这把剑的资产其实样样都在
/// （文件 1,722,692 字节、sha256 与存档 `assetID` 逐位相同、身份逐字段相同）；
/// 那一刻不成立的是**本地资产记录还没有这一条**（那一进程的资产准备还没轮到它）。
/// 五件事的修法完全不同，却共用同一句话 —— 于是排障只能猜。
///
/// 判据一个字都没放宽：这一份只是把**既有那几条 guard** 的结论按腿具名。
/// 唯一"新增"的判定是"记录声明的身份 vs 记录声明的字节"之间的一致性
/// （文件在不在 / 普通文件 / 字节数 / 哈希），它们全部 fail-closed 且每次拒绝都带期望与实际。
struct ResidentPropAssetVerification: Equatable, Sendable {
    /// 判据的五条腿。名字进统一日志（`腿=`）、进工具回执、进面板那行 —— 同一份字面量。
    enum Leg: String, CaseIterable, Sendable {
        /// `residentOwnedPropAssets` 里有没有这条记录（本地资产准备有没有轮到它）。
        case record = "asset-record"
        /// 记录里那份身份与世界状态里那份身份是否逐字段相同（`matchesIdentity`）。
        case identity = "asset-identity"
        /// 记录指的那份文件此刻在不在、是不是普通文件、字节数对不对。
        case file = "asset-file"
        /// 字节 sha256 与记录/存档声明的 `assetID` 是否一致。
        case hash = "asset-hash"
        /// 渲染器有没有把这份资产备好（`isResidentPropPrepared`）。
        case prepare = "asset-prepare"

        /// 这条腿不成立时**该做什么**。与判据同源（同一份 switch）：拒绝文案不会与判据分叉。
        var remedy: String {
            switch self {
            case .record:
                "这不是「物件坏了」：这一进程还没为它跑完一次资产准备（既有的 5 秒周期），"
                    + "等它在房间里显示出来再试一次即可。"
            case .identity:
                "存档里那份身份与本地准备的这一份不是同一件东西：已保留原记录，没有改动它。"
            case .file:
                "记录指的那份模型文件此刻不在 / 不是普通文件 / 字节数不对：没有删除也没有重新生成，请检查许愿任务与本地资产目录。"
            case .hash:
                "文件字节与记录声明的 assetID 不一致：已停用这份资产，绝不按「旧的画法」将就。"
            case .prepare:
                "记录与文件都已经通过，只是渲染器这一刻还没备好这份资产（还没轮到它这一帧）："
                    + "等空间画面把它显示出来再试一次。"
            }
        }
    }

    /// 一条不成立的腿：`field` / `expected` / `actual` 三个字段就是日志与回执里那三个字段。
    struct Failure: Equatable, Sendable {
        let leg: Leg
        let field: String
        let expected: String
        let actual: String
        /// 同一时刻**另外四条腿**各自看到了什么（拒绝时一起给人看，免得只看一条腿就下结论）。
        let examination: String

        var summary: String {
            "\(leg.rawValue) field=\(field) expected=\(expected) actual=\(actual) examination=[\(examination)]"
        }

        /// 用户/agent/面板读到的那**一句**：是哪条腿 + 字段与数值 + 该做什么 + 同一时刻别的腿看到了什么。
        /// 一句话只在这一处拼：统一日志、工具回执、面板那行读的都是它。
        var userText: String {
            "资产未验证（\(leg.rawValue)）：字段=\(field) 期望=\(expected) 实际=\(actual)。\(leg.remedy)"
                + "（同一时刻的量：\(examination)）"
        }
    }

    let objectID: String
    /// `residentOwnedPropAssets` 里那条记录（`nil` = 这条腿没过）。
    let record: WorldGeneratedProp?
    /// 记录里那份资产的落点（`nil` = 没有记录）。
    let recordModelURL: String?
    /// 本地资产记录表里此刻有几条、分别叫什么（"到底有没有它"必须可核对）。
    let recordCount: Int
    let recordNames: [String]
    /// 世界状态里那份身份（这次要挂的那一幕要求的身份）；拿不到时 `nil`（不比对身份）。
    let expected: WorldGeneratedProp?
    /// 记录里那份身份与世界状态里那份身份**是不是同一件东西**（`nil` = 这次没有给出要比对的身份）。
    ///
    /// 判定本身只有一处：`WorldGeneratedProp.matchesIdentity(of:)`（WorldRuntime）。这一份是
    /// **结论**，不是第二份判据 —— 宿主算完传进来，这里只负责把它翻译成"哪几个字段、期望什么、
    /// 实际什么"。这样离线 harness 用最小的世界类型替身也能编这一份（它不必实现那条判据）。
    let identityMatches: Bool?
    /// 一次已经发生过的字节校验收据（`nil` = 这条资产还没走过字节校验）。
    let byteReceipt: ResidentPropAssetByteReceipt?
    let fileExists: Bool
    let fileIsRegularFile: Bool
    let fileIsSymbolicLink: Bool
    /// 此刻 `stat` 到的字节数（`nil` = 拿不到 / 路径未知）。
    let fileBytes: Int?
    /// 此刻**真的重算过**的 sha256（`nil` = 这条路径不重算字节，例如每帧级的挂点可用性查询）。
    let observedSHA256: String?
    /// 渲染器有没有备好这份资产。
    let prepared: Bool

    /// 按**腿**的顺序给出第一条不成立的。`nil` = 五条腿全过（资产已验证）。
    var failure: Failure? {
        guard let record else {
            return Failure(leg: .record,
                field: "residentOwnedPropAssets[\(objectID)]",
                expected: "一条已准备的资产记录",
                actual: "nil（当前表里 \(recordCount) 条：\(recordNames.isEmpty ? "（空）" : recordNames.joined(separator: "、"))）",
                examination: examination)
        }
        if identityMatches == false {
            guard let expected else {
                // 判据说"不同"却拿不出要比对的身份：fail-closed，而且把这件事本身说出来。
                return Failure(leg: .identity, field: "identityMatches",
                    expected: "true", actual: "false（这次没有给出要比对的身份）",
                    examination: examination)
            }
            let difference = Self.identityDifference(record, expected)
            return Failure(leg: .identity, field: difference.fields,
                expected: difference.expected, actual: difference.actual, examination: examination)
        }
        let path = recordModelURL ?? byteReceipt?.modelURL ?? "（未知路径）"
        guard fileExists else {
            return Failure(leg: .file, field: "文件路径",
                expected: "\(path) 存在" + (byteReceipt.map { "，且是 \($0.bytes) 字节的普通文件" } ?? ""),
                actual: "不存在", examination: examination)
        }
        guard fileIsRegularFile, !fileIsSymbolicLink else {
            return Failure(leg: .file, field: "文件类型",
                expected: "普通文件（非符号链接）",
                actual: fileIsSymbolicLink ? "符号链接" : "不是普通文件", examination: examination)
        }
        if let receipt = byteReceipt, let fileBytes, fileBytes != receipt.bytes {
            return Failure(leg: .file, field: "字节数",
                expected: "\(receipt.bytes)（校验收据 \(receipt.modelURL)）",
                actual: "\(fileBytes)", examination: examination)
        }
        let declared = expected.flatMap { Self.declaredSHA256($0.assetID) }
        if let observed = observedSHA256?.lowercased() {
            if let reference = byteReceipt?.sha256.lowercased() ?? declared, observed != reference {
                return Failure(leg: .hash, field: "sha256(\(path))",
                    expected: "sha256:\(reference)", actual: "sha256:\(observed)", examination: examination)
            }
        } else if let receipt = byteReceipt, let declared, receipt.sha256.lowercased() != declared {
            return Failure(leg: .hash, field: "记录里的 assetID",
                expected: "sha256:\(declared)", actual: "sha256:\(receipt.sha256)（字节校验收据）",
                examination: examination)
        }
        guard prepared else {
            return Failure(leg: .prepare,
                field: "isResidentPropPrepared(assetID: \(record.assetID), modelURL: \(path))",
                expected: "true（渲染器已备好这份资产）", actual: "false", examination: examination)
        }
        return nil
    }

    /// 同一时刻五条腿各自看到了什么。拒绝的那一句里**同时**给出，排障不必再猜别的腿。
    var examination: String {
        var parts: [String] = []
        parts.append("记录=" + (record.map { "有（\($0.displayName)）" } ?? "无"))
        if let identityMatches {
            parts.append("身份=" + (identityMatches ? "相同" : "不同"))
        } else {
            parts.append("身份=未判（这次没有给出要比对的身份）")
        }
        parts.append("文件=" + (record == nil && byteReceipt == nil
            ? "未判（没有记录里的路径）"
            : (fileExists
                ? "存在\(fileIsRegularFile ? "" : "（非普通文件）")\(fileIsSymbolicLink ? "（符号链接）" : "")"
                    + (fileBytes.map { " \($0) 字节" } ?? "")
                : "不存在")
                + (byteReceipt.map { "（校验收据 \($0.bytes) 字节）" } ?? "（没有校验收据）")))
        if let observed = observedSHA256 {
            parts.append("哈希=sha256:\(observed.lowercased())（此刻重算）")
        } else if let receipt = byteReceipt {
            parts.append("哈希=未重算（校验收据 sha256:\(receipt.sha256)）")
        } else {
            parts.append("哈希=未判（这条资产还没走过字节校验）")
        }
        parts.append("渲染器备好=\(prepared)")
        return parts.joined(separator: "；")
    }

    /// `assetID` 里那半段 sha256（`sha256:<hex>`；不是这个形状就 `nil`，绝不猜）。
    static func declaredSHA256(_ assetID: String) -> String? {
        guard assetID.hasPrefix("sha256:") else { return nil }
        let digest = String(assetID.dropFirst("sha256:".count))
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
        return digest.lowercased()
    }

    /// 身份不一致时**逐字段**说出期望与实际（不是一句"不一致"）。
    static func identityDifference(_ record: WorldGeneratedProp,
                                   _ expected: WorldGeneratedProp)
        -> (fields: String, expected: String, actual: String) {
        var fields: [String] = []
        var expectedText: [String] = []
        var actualText: [String] = []
        func note(_ field: String, _ want: String, _ have: String) {
            fields.append(field); expectedText.append("\(field)=\(want)"); actualText.append("\(field)=\(have)")
        }
        if record.objectID != expected.objectID { note("objectID", expected.objectID, record.objectID) }
        if record.sourceWishID != expected.sourceWishID { note("sourceWishID", expected.sourceWishID, record.sourceWishID) }
        if record.assetID != expected.assetID { note("assetID", expected.assetID, record.assetID) }
        if record.displayName != expected.displayName { note("displayName", expected.displayName, record.displayName) }
        if record.size != expected.size { note("size", Self.sizeText(expected.size), Self.sizeText(record.size)) }
        // `matchesIdentity` 已经说过"不成立"，而上面五个字段就是它读的全部；一个都没列出来
        // 说明身份判据与它自己读的字段之间出现了第二种真相 —— 明确说出来，不许静默给一句空话。
        guard !fields.isEmpty else {
            return ("（matchesIdentity 判为不同，但五个字段逐位相同 —— 判据本身出了分歧）",
                    "record.matchesIdentity(expected) == true", "matchesIdentity(expected) == false")
        }
        return (fields.joined(separator: "、"),
                expectedText.joined(separator: "；"), actualText.joined(separator: "；"))
    }

    static func sizeText(_ size: WorldVector3) -> String {
        String(format: "(%.3f, %.3f, %.3f)", size.x, size.y, size.z)
    }
}

enum PropAttachmentPose {
    static func orthonormalized(
        _ transform: simd_float4x4
    ) throws -> simd_float4x4 {
        guard transform.columns.0.x.isFinite,
              transform.columns.0.y.isFinite,
              transform.columns.0.z.isFinite,
              transform.columns.1.x.isFinite,
              transform.columns.1.y.isFinite,
              transform.columns.1.z.isFinite,
              transform.columns.2.x.isFinite,
              transform.columns.2.y.isFinite,
              transform.columns.2.z.isFinite,
              transform.columns.3.x.isFinite,
              transform.columns.3.y.isFinite,
              transform.columns.3.z.isFinite
        else {
            throw PropAttachmentError.invalidHandPose
        }

        let rawX = SIMD3<Float>(
            transform.columns.0.x,
            transform.columns.0.y,
            transform.columns.0.z
        )
        let rawY = SIMD3<Float>(
            transform.columns.1.x,
            transform.columns.1.y,
            transform.columns.1.z
        )
        let rawZ = SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        )
        guard simd_length_squared(rawX) > 0.000_000_1,
              simd_length_squared(rawY) > 0.000_000_1,
              simd_length_squared(rawZ) > 0.000_000_1
        else {
            throw PropAttachmentError.invalidHandPose
        }

        let x = simd_normalize(rawX)
        let adjustedY = rawY - x * simd_dot(rawY, x)
        guard simd_length_squared(adjustedY) > 0.000_000_1 else {
            throw PropAttachmentError.invalidHandPose
        }
        let y = simd_normalize(adjustedY)
        let z = simd_normalize(simd_cross(x, y))
        guard simd_length_squared(z) > 0.000_000_1 else {
            throw PropAttachmentError.invalidHandPose
        }

        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0),
            SIMD4<Float>(y, 0),
            SIMD4<Float>(z, 0),
            SIMD4<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z,
                1
            )
        ))
    }
}

enum PropAttachmentMatrix {
    static func transform(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>,
        descriptor: ResidentHeldPropDescriptor,
        handPose: simd_float4x4
    ) throws -> simd_float4x4 {
        let pose = try PropAttachmentPose.orthonormalized(handPose)
        // 手里的这一件与地上那一件是**同一份资产**：网格躺着生成时，手持也必须先转正，
        // 否则同一件东西"放在地上立着、拿在手里躺着"（画面自相矛盾）。
        //
        // 抓握点刻意仍按**原始网格**的包围盒算（`normalizedGrip` 是相对原始 AABB 的比例，
        // 存档里每件物件的标定就是这个意思），只是把那个点跟着一起转过去 ——
        // 于是旧标定不动，而手里的姿态与地上的姿态一致。
        let orientation = descriptor.orientation
        let upright = !WorldPropRotation.isIdentity(orientation)
        let bounds = WorldPropOrientationPolicy.orientedBounds(
            minimum: minimum, maximum: maximum, rotation: orientation
        )
        // 缩放要用的**摆正后**三轴跨度。手里这一件与地上那一件读的是同一组数字
        // （`targetSizeMeters` = 世界里那一份 `effectiveSize`），所以形状不可能不一致。
        let rawExtent = upright
            ? SIMD3<Float>(bounds.maximum.x - bounds.minimum.x,
                           bounds.maximum.y - bounds.minimum.y,
                           bounds.maximum.z - bounds.minimum.z)
            : SIMD3<Float>(maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z)
        let height = rawExtent.y
        let calibration = descriptor.calibration
        var values = [
            minimum.x, minimum.y, minimum.z,
            maximum.x, maximum.y, maximum.z,
            descriptor.targetHeightMeters,
            calibration.normalizedGrip.x,
            calibration.normalizedGrip.y,
            calibration.normalizedGrip.z,
            calibration.localOffset.x,
            calibration.localOffset.y,
            calibration.localOffset.z,
            calibration.localRotation.x,
            calibration.localRotation.y,
            calibration.localRotation.z,
            calibration.localRotation.w,
        ]
        if let targetSize = descriptor.targetSizeMeters {
            values.append(contentsOf: [targetSize.x, targetSize.y, targetSize.z])
        }
        // 逐轴那一份：只有目标尺寸**不是**这份网格的等比像时才真的分叉（判据复用既有的
        // `WorldPropSizePolicy.uniformFactor`，与已摆那一件同一处）。每一维都与
        // `targetHeightMeters` **同一条边界**（0 < v ≤ 10 米）。
        let perAxis: SIMD3<Float>? = descriptor.targetSizeMeters.flatMap { targetSize in
            guard WorldPropSizePolicy.uniformFactor(
                from: WorldVector3(x: rawExtent.x, y: rawExtent.y, z: rawExtent.z),
                to: targetSize) == nil else { return nil }
            return SIMD3<Float>(targetSize.x, targetSize.y, targetSize.z)
        }
        guard values.allSatisfy(\.isFinite),
              height > 0.000_01,
              rawExtent.x > 0.000_01, rawExtent.z > 0.000_01,
              descriptor.targetHeightMeters > 0,
              descriptor.targetHeightMeters <= 10,
              perAxis.map({ $0.x > 0 && $0.x <= 10 && $0.y > 0 && $0.y <= 10 && $0.z > 0 && $0.z <= 10 })
                  ?? true,
              calibration.avatarAssetID == ResidentPropAttachmentEligibility.supportedAvatarID,
              calibration.hand == descriptor.attachmentPoint.worldSlot,
              (0...1).contains(calibration.normalizedGrip.x),
              (0...1).contains(calibration.normalizedGrip.y),
              (0...1).contains(calibration.normalizedGrip.z)
        else {
            throw PropAttachmentError.invalidHandPose
        }

        let rotationValue = SIMD4<Float>(
            calibration.localRotation.x,
            calibration.localRotation.y,
            calibration.localRotation.z,
            calibration.localRotation.w
        )
        guard simd_length_squared(rotationValue) > 0.000_000_1 else {
            throw PropAttachmentError.invalidHandPose
        }
        let uniformScaleValue = descriptor.targetHeightMeters / height
        let scaleValues = perAxis.map {
            SIMD3<Float>($0.x / rawExtent.x, $0.y / rawExtent.y, $0.z / rawExtent.z)
        } ?? SIMD3<Float>(repeating: uniformScaleValue)
        let grip = minimum + (maximum - minimum) * SIMD3<Float>(
            calibration.normalizedGrip.x,
            calibration.normalizedGrip.y,
            calibration.normalizedGrip.z
        )
        let offset = SIMD3<Float>(
            calibration.localOffset.x,
            calibration.localOffset.y,
            calibration.localOffset.z
        )
        let quaternion = simd_quatf(vector: rotationValue).normalized
        var localRotation = simd_float4x4(quaternion)
        localRotation.columns.3 = SIMD4<Float>(offset, 1)
        var scale = matrix_identity_float4x4
        scale.columns.0.x = scaleValues.x
        scale.columns.1.y = scaleValues.y
        scale.columns.2.z = scaleValues.z
        // 抓握点先转到**摆正后**的坐标系里：`T(-R·grip) · R` 与"先转正再取原始 grip 点"
        // 是同一件事，于是手里握的还是网格上同一个物理位置。
        let anchoredGrip = upright
            ? WorldPropRotation.rotate(grip, by: orientation)
            : grip
        var anchor = matrix_identity_float4x4
        anchor.columns.3 = SIMD4<Float>(-anchoredGrip, 1)
        guard upright else {
            return pose * localRotation * scale * anchor
        }
        var uprightMatrix = matrix_identity_float4x4
        let (qx, qy, qz, qw) = (orientation.x, orientation.y, orientation.z, orientation.w)
        uprightMatrix.columns.0 = SIMD4(1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy + qz * qw), 2 * (qx * qz - qy * qw), 0)
        uprightMatrix.columns.1 = SIMD4(2 * (qx * qy - qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz + qx * qw), 0)
        uprightMatrix.columns.2 = SIMD4(2 * (qx * qz + qy * qw), 2 * (qy * qz - qx * qw), 1 - 2 * (qx * qx + qy * qy), 0)
        return pose * localRotation * scale * anchor * uprightMatrix
    }
}
