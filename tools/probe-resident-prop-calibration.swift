// 决定性探针：用**真生产源码**（`PropAttachment.swift` / `PropAttachmentSlot.swift` /
// `PropGripInference.swift`）与真机世界状态里那把剑的**真实数值**，跑一遍
// `makeGripCalibration` 那条链里最后、也是唯一一处从没被任何门禁编译过的一步：
//
//     ResidentPropAttachmentEligibility.suggestedCalibration(for:avatar:point:)
//       → PropAttachmentSlots.calibration(avatarAssetID:prop:point:)
//
// 为什么必须这么做：所有离线门禁（`test-resident-prop-hold.swift` 等）都用
// `tools/fixtures/ResidentPropHoldLimitShim.swift` 给 `ResidentPropAttachmentEligibility`
// 打**替身**，因为真定义所在的那份文件依赖 `StageAvatarAsset`。于是"生产那一份
// `suggestedCalibration` 到底返回什么"从来没有被编译、更没有被断言过。
import Foundation
import WorldRuntime

// ---- 渲染侧类型的最小替身（真定义在 Presence/StageAvatarRuntime.swift）----
enum StageAvatarFormat: String, Codable, Equatable, Sendable { case pmx, vrm }
struct StageAvatarAsset: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let format: StageAvatarFormat
    let modelURL: URL
    let resourceRootURL: URL
}

@MainActor var failures = 0

@MainActor func check(_ value: Bool, _ message: String) {
    print(value ? "  OK   \(message)" : "  FAIL \(message)")
    if !value { failures += 1 }
}
@main
struct Probe {
    @MainActor static func main() {

        // ---- 真机世界状态里那把剑（`world_records` domain=objects、
        //      key=wish-prop-4210db95-9253-4caf-83a3-3c45f090b099 的 `gmgn.generated-prop.v1`）----
        let sword = WorldGeneratedProp(
            objectID: "wish-prop-4210db95-9253-4caf-83a3-3c45f090b099",
            sourceWishID: "4210DB95-9253-4CAF-83A3-3C45F090B099",
            assetID: "sha256:e9dda009e47ca4c1ace5e8a6e4ccf18645a109556b4f4772e410815c2be05529",
            displayName: "2B 白色长剑（外形摆件）",
            size: WorldVector3(x: 0.14604884, y: 1.1, z: 0.061886825),
            sourceHeight: 1.0054325,
            orientation: WorldPropOrientation(
                rotation: WorldQuaternion(x: 0, y: 0, z: 0.70710677, w: 0.7071068),
                source: .inferredPrincipalAxis,
                notice: nil
            )
        )
        let avatar = StageAvatarAsset(
            id: ResidentPropAttachmentEligibility.supportedAvatarID,
            name: "2B小姐姐 04.14",
            format: .pmx,
            modelURL: URL(fileURLWithPath: "/tmp/na_2b_0414.pmx"),
            resourceRootURL: URL(fileURLWithPath: "/tmp")
        )

        print("== 真机那份 PMX 的骨名候选（探针已证明真节点树里全都在）==")
        for point in PropAttachmentPoint.allCases {
            print("  \(PropAttachmentSlots.displayName(for: point)): \(PropAttachmentSlots.candidatesText(for: point))")
        }
        print()

        print("== 资格判据（`rejectionReason`）==")
        if let reason = ResidentPropAttachmentEligibility.rejectionReason(for: avatar) {
            print("  拒绝：\(reason)")
        } else {
            print("  通过（id=\(avatar.id), format=\(avatar.format.rawValue)）")
        }
        check(ResidentPropAttachmentEligibility.rejectionReason(for: avatar) == nil,
              "已适配的 2B PMX 角色必须过资格判据")
        check(sword.isValid, "真机那把剑的 WorldGeneratedProp 必须合法（否则物件本身在服务里就被拒）")
        print()

        print("== 净空 ==")
        for point in [PropAttachmentPoint.back, .waist] {
            let clearance = PropAttachmentSlots.clearanceMeters(for: sword, point: point)
            print(String(format: "  %@ 净空 = %@ m",
                         PropAttachmentSlots.displayName(for: point) as NSString,
                         clearance.map { String(format: "%.4f", $0) } ?? "nil(判不了)"))
            check(PropAttachmentSlots.clearanceRejection(for: sword, point: point) == nil,
                  "\(PropAttachmentSlots.displayName(for: point)) 净空必须过闸")
        }
        print()

        print("== ✅ `suggestedCalibration`：生产最后一道也是唯一没被门禁编译过的那一步 ==")
        for point in PropAttachmentPoint.allCases {
            let name = PropAttachmentSlots.displayName(for: point)
            if let calibration = ResidentPropAttachmentEligibility.suggestedCalibration(
                for: sword, avatar: avatar, point: point
            ) {
                let json = (try? JSONEncoder().encode(calibration))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "?"
                print("  \(name)：OK  \(json)")
                check(calibration.isValid, "\(name) 的标定必须 isValid")
                check(calibration.hand == point.worldSlot, "\(name) 的标定 hand 必须是这个挂点")
            } else {
                print("  \(name)：**nil ⇒ 生产会抛 `.attachmentUnsupported(\"这个物件还没有当前居民的\(name)挂点建议。\")`**")
            }
            check(ResidentPropAttachmentEligibility.suggestedCalibration(for: sword, avatar: avatar, point: point) != nil,
                  "真机那把剑在 \(name) 上必须拿得到标定（拿不到就是全挂不了的根因）")
        }

        // 极端情况：`suggestedCalibration` 的**输入**是不是问题所在
        print()
        print("== `PropGripInference.suggestion`（标定的输入）==")
        let suggestion = PropGripInference.suggestion(for: sword)
        print("  origin=\(suggestion.origin) normalizedGrip=(\(suggestion.normalizedGrip.x), \(suggestion.normalizedGrip.y), \(suggestion.normalizedGrip.z))")
        print("  localOffset=(\(suggestion.localOffset.x), \(suggestion.localOffset.y), \(suggestion.localOffset.z))")
        print("  localRotation=(\(suggestion.localRotation.x), \(suggestion.localRotation.y), \(suggestion.localRotation.z), \(suggestion.localRotation.w))")
        print("  isValid=\(suggestion.isValid)")
        print("  notice=\(suggestion.notice ?? "nil")")
        check(suggestion.isValid, "推断出来的握点必须合法")

        print()
        print(failures == 0 ? "RESULT: 这条链在真数值上全部通过" : "RESULT: \(failures) 条断言红了")
        exit(failures == 0 ? 0 : 1)

    }
}
