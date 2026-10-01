import Foundation
import simd
import WorldRuntime

// ===========================================================================
// 挂点（slot）：把「拿在右手」泛化成「挂在哪个挂点上」
// ===========================================================================
//
// 用户的原始要求是「物品能跟随人物吗，比如那把刀挂在人物的背后，或者放在腰间」。跟手这条链
// 早就通了 —— `PropAttachmentMatrix.transform` 算的一直是**骨骼世界变换 × 局部**，每帧在
// `MarbleSpatialView.renderResidentHeldProp`（`:2824-2875`）里跑。缺的是"哪根骨头"这件事
// 只写了右手一处。这一份只做三件事，别的（公式/可见失败/状态归属）一个字都不动：
//
//   ① 每个挂点**看哪些骨名**（不同模型骨名不同，见下）
//   ② 每个挂点的**默认局部偏移与朝向**（背后斜挂、腰间横挂）
//   ③ 由上面两样造出 `WorldPropGripCalibration`（`hand` 字段就是挂点，见 `WorldPropSlot`）
//
// ## 真机骨名证据（2026-10-01 实测，不是猜）
//
// 直接解析真机安装的那份 PMX
// （`~/Library/Application Support/gmgn radio/PresencePackages/pmx.2b-miss-0414-standard/na_2b_0414.pmx`，
// 156 根骨头，模型名 `ヨルハ二号B型`），标准人形骨的**静止坐标**（MMD 单位）与父链是：
//
//   全ての親(0) → センター(1, y= 8.90) → グルーブ(2, y= 9.12) → 腰(3, y=12.85, univ="waist")
//      腰 → 上半身(4, y=14.51) → 上半身2(5, y=15.38) → 首(6, y=18.13) → 頭(7, y=18.70)
//      腰 → 下半身(73, y=14.55)
//      左手首(26, x=+6.17, y=14.85) / 右手首(51, x=-6.17, y=14.85)
//      両目/後髪 的 z 符号也核过：左目 z=-0.67、後髪 z=+1.30 ⇒ **-Z 是脸的朝向、+Z 是背后**；
//      左目 x=+0.40、右目 x=-0.40 ⇒ **+X 是角色左手侧**、**+Y 是上**。
//
// 另一代骨架（匿名 raw 2B，`boneNNN`）的对应关系记在 `PMXStageAvatarRenderer.raw2BBoneMap`
// 里，且我在 `backups/2026-08-12-before-2b-skeleton-restore/.../2B/23.pmx`（182 骨）上复核过
// 那几个数：`センター→bone000(y=101.6)`、`上半身→bone001(y=101.6)`、`上半身2→bone002(y=114.3)`、
// `下半身→bone014(y=101.6, 父 bone000)`、`右手首→bone009`。
// ⇒ **上半身2/bone002 是胸（背后挂点的骨）、下半身/bone014 与 腰 是骨盆（腰间挂点的骨）**，
// 两者都不是手骨。
//
// 于是候选骨名各给两代（标准命名在前、匿名骨名兜底），与手那条 `["右手首","bone009"]` 同一个手法。
//
// ## ⚠️ 需要在真机上确认的两件事
//
//   ① **穿模**：下面那几个默认偏移是按"米、骨骼局部空间"给的（与 `PropGripInference.localOffset`
//      的约定、以及编辑器「微调 2 厘米」同一个单位），数值本身没有在真机上量过。偏了不用重做 ——
//      用户/agent 用既有的 `adjustGrip` 一步就能挪，落库的也是挪完那一份。
//   ② 骨名是否真的在场景里找得到：`evaluatedAttachmentPose` 走的是
//      `childNode(withName:recursively:)`，找不到就**可见失败**（`missingBone`），不会静默。

extension PropAttachmentPoint {
    /// 世界状态里存的挂点。两处枚举一一对应：`WorldRuntime` 不能反过来依赖 app 层，
    /// 而存档里的 `hand` 字段读的就是世界那一份。
    var worldSlot: WorldPropSlot {
        switch self {
        case .rightHand: .rightHand
        case .back: .back
        case .waist: .waist
        }
    }
}

extension WorldPropSlot {
    /// 反方向：世界状态 → 渲染侧的挂点。
    var attachmentPoint: PropAttachmentPoint {
        switch self {
        case .rightHand: .rightHand
        case .back: .back
        case .waist: .waist
        }
    }
}

