// 离线接地检查：PMX 全身动作的脚底接地与动作切换时的残留垂直位移。
//
// 从生产源码中抽取纯逻辑声明（PMXAnimatedGrounding / PMXFullStageGroundingPolicy /
// MarblePMXFraming）编译执行，并检查动作安装路径的接地状态对称性。不启动宿主、
// 不使用 GPU/SceneKit 场景、不触发任何系统授权。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}
/// 取 `signature` 起始的完整花括号声明体。
func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else {
        fatalError("missing declaration \(signature)")
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("unbalanced declaration \(signature)")
}

let pmx = try read("apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift")
let marble = try read("apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift")

// 1) 动作切换：installMotion 必须清除上一段动作残留的接地偏移，和 clearMotion 对称。
let installMotion = declaration("private func installMotion(", in: pmx)
let clearMotion = declaration("public func clearMotion(", in: pmx)
guard clearMotion.contains("localGroundingOffsetY = 0") else {
    print("FAIL: clearMotion no longer clears the animated grounding offset")
    exit(1)
}

// 2) 纯逻辑接地不变量。
let harness = #"""
import Foundation
import simd

struct PMXAvatarBounds: Equatable {
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
    var center: SIMD3<Float> { (minimum + maximum) * 0.5 }
    var size: SIMD3<Float> { maximum - minimum }
}

struct StageAvatarPlacement: Equatable {
    var position: SIMD3<Float>
    var scale: Float
    var yaw: Float
}

__PMX_ANIMATED_GROUNDING__
__PMX_CONTACT_GROUNDING__
__PMX_FULL_STAGE_GROUNDING__
__MARBLE_FRAMING__

