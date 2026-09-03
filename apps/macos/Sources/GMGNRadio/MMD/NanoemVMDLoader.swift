import CNanoem
import Foundation
import simd

enum VMDLoaderError: Error, Equatable {
    case emptyData
    case nanoemStatus(Int32)
    case invalidMotion
    case invalidString
}

enum NanoemVMDLoader {
    static func load(from url: URL) throws -> VMDMotionDocument {
        try load(data: Data(contentsOf: url))
    }

    static func load(data: Data) throws -> VMDMotionDocument {
        guard !data.isEmpty else { throw VMDLoaderError.emptyData }

        var status = nanoem_status_t(NANOEM_STATUS_SUCCESS)
        guard let factory = nanoemUnicodeStringFactoryCreateCF(&status) else {
            throw VMDLoaderError.nanoemStatus(Int32(status))
        }
        defer { nanoemUnicodeStringFactoryDestroyCF(factory) }

        guard let motion = nanoemMotionCreate(factory, &status) else {
            throw VMDLoaderError.nanoemStatus(Int32(status))
        }
        defer { nanoemMotionDestroy(motion) }

        return try data.withUnsafeBytes { rawBuffer in
            guard let address = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw VMDLoaderError.emptyData
            }
            guard let buffer = nanoemBufferCreate(address, data.count, &status) else {
                throw VMDLoaderError.nanoemStatus(Int32(status))
            }
            defer { nanoemBufferDestroy(buffer) }

            guard nanoemMotionLoadFromBufferVMD(motion, buffer, 0, &status) != 0,
                  status == nanoem_status_t(NANOEM_STATUS_SUCCESS)
            else {
                throw VMDLoaderError.nanoemStatus(Int32(status))
            }

            let targetName = try decode(
                nanoemMotionGetTargetModelName(motion),
                factory: factory,
                status: &status
            )
            let bones = try readBoneKeyframes(motion, factory: factory, status: &status)
            let morphs = try readMorphKeyframes(motion, factory: factory, status: &status)
            return VMDMotionDocument(
                targetModelName: targetName,
                boneKeyframes: bones,
                morphKeyframes: morphs
            )
        }
    }

    private static func readBoneKeyframes(
        _ motion: OpaquePointer,
        factory: OpaquePointer,
        status: inout nanoem_status_t
    ) throws -> [VMDBoneKeyframe] {
        var count: nanoem_rsize_t = 0
        guard let keyframes = nanoemMotionGetAllBoneKeyframeObjects(motion, &count) else {
            return []
        }

        var result: [VMDBoneKeyframe] = []
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let keyframe = keyframes[index],
                  let object = nanoemMotionBoneKeyframeGetKeyframeObject(keyframe)
            else {
                throw VMDLoaderError.invalidMotion
            }
            let name = try decode(
                nanoemMotionBoneKeyframeGetName(keyframe),
                factory: factory,
                status: &status
            )
            let translation = nanoemMotionBoneKeyframeGetTranslation(keyframe)
            let orientation = nanoemMotionBoneKeyframeGetOrientation(keyframe)
            let quaternion = simd_quatf(
                ix: orientation?[0] ?? 0,
                iy: orientation?[1] ?? 0,
                iz: orientation?[2] ?? 0,
                r: orientation?[3] ?? 1
            )
            result.append(
                VMDBoneKeyframe(
                    boneName: name,
                    frameIndex: nanoemMotionKeyframeObjectGetFrameIndex(object),
                    translation: SIMD3<Float>(
                        translation?[0] ?? 0,
                        translation?[1] ?? 0,
                        translation?[2] ?? 0
                    ),
                    rotation: normalizedOrIdentity(quaternion),
                    interpolation: VMDBoneInterpolation(
                        translationX: interpolation(
                            keyframe,
                            nanoem_motion_bone_keyframe_interpolation_type_t(
                                NANOEM_MOTION_BONE_KEYFRAME_INTERPOLATION_TYPE_TRANSLATION_X
                            )
                        ),
                        translationY: interpolation(
                            keyframe,
                            nanoem_motion_bone_keyframe_interpolation_type_t(
                                NANOEM_MOTION_BONE_KEYFRAME_INTERPOLATION_TYPE_TRANSLATION_Y
                            )
                        ),
                        translationZ: interpolation(
                            keyframe,
                            nanoem_motion_bone_keyframe_interpolation_type_t(
                                NANOEM_MOTION_BONE_KEYFRAME_INTERPOLATION_TYPE_TRANSLATION_Z
                            )
                        ),
                        rotation: interpolation(
                            keyframe,
                            nanoem_motion_bone_keyframe_interpolation_type_t(
                                NANOEM_MOTION_BONE_KEYFRAME_INTERPOLATION_TYPE_ORIENTATION
                            )
                        )
                    )
                )
            )
        }
        return result
    }

    private static func readMorphKeyframes(
        _ motion: OpaquePointer,
        factory: OpaquePointer,
        status: inout nanoem_status_t
    ) throws -> [VMDMorphKeyframe] {
        var count: nanoem_rsize_t = 0
        guard let keyframes = nanoemMotionGetAllMorphKeyframeObjects(motion, &count) else {
            return []
        }

        var result: [VMDMorphKeyframe] = []
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let keyframe = keyframes[index],
                  let object = nanoemMotionMorphKeyframeGetKeyframeObject(keyframe)
            else {
                throw VMDLoaderError.invalidMotion
            }
            result.append(
                VMDMorphKeyframe(
                    morphName: try decode(
                        nanoemMotionMorphKeyframeGetName(keyframe),
                        factory: factory,
                        status: &status
                    ),
                    frameIndex: nanoemMotionKeyframeObjectGetFrameIndex(object),
                    weight: nanoemMotionMorphKeyframeGetWeight(keyframe)
                )
            )
        }
        return result
    }

    private static func interpolation(
        _ keyframe: OpaquePointer,
        _ channel: nanoem_motion_bone_keyframe_interpolation_type_t
    ) -> VMDBezierControlPoints {
        guard let values = nanoemMotionBoneKeyframeGetInterpolation(keyframe, channel) else {
            return .linear
        }
        return VMDBezierControlPoints(values[0], values[1], values[2], values[3])
    }

    private static func decode(
        _ value: UnsafePointer<nanoem_unicode_string_t>?,
        factory: OpaquePointer,
        status: inout nanoem_status_t
    ) throws -> String {
        guard let value else { return "" }
        var length: nanoem_rsize_t = 0
        guard let bytes = nanoemUnicodeStringFactoryGetByteArrayEncoding(
            factory,
            value,
            &length,
            nanoem_codec_type_t(NANOEM_CODEC_TYPE_UTF8),
            &status
        ) else {
            throw VMDLoaderError.invalidString
        }
        defer { nanoemUnicodeStringFactoryDestroyByteArray(factory, bytes) }
        guard status == nanoem_status_t(NANOEM_STATUS_SUCCESS) else {
            throw VMDLoaderError.nanoemStatus(Int32(status))
        }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(length)), as: UTF8.self)
    }

    private static func normalizedOrIdentity(_ value: simd_quatf) -> simd_quatf {
        let lengthSquared = simd_length_squared(value.vector)
        guard lengthSquared.isFinite, lengthSquared > 0.000_001 else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_normalize(value)
    }
}
