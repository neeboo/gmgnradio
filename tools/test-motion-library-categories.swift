// Compile with Presence/MotionLibraryCategory.swift; no app, user data or GPU.
import Foundation

@main struct MotionCategoryChecks {
    static func main() throws {
        let fixture = URL(fileURLWithPath: "tools/motion/fixtures/bones-arpg.json")
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        let motions = data["motions"] as! [[String: Any]]
        let lifeGroups = Set(["拾取交互", "持物交互", "放置交互"])
        let dramaGroups = Set(["战斗闪避", "战斗姿态移动", "徒手攻击", "受击倒地", "跌倒与起身"])
        var counts: [MotionLibraryCategory: Int] = [:]
        for motion in motions {
            let key = motion["key"] as! String
            let group = motion["category"] as! String
            let expected: MotionLibraryCategory
            if key.hasPrefix("interact-button-") { expected = .work }
            else if key.hasPrefix("interact-door-") || ["idle-neutral", "idle-staggered"].contains(key)
                || lifeGroups.contains(group) { expected = .life }
            else if ["idle-alert", "alert-enter"].contains(key) || dramaGroups.contains(group) { expected = .drama }
            else { expected = .exercise }
            for format in ["pmx", "vrm"] {
                precondition(MotionLibraryCategory.category(forMotionID: "gmgn.motion.bones.arpg.\(key)-\(format)") == expected,
                             "wrong category: \(key)-\(format)")
            }
            counts[expected, default: 0] += 1
        }
        precondition(counts == [.life: 22, .work: 2, .exercise: 122, .drama: 23])
        for (key, expected) in ["thinking-loop": MotionLibraryCategory.work, "idle-loop": .life,
            "hold-display": .life, "jumping-jacks": .exercise, "walk-loop": .exercise,
            "coffee-button": .life, "chair-sit-loop": .life, "cross-legged-loop": .life, "kneeling-loop": .life] {
            precondition(MotionLibraryCategory.category(forMotionID: "gmgn.motion.bones.\(key)-pmx") == expected)
        }
        precondition(MotionLibraryCategory.allCases.map(\.title) == ["生活", "工作", "运动", "戏剧"])
        for id in ["custom.thinking-pmx", "gmgn.motion.bones.arpg.unknown-pmx", "gmgn.motion.bones.arpg.idle-neutral-fbx"] {
            precondition(MotionLibraryCategory.category(forMotionID: id) == nil, "unknown assets must not get fabricated categories")
        }
        print("PASS: all 169 ARPG source entries in both formats, 9 resident keys, four category order and unknown-ID boundaries")
    }
}