var checks = 0
var failures = 0
let check: (Bool, String) -> Void = { value, message in
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

let bounds = PMXAvatarBounds(
    minimum: SIMD3<Float>(-5, 2, -3),
    maximum: SIMD3<Float>(5, 22, 3)
)
let placement = StageAvatarPlacement(
    position: SIMD3<Float>(1, 0.04, 3),
    scale: 0.8,
    yaw: 0
)
let rest: Float = 4
let animated: Float = 7

// rest 与 animated 脚的模型局部 Y 都以 bounds.minimum.y 为基准时，模型变换必须
// 把对应脚底精确放到 placement.position.y，高度归一化为 1.7 * scale。
let restTransform = MarblePMXFraming.modelTransform(
    bounds: bounds,
    placement: placement,
    soleReferenceY: rest
)
let restSole = restTransform * SIMD4<Float>(bounds.center.x, rest, bounds.center.z, 1)
// 生产路径里 animated 是模型局部的绝对 Y，rest 之外的基准由 soleReferenceY 提供。
let animatedSoleLocalY = animated
let animatedTransform = MarblePMXFraming.modelTransform(
    bounds: bounds,
    placement: placement,
    localGroundingOffsetY: PMXAnimatedGrounding.localOffsetY(
        restFootReferenceY: rest,
        animatedFootReferenceY: animated
    ),
    soleReferenceY: rest
)
let animatedSole = animatedTransform
    * SIMD4<Float>(bounds.center.x, animatedSoleLocalY, bounds.center.z, 1)
let restCrown = restTransform * SIMD4<Float>(bounds.center.x, bounds.maximum.y, bounds.center.z, 1)
check(abs(restSole.y - placement.position.y) < 0.0001,
      "rest sole is grounded exactly at the placement Y")
check(abs(animatedSole.y - placement.position.y) < 0.0001,
      "compensated animated sole is grounded exactly at the placement Y")
check(abs((restCrown.y - restSole.y) - 1.7 * placement.scale) < 0.0001,
      "sole-to-crown height normalizes to 1.7 * scale")

// 接地增量必须是「rest - animated」（模型局部量），不是绝对值、不是反向。
check(abs(PMXAnimatedGrounding.localOffsetY(restFootReferenceY: rest, animatedFootReferenceY: animated) + 3) < 0.0001,
      "grounding delta is rest minus animated")
check(PMXAnimatedGrounding.localOffsetY(restFootReferenceY: .nan, animatedFootReferenceY: animated) == 0,
      "non-finite rest reference disables compensation")

// 单向策略：根运动开启时完整补偿；关闭时只抬升、绝不下压。
check(PMXFullStageGroundingPolicy.offset(rootMotionEnabled: true, animatedOffset: -3) == -3,
      "root-motion clips keep the full signed compensation")
check(PMXFullStageGroundingPolicy.offset(rootMotionEnabled: false, animatedOffset: -3) == 0,
      "root-locked clips never lower the model below their authored world Y")
check(PMXFullStageGroundingPolicy.offset(rootMotionEnabled: false, animatedOffset: 3.0531) == 3.0531,
      "root-locked clips lift the model out of floor penetration")
check(PMXFullStageGroundingPolicy.offset(rootMotionEnabled: true, animatedOffset: .nan) == 0,
      "non-finite compensation is refused")

// 实测回归：用户 `preferred.pmx` 默认动作 recovery-faint 的センター下沉
// （离线 FK 实测 sole 低于地面 0.2445 m）。修复后脚底必须回到 placement Y 以上。
let faintBounds = PMXAvatarBounds(
    minimum: SIMD3<Float>(-5, -0.0022, -3),
    maximum: SIMD3<Float>(5, 21.2252, 3)
)
let faintPlacement = StageAvatarPlacement(
    position: SIMD3<Float>(0, -0.0678, 0),
    scale: 1,
    yaw: 0
)
let faintRest: Float = -0.0022
let faintAnimated: Float = -3.0553
let faintSoleOffset = PMXAnimatedGrounding.localOffsetY(
    restFootReferenceY: faintRest,
    animatedFootReferenceY: faintAnimated
)
let faintOffset = PMXFullStageGroundingPolicy.offset(
    rootMotionEnabled: false,
    animatedOffset: faintSoleOffset
)
let faintTransform = MarblePMXFraming.modelTransform(
    bounds: faintBounds,
    placement: faintPlacement,
    localGroundingOffsetY: faintOffset,
    soleReferenceY: faintRest
)
let faintSole = faintTransform * SIMD4<Float>(faintBounds.center.x, faintAnimated, faintBounds.center.z, 1)
check(faintSole.y >= faintPlacement.position.y - 0.0001,
      "measured recovery-faint sole no longer sinks below the floor")

// 全身最低接触（坐 / 跪 / 盘腿）：脚可能比静止姿态更高，只看脚会漏掉膝 / 小腿 / 臀。
// 复现"脚抬起、膝下沉"的接触姿态：脚参考偏移 <= 0（不抬升），而全身最低点低于地面。
let contactFootOffset = PMXAnimatedGrounding.localOffsetY(
    restFootReferenceY: 0.1,
    animatedFootReferenceY: 0.3
)
check(contactFootOffset < 0, "kneeling pose: soles sit above rest (foot-only offset is negative)")
let footOnlyLift = PMXFullStageGroundingPolicy.offset(
    rootMotionEnabled: false,
    animatedOffset: contactFootOffset
)
check(footOnlyLift == 0, "kneeling pose: foot-only policy never lifts the body")
let bodyPenetration: Float = -0.2445
let contactLift = max(0, PMXContactGrounding.penetrationOffset(
    restGlobalMinY: 0,
    animatedGlobalMinY: bodyPenetration
))
check(abs(contactLift - 0.2445) < 0.0001,
      "whole-body contact lifts exactly the penetrated depth")
let groundedBodyY = bodyPenetration + contactLift
check(groundedBodyY >= -0.0001,
      "after whole-body compensation the lowest vertex is at or above the floor")
// 负对照：只取脚时最低顶点仍在地面以下（这条必须在脚-only 修复下红）。
check(bodyPenetration + footOnlyLift < -0.0001,
      "negative control: foot-only grounding leaves the lowest non-foot vertex below the floor")
check(PMXContactGrounding.penetrationOffset(restGlobalMinY: 4, animatedGlobalMinY: 7) == -3,
      "contact offset is rest minus animated (body above rest is negative)")
check(PMXContactGrounding.penetrationOffset(restGlobalMinY: .nan, animatedGlobalMinY: 1) == 0,
      "non-finite contact reference refuses compensation")

print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) avatar grounding checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
"""#

let program = harness
    .replacingOccurrences(of: "__PMX_ANIMATED_GROUNDING__",
                          with: declaration("enum PMXAnimatedGrounding", in: pmx))
    .replacingOccurrences(of: "__PMX_CONTACT_GROUNDING__",
                          with: declaration("enum PMXContactGrounding", in: pmx))
    .replacingOccurrences(of: "__PMX_FULL_STAGE_GROUNDING__",
                          with: declaration("enum PMXFullStageGroundingPolicy", in: pmx))
    .replacingOccurrences(of: "__MARBLE_FRAMING__",
                          with: declaration("enum MarblePMXFraming", in: marble))

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-avatar-grounding-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let sourceURL = temporary.appendingPathComponent("main.swift")
try program.write(to: sourceURL, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("grounding")

let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compile.arguments = ["swiftc", "-swift-version", "6", sourceURL.path, "-o", executable.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    print("FAIL: grounding harness did not compile")
    exit(compile.terminationStatus)
}

let run = Process()
run.executableURL = executable
try run.run()
run.waitUntilExit()

// 3) installMotion 的残留偏移检查（在纯逻辑检查之后，保证两条信息都能看到）。
if !installMotion.contains("localGroundingOffsetY = 0") {
    print("FAIL: installMotion keeps the previous clip's grounding offset into the new motion")
    exit(1)
}
print("PASS: installMotion clears the previous clip's grounding offset")

// 4) 全身接触项必须真的接在每帧接地计算里，而不只是"存在一个纯逻辑枚举"。
let groundingUpdate = declaration("private func updateAnimatedGroundingOffset(", in: pmx)
guard groundingUpdate.contains("PMXContactGrounding.penetrationOffset"),
      groundingUpdate.contains("max(soleOffset, rootDrop, contactLift)") else {
    print("FAIL: updateAnimatedGroundingOffset no longer folds whole-body contact into the offset")
    exit(1)
}
print("PASS: per-frame grounding folds whole-body contact into the offset")
// 注入负对照：把接触项抽掉之后，判据必须能看出差别（只取脚 = 穿地）。
let injectedFootOnly = groundingUpdate.replacingOccurrences(
    of: "contactLift = max(0, PMXContactGrounding.penetrationOffset(",
    with: "contactLift = 0 // injected foot-only"
)
guard injectedFootOnly != groundingUpdate,
      !injectedFootOnly.contains("PMXContactGrounding.penetrationOffset") else {
    print("FAIL: whole-body contact injection negative control did not take")
    exit(1)
}
print("PASS: whole-body contact injection negative control (foot-only) changes the source")
exit(run.terminationStatus)
