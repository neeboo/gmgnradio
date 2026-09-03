import Foundation
import VRMMetalKit

enum VMDHumanoidMap {
    static func bones(named sourceName: String) -> [VRMHumanoidBone] {
        let name = normalized(sourceName)
        if let bones = directBoneMap[name] {
            return bones
        }
        if let finger = fingerBone(named: name) {
            return [finger]
        }
        return []
    }

    static func expressionName(for sourceName: String) -> String {
        let name = normalized(sourceName)
        return expressionMap[name] ?? sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let directBoneMap: [String: [VRMHumanoidBone]] = [
        "センター": [.hips],
        "グルーブ": [.hips],
        "下半身": [.hips],
        "腰": [.hips],
        "hips": [.hips],
        "上半身": [.spine],
        "spine": [.spine],
        "上半身2": [.chest],
        "chest": [.chest],
        "上半身3": [.upperChest],
        "upperchest": [.upperChest],
        "首": [.neck],
        "neck": [.neck],
        "頭": [.head],
        "head": [.head],
        "左目": [.leftEye],
        "右目": [.rightEye],
        "両目": [.leftEye, .rightEye],
        "左肩": [.leftShoulder],
        "右肩": [.rightShoulder],
        "左腕": [.leftUpperArm],
        "右腕": [.rightUpperArm],
        "左腕捩": [.leftUpperArmTwist],
        "右腕捩": [.rightUpperArmTwist],
        "左ひじ": [.leftLowerArm],
        "左肘": [.leftLowerArm],
        "右ひじ": [.rightLowerArm],
        "右肘": [.rightLowerArm],
        "左手捩": [.leftLowerArmTwist],
        "右手捩": [.rightLowerArmTwist],
        "左手首": [.leftHand],
        "右手首": [.rightHand],
        "左足": [.leftUpperLeg],
        "右足": [.rightUpperLeg],
        "左ひざ": [.leftLowerLeg],
        "左膝": [.leftLowerLeg],
        "右ひざ": [.rightLowerLeg],
        "右膝": [.rightLowerLeg],
        "左足首": [.leftFoot],
        "右足首": [.rightFoot],
        "左つま先": [.leftToes],
        "右つま先": [.rightToes],
    ]

    private static let expressionMap: [String: String] = [
        "あ": "aa",
        "a": "aa",
        "い": "ih",
        "i": "ih",
        "う": "ou",
        "u": "ou",
        "え": "ee",
        "e": "ee",
        "お": "oh",
        "o": "oh",
        "まばたき": "blink",
        "blink": "blink",
        "ウィンク": "blinkLeft",
        "ウィンク左": "blinkLeft",
        "ウィンク右": "blinkRight",
        "笑い": "happy",
        "にこり": "happy",
        "怒り": "angry",
        "悲しい": "sad",
        "困る": "sad",
        "びっくり": "surprised",
        "驚き": "surprised",
        "なごみ": "relaxed",
    ]

    private static func fingerBone(named name: String) -> VRMHumanoidBone? {
        let side: Character
        let remainder: Substring
        if name.first == "左" {
            side = "L"
            remainder = name.dropFirst()
        } else if name.first == "右" {
            side = "R"
            remainder = name.dropFirst()
        } else {
            return nil
        }

        let value = String(remainder)
        let definitions: [(aliases: [String], bones: [VRMHumanoidBone], rightBones: [VRMHumanoidBone], startsAtZero: Bool)] = [
            (["親指"], [.leftThumbMetacarpal, .leftThumbProximal, .leftThumbDistal], [.rightThumbMetacarpal, .rightThumbProximal, .rightThumbDistal], true),
            (["人指", "人差指"], [.leftIndexProximal, .leftIndexIntermediate, .leftIndexDistal], [.rightIndexProximal, .rightIndexIntermediate, .rightIndexDistal], false),
            (["中指"], [.leftMiddleProximal, .leftMiddleIntermediate, .leftMiddleDistal], [.rightMiddleProximal, .rightMiddleIntermediate, .rightMiddleDistal], false),
            (["薬指"], [.leftRingProximal, .leftRingIntermediate, .leftRingDistal], [.rightRingProximal, .rightRingIntermediate, .rightRingDistal], false),
            (["小指"], [.leftLittleProximal, .leftLittleIntermediate, .leftLittleDistal], [.rightLittleProximal, .rightLittleIntermediate, .rightLittleDistal], false),
        ]

        for definition in definitions {
            for alias in definition.aliases where value.hasPrefix(alias) {
                guard let number = Int(value.dropFirst(alias.count)) else { return nil }
                let index = definition.startsAtZero ? number : number - 1
                let bones = side == "L" ? definition.bones : definition.rightBones
                guard bones.indices.contains(index) else { return nil }
                return bones[index]
            }
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "０", with: "0")
            .replacingOccurrences(of: "１", with: "1")
            .replacingOccurrences(of: "２", with: "2")
            .replacingOccurrences(of: "３", with: "3")
            .lowercased()
    }
}
