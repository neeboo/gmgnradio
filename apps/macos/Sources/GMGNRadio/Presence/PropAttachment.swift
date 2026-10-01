import Foundation
import simd
import WorldRuntime

/// 物件挂在角色的**哪个挂点**上：右手（既有）、背后、腰间。
///
/// 手的两个候选骨名逐字未动。背后/腰间的**默认偏移与朝向**不在这里 —— 那是
/// `PropAttachmentSlot.swift` 的挂点表（`PropAttachmentSlots`）。这里只回答
/// "这个挂点看哪些骨名"这一件事，理由（真机静止坐标）写在那份挂点表的文件头。
enum PropAttachmentPoint: String, CaseIterable, Equatable, Sendable {
    case rightHand
    case back
    case waist

    var boneNameCandidates: [String] {
        switch self {
        case .rightHand:
            ["右手首", "bone009"]
        case .back:
            // 胸骨：标准命名 上半身2（真机 y=15.38）→ 匿名 raw 骨 bone002（真机 y=114.3）
            // → 退化到脊椎根 上半身 / bone001（真机 y=101.6，是髋的高度、不是胸）。
            ["上半身2", "bone002", "上半身", "bone001"]
        case .waist:
            // 腰/骨盆：标准命名 腰（真机 univ="waist"，y=12.85）→ 下半身（y=14.55）
            // → 匿名 raw 骨的骨盆 bone014（真机 y=101.6，父 bone000）→ 骨架根 センター/bone000。
            // 刻意**不含任何手骨**：腰间挂错到手骨上，画面上一眼能看出。
            ["腰", "下半身", "bone014", "センター", "bone000"]
        }
    }
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
        }
    }

    /// 失败文案里那串"找过哪些骨名"。只有一个出处：挂点自己的候选表。
    static func candidatesText(_ point: PropAttachmentPoint) -> String {
        point.boneNameCandidates.joined(separator: " / ")
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
        let height = upright ? bounds.maximum.y - bounds.minimum.y : maximum.y - minimum.y
        let calibration = descriptor.calibration
        let values = [
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
        guard values.allSatisfy(\.isFinite),
              height > 0.000_01,
              descriptor.targetHeightMeters > 0,
              descriptor.targetHeightMeters <= 10,
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
        let scaleValue = descriptor.targetHeightMeters / height
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
        scale.columns.0.x = scaleValue
        scale.columns.1.y = scaleValue
        scale.columns.2.z = scaleValue
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
