// 离线探针：真机 PMX → MMDSceneKit 节点树 → 挂点候选骨名到底找不找得到。
//
// 只读。不启动 app，不写任何文件。
//
// 用法：
//   swift run pmx-node-probe            # 用真机那份 PMX
//   swift run pmx-node-probe <path.pmx>

import Foundation
import SceneKit
import MMDSceneKit

let defaultPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/gmgn radio/PresencePackages/pmx.2b-miss-0414-standard/na_2b_0414.pmx")
    .path
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultPath
let url = URL(fileURLWithPath: path)

guard let source = MMDSceneSource(url: url), let model = source.getModel() else {
    print("FAIL: 读不出 PMX：\(path)")
    exit(1)
}

// ---- 1. 真节点树里到底有哪些名字 ------------------------------------------
var allNames: [String] = []
var bonesUnderRoot: [String] = []
model.enumerateChildNodes { node, _ in
    if let name = node.name { allNames.append(name) }
}
if let rootBone = model.childNode(withName: "rootBone", recursively: true) {
    rootBone.enumerateChildNodes { node, _ in
        if let name = node.name { bonesUnderRoot.append(name) }
    }
}

print("PMX               : \(path)")
print("模型节点 name      : \(model.name ?? "nil")")
print("模型节点类         : \(type(of: model))")
print("全部后代节点数      : \(allNames.count)")
print("rootBone 下骨节点数 : \(bonesUnderRoot.count)")
print()
print("== rootBone 下的骨名（前 40）==")
for (index, name) in bonesUnderRoot.prefix(40).enumerated() {
    print(String(format: "  [%3d] %@", index, name))
}
print()
print("== rootBone 下的骨名（后 10）==")
for (index, name) in bonesUnderRoot.suffix(10).enumerated() {
    print(String(format: "  [%3d] %@", bonesUnderRoot.count - 10 + index, name))
}
print()

// ---- 2. 挂点表的候选骨名逐条用**生产那一行代码**去查 ----------------------
// 与 `PMXStageAvatarRenderer.validateAttachmentPoint` 同一个调用：
//   modelNode.childNode(withName: name, recursively: true)
let candidates: [String: [String]] = [
    "rightHand": ["右手首", "bone009"],
    "back": ["上半身2", "bone002", "上半身", "bone001"],
    "waist": ["腰", "下半身", "bone014", "センター", "bone000"],
]
var slotWithoutAHit: [String] = []
for slot in ["rightHand", "back", "waist"] {
    print("== 挂点 \(slot) ==")
    var hit = false
    for name in candidates[slot]! {
        let node = model.childNode(withName: name, recursively: true)
        if node != nil { hit = true }
        let kind = node.map { String(describing: type(of: $0)) } ?? "-"
        print("  \(node == nil ? "MISSING" : "FOUND  ")  \(name)\(node == nil ? "" : "  (\(kind))")")
    }
    // 判据与生产同一条：`validateAttachmentPoint` 要的是"候选里**至少一条**找得到"，
    // 不是"每条都找得到"（`boneNNN` 那一代匿名骨名在这份模型上本来就不该有）。
    if !hit { slotWithoutAHit.append(slot) }
    print("  → 至少一条命中：\(hit)（这就是 `validateAttachmentPoint` 的判据）")
    print()
}

// ---- 3. `acceptsAttachmentRig` 的三根标准骨 --------------------------------
let rigRequired = ["センター", "上半身", "右手首"]
let rigOK = rigRequired.allSatisfy { model.childNode(withName: $0, recursively: true) != nil }
print("acceptsAttachmentRig(センター/上半身/右手首 全在) = \(rigOK)")
print()

// ---- 4. 关键骨的世界/局部静止坐标（证明找到的是**那根**骨，不是同名的别的东西）--
func localPosition(_ name: String) -> String {
    guard let node = model.childNode(withName: name, recursively: true) else { return "MISSING" }
    let p = node.simdPosition
    return String(format: "局部 (x=%.4f, y=%.4f, z=%.4f)", p.x, p.y, p.z)
}
for name in ["センター", "腰", "上半身", "上半身2", "下半身", "右手首", "左手首"] {
    print(String(format: "  %-8@ %@", name as NSString, localPosition(name)))
}
print()
print(slotWithoutAHit.isEmpty
      ? "RESULT: 三个挂点各自都至少有一条候选骨名在真节点树里找得到（MISSING 的那些是另一代骨架 boneNNN 的兜底，这份模型本来就没有）"
      : "RESULT: 这些挂点在真节点树里一条候选都找不到：\(slotWithoutAHit.joined(separator: ", "))")