/// 挂点表：**唯一**一份"挂在哪儿、往哪偏、朝哪边"的定义。
///
/// 手那条路刻意**不在这里**另立默认值：它照旧读 `PropGripInference`（柄端握点 + 刃沿骨轴），
/// 于是改造前后逐字节相同。
enum PropAttachmentSlots {
    /// 面板与回执用的挂点名。**只有这一处**，编辑器那一行、agent 回执、失败文案都读它。
    static func displayName(for point: PropAttachmentPoint) -> String {
        switch point {
        case .rightHand: "右手"
        case .back: "背后"
        case .waist: "腰间"
        }
    }

    /// agent 工具与编辑器传进来的挂点名（英文短标识，与 `WorldPropSlot.rawValue` 同一份字面量）。
    static var acceptedNames: [String] { PropAttachmentPoint.allCases.map(\.worldSlot.rawValue) }

    /// 用户/agent 说的那句话 → 挂点。认不出来就是 `nil`，**不许猜一个**。
    ///
    /// 认的既有工具参数用的英文标识（`rightHand` / `back` / `waist`），也有用户嘴里那几种说法
    /// （"挂背后" / "挂腰上" / "拿手里"）—— 但只有这一处认识它们，别处不许再写一份别名表。
    static func resolve(name: String) -> PropAttachmentPoint? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "righthand", "right_hand", "hand", "手", "手里", "手上", "右手": .rightHand
        case "back", "背后", "背上", "后背": .back
        case "waist", "hip", "腰间", "腰上", "腰": .waist
        default: nil
        }
    }

    /// 这个挂点看哪些骨名（不同模型骨名不同；顺序就是查找顺序）。
    /// 骨名候选表本身留在 `PropAttachment.swift` 的枚举里 —— 那是仓库里既有的唯一定义处，
    /// harness 直接切那段源码编译；这里只回答"这个挂点有没有默认姿势"。
    static func boneNameCandidates(for point: PropAttachmentPoint) -> [String] {
        point.boneNameCandidates
    }

    /// **默认挂载偏移**：米，作用在**骨骼局部空间**（与 `PropGripInference` 的 `localOffset`
    /// 同一个单位、同一个坐标系，见 `PropAttachmentMatrix.transform` 的乘法次序）。
    ///
    /// - 手：`(0,0,0)` —— 沿用 `PropGripInference` 交回来的那一份，不另立默认值。
    /// - 背后：从**胸骨**（上半身2/bone002）往身后 15 cm（+Z 是背后，见文件头的真机坐标）。
    /// - 腰间：从**腰骨**（腰/下半身/bone014）往身后 12 cm、往下 2 cm。
    static func defaultOffsetMeters(for point: PropAttachmentPoint) -> WorldVector3 {
        switch point {
        case .rightHand: WorldVector3(x: 0, y: 0, z: 0)
        case .back: WorldVector3(x: 0, y: 0, z: 0.15)
        case .waist: WorldVector3(x: 0, y: -0.02, z: 0.12)
        }
    }

    /// **默认挂载点**：物件网格上的哪一个点落在上面那个偏移处（0…1 的原始 AABB 比例）。
    ///
    /// - 手：由 `PropGripInference` 给（细长物件落在柄端）。
    /// - 背后/腰间：网格**中点**。挂在背上/腰上的东西是"吊在那儿"，不是"攥在一端"，
    ///   所以刻意**不套用手那套柄端握点**。
    static func defaultNormalizedGrip(for point: PropAttachmentPoint) -> WorldVector3 {
        switch point {
        case .rightHand: PropGripInference.inheritedNormalizedGrip
        case .back, .waist: WorldVector3(x: 0.5, y: 0.5, z: 0.5)
        }
    }

    /// **默认朝向**：长轴（摆正后的主轴、也就是刀身）在**骨骼局部空间**里该指向哪儿。
    ///
    /// 骨骼的绑定旋转在 PMX 里是单位阵，所以骨局部轴 == 模型轴：
    /// `+X` = 角色左手侧、`+Y` = 上、`+Z` = 背后（真机坐标见文件头）。
    ///
    /// - 手：`(0,1,0)` —— 与 `PropGripInference.bladeDirectionInHandSpace` 同一个方向，
    ///   也就是"刃沿手骨骨轴"。这里返回它只是为了让三态共用同一个出口。
    /// - 背后：**斜挂** —— 刀尖朝左肩上方（离竖直约 33°），一眼能看出刀尖冲哪边。
    /// - 腰间：**横挂** —— 刀身沿角色左右轴水平躺着。
    static func bladeDirectionInBoneSpace(for point: PropAttachmentPoint) -> SIMD3<Float> {
        switch point {
        case .rightHand: PropGripInference.bladeDirectionInHandSpace
        case .back: simd_normalize(SIMD3<Float>(0.55, 0.835, 0))
        case .waist: SIMD3<Float>(1, 0, 0)
        }
    }

    /// 由「挂点 + 当前物件」造一份标定。**手那条路逐字节等于 `PropGripInference.suggestion`**。
    static func calibration(
        avatarAssetID: String,
        prop: WorldGeneratedProp,
        point: PropAttachmentPoint
    ) -> WorldPropGripCalibration? {
        guard prop.isValid, !avatarAssetID.isEmpty, avatarAssetID.count <= 256 else { return nil }
        let suggestion = PropGripInference.suggestion(for: prop)
        let calibration: WorldPropGripCalibration
        switch point {
        case .rightHand:
            // 手：握点、偏移、朝向**全部**照旧由推断给出（`localOffset` 恒为 0）。
            calibration = WorldPropGripCalibration(
                avatarAssetID: avatarAssetID,
                hand: point.worldSlot,
                normalizedGrip: suggestion.normalizedGrip,
                localOffset: suggestion.localOffset,
                localRotation: suggestion.localRotation
            )
        case .back, .waist:
            // 背后/腰间：握点与偏移由挂点定义给出，朝向 = 把"推断出来的刃轴"转到挂点要的方向。
            calibration = WorldPropGripCalibration(
                avatarAssetID: avatarAssetID,
                hand: point.worldSlot,
                normalizedGrip: defaultNormalizedGrip(for: point),
                localOffset: defaultOffsetMeters(for: point),
                localRotation: rotationAligningBlade(
                    of: prop, suggestion: suggestion, to: bladeDirectionInBoneSpace(for: point)
                )
            )
        }
        guard calibration.isValid else { return nil }
        return calibration
    }

    /// 挂点默认姿势的**人话**说明（面板那一行与 agent 回执读它）。手那条路没有要说的。
    static func notice(for point: PropAttachmentPoint) -> String? {
        switch point {
        case .rightHand: nil
        case .back:
            "已挂到背后（骨骼：上半身2 / bone002 一系），斜挂、刀尖朝左肩上方，离胸骨 15 厘米。"
        case .waist:
            "已挂到腰间（骨骼：腰 / 下半身 / bone014 一系），横挂，离腰骨 12 厘米。"
        }
    }

    /// 刀身（摆正后的主轴）在骨骼局部空间里现在的方向 → 转到挂点要的方向。
    ///
    /// 复用 `PropGripInference` 的**同一个**换算（它就是"刃轴相对骨轴指哪"的唯一定义）；
    /// 读不出刃轴时原样返回推断的旋转，不猜。
    private static func rotationAligningBlade(
        of prop: WorldGeneratedProp,
        suggestion: PropGripSuggestion,
        to target: SIMD3<Float>
    ) -> WorldQuaternion {
        let base = suggestion.localRotation
        guard let current = PropGripInference.bladeAxisInHandSpace(
            size: prop.effectiveSize,
            orientation: prop.orientationRotation,
            localRotation: base
        ) else { return base }
        return quaternionProduct(PropGripInference.rotationAligning(current, to: target), base)
    }

    /// 四元数乘法（与 `WorldPropRotation.rotate` 同一个约定：`a * b` 先生效 `b` 再生效 `a`）。
    static func quaternionProduct(_ a: WorldQuaternion, _ b: WorldQuaternion) -> WorldQuaternion {
        let product = simd_quatf(vector: SIMD4<Float>(a.x, a.y, a.z, a.w))
            * simd_quatf(vector: SIMD4<Float>(b.x, b.y, b.z, b.w))
        return WorldQuaternion(x: product.imag.x, y: product.imag.y, z: product.imag.z, w: product.real)
    }
}
