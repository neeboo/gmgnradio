import Foundation
import simd
import WorldRuntime

enum PropAttachmentPoint: String, Equatable, Sendable {
    case rightHand

    var boneNameCandidates: [String] {
        switch self {
        case .rightHand:
            ["右手首", "bone009"]
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

    var assetKey: String {
        assetID + "|" + modelURL.standardizedFileURL.path
    }
}

enum PropAttachmentError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedAvatar
    case avatarMismatch
    case missingHandBone
    case invalidHandPose
    case assetNotPrepared

    var errorDescription: String? {
        switch self {
        case .unsupportedAvatar:
            "当前角色还不能拿起物件。首版仅支持已适配的 2B 角色。"
        case .avatarMismatch:
            "拿取记录属于另一个角色，请先把物件放回。"
        case .missingHandBone:
            "当前 2B 模型缺少右手骨骼，暂时无法拿起物件。"
        case .invalidHandPose:
            "当前右手姿势无效，暂时无法显示物件。"
        case .assetNotPrepared:
            "物件还没有准备好，暂时无法拿起。"
        }
    }
}

enum ResidentPropAttachmentEligibility {
    static let supportedAvatarID = "pmx.2b-miss-0414-standard"

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

    static func suggestedCalibration(
        for prop: WorldGeneratedProp,
        avatar: StageAvatarAsset?
    ) -> WorldPropGripCalibration? {
        guard prop.isValid, isEligible(avatar), let avatar else { return nil }
        return WorldPropGripCalibration(
            avatarAssetID: avatar.id,
            hand: .rightHand,
            normalizedGrip: WorldVector3(x: 0.5, y: 0.2, z: 0.5),
            localOffset: WorldVector3(x: 0, y: 0, z: 0),
            localRotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
        )
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
        let height = maximum.y - minimum.y
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
              calibration.hand == .rightHand,
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
        var anchor = matrix_identity_float4x4
        anchor.columns.3 = SIMD4<Float>(-grip, 1)
        return pose * localRotation * scale * anchor
    }
}
