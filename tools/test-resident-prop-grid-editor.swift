import Foundation

// 摆放格子映射层的离线验证。
//
// 只编译三个纯逻辑文件（Foundation + simd），**不编译 WorldRuntime**：这些映射里最容易错的
// 是"半格偏移加了几次""层号有没有串""footprint 是不是整块着色"，它们与几何无关。
let mappingFile = "apps/macos/Sources/GMGNRadio/Presence/PropSupportGridMapping.swift"
let presentationFile = "apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPresentation.swift"
let pickerFile = "apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPicker.swift"

let mappingSource = try String(contentsOfFile: mappingFile, encoding: .utf8)
let presentationSource = try String(contentsOfFile: presentationFile, encoding: .utf8)
let pickerSource = try String(contentsOfFile: pickerFile, encoding: .utf8)
guard mappingSource.contains("enum PropSupportGridMapping") else { print("FAIL: grid mapping missing"); exit(1) }
guard presentationSource.contains("enum PropSupportGridPresentation") else { print("FAIL: grid presentation missing"); exit(1) }
guard pickerSource.contains("enum PropSupportGridPicker") else { print("FAIL: grid picker missing"); exit(1) }
// 映射层必须保持可离线验证：不许引入 WorldRuntime（那会让这条 harness 需要编译整个包）。
let mappingImports = mappingSource.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
guard mappingImports.allSatisfy({ $0 == "" || !$0.hasPrefix("import ") || $0 == "import Foundation" || $0 == "import simd" }) else {
    print("FAIL: grid mapping must only import Foundation and simd"); exit(1) }

let harness = #"""
import Foundation
import simd
func check(_ value: Bool, _ message: String) { if !value { print("FAIL:", message); exit(1) } }
func near(_ a: Float, _ b: Float, _ tolerance: Float = 0.00001) -> Bool { abs(a - b) <= tolerance }
@main struct Checks {
    static func main() throws {
        let spacing: Float = 0.25

        // ── 列号 → 世界最小角；只在这里换算一次 ─────────────────────────────
        let origin00 = PropSupportGridMapping.columnWorldOrigin(columnX: 0, columnZ: 0, spacing: spacing)
        check(near(origin00.x, 0) && near(origin00.y, 0), "column 0 sits at the world origin")
        let origin42 = PropSupportGridMapping.columnWorldOrigin(columnX: 4, columnZ: -2, spacing: spacing)
        check(near(origin42.x, 1.0) && near(origin42.y, -0.5), "column world origin is column times spacing")
        let originNeg = PropSupportGridMapping.columnWorldOrigin(columnX: -1, columnZ: 0, spacing: spacing)
        check(near(originNeg.x, -0.25), "negative columns stay negative (no clamping or rounding)")

        // ── 映射成呈现格子：填的是【最小角】，格心由呈现层自己加半格 ──────────
        let input = PropSupportGridMapping.LayerInput(
            columnX: 4, columnZ: 2, layer: 0, supportHeight: 0.5, spacing: spacing)
        let cells = PropSupportGridMapping.presentationCells([input])
        check(cells.count == 1, "one layer maps to one cell")
        let cell = cells[0]
        check(near(cell.columnXWorld, 1.0) && near(cell.columnZWorld, 0.5),
              "mapping fills the column minimum corner, not the cell centre")
        check(near(cell.supportHeight, 0.5), "support height is carried through")
        // 关键：半格只能加一次。呈现层的 worldCenter 加半格之后必须正好是格心。
        let centre = cell.worldCenter(spacing: spacing)
        check(near(centre.x, 1.125) && near(centre.z, 0.625),
              "cell centre is the minimum corner plus exactly one half cell")
        check(near(centre.y, 0.5), "cell centre keeps the support height")
        // 吸附位置必须与呈现层的格心一致 —— 两处都加半格，不允许其中一处加两次。
        let snapped = PropSupportGridMapping.snappedPlacementPosition(
            columnX: 4, columnZ: 2, spacing: spacing, supportHeight: 0.5)
        check(near(snapped.x, centre.x) && near(snapped.y, centre.y) && near(snapped.z, centre.z),
              "snapped placement equals the presentation centre")

        // ── 顺序与多层 ────────────────────────────────────────────────────
        let stacked = [
            PropSupportGridMapping.LayerInput(columnX: 0, columnZ: 0, layer: 0, supportHeight: 0, spacing: spacing),
            PropSupportGridMapping.LayerInput(columnX: 0, columnZ: 0, layer: 1, supportHeight: 0.75, spacing: spacing),
            PropSupportGridMapping.LayerInput(columnX: 1, columnZ: 0, layer: 0, supportHeight: 0, spacing: spacing),
        ]
        let stackedCells = PropSupportGridMapping.presentationCells(stacked)
        check(stackedCells.count == 3, "every layer maps, not just the first per column")
        check(stackedCells.map(\.layer) == [0, 1, 0], "mapping preserves input order and layer numbers")
        check(near(stackedCells[1].supportHeight, 0.75), "a stacked layer keeps its own height")

        // ── 拾取候选 ──────────────────────────────────────────────────────
        let candidates = PropSupportGridMapping.pickerCandidates(stacked)
        check(candidates.count == 3, "every layer becomes a pick candidate")
        check(candidates[1].columnX == 0 && candidates[1].columnZ == 0
                && candidates[1].layer == 1 && near(candidates[1].supportHeight, 0.75),
              "pick candidate carries column, layer and height")

        // ── footprint 整块着色 ────────────────────────────────────────────
        let anchor = PropSupportGridMapping.LayerInput(
            columnX: 2, columnZ: 2, layer: 0, supportHeight: 0, spacing: spacing)
        let otherLayer = PropSupportGridMapping.LayerInput(
            columnX: 2, columnZ: 2, layer: 1, supportHeight: 0.75, spacing: spacing)
        let outside = PropSupportGridMapping.LayerInput(
            columnX: 9, columnZ: 9, layer: 0, supportHeight: 0, spacing: spacing)
        let stateCells = PropSupportGridMapping.presentationCells([anchor, otherLayer, outside])
        let covered: Set<PropSupportGridMapping.ColumnKey> = [
            .init(x: 2, z: 2), .init(x: 3, z: 2), .init(x: 2, z: 3), .init(x: 3, z: 3),
        ]
        let valid = PropSupportGridMapping.footprintStates(
            cells: stateCells, coveredColumns: covered, anchorLayer: 0, isFootprintValid: true)
        check(valid.count == 1, "only cells of the anchor layer inside the footprint are coloured")
        check(valid[stateCells[0]] == .validFootprint, "the anchored cell turns valid")
        check(valid[stateCells[1]] == nil, "a stacked layer in the same column is not coloured")
        check(valid[stateCells[2]] == nil, "a cell outside the footprint is not coloured")
        let invalid = PropSupportGridMapping.footprintStates(
            cells: stateCells, coveredColumns: covered, anchorLayer: 0, isFootprintValid: false)
        check(invalid[stateCells[0]] == .invalidFootprint, "an invalid footprint colours the cell red")
        check(PropSupportGridMapping.footprintStates(
            cells: stateCells, coveredColumns: [], anchorLayer: 0, isFootprintValid: true).isEmpty,
              "no covered columns means no footprint colouring")
        // 整块 footprint：覆盖的每一列都必须被着色，而不是只有锚点那一格。
        let wide = PropSupportGridMapping.presentationCells(
            covered.map { PropSupportGridMapping.LayerInput(
                columnX: $0.x, columnZ: $0.z, layer: 0, supportHeight: 0, spacing: spacing) })
        let wideStates = PropSupportGridMapping.footprintStates(
            cells: wide, coveredColumns: covered, anchorLayer: 0, isFootprintValid: true)
        check(wideStates.count == 4, "the whole footprint lights up, not just its anchor cell")
        check(wideStates.values.allSatisfy { $0 == .validFootprint }, "the whole footprint shares one verdict")

        // ── 90° 步进旋转 ──────────────────────────────────────────────────
        check(near(PropSupportGridMapping.yaw(rotatedBySteps: 1, from: 0), Float.pi / 2), "one step is 90 degrees")
        check(near(PropSupportGridMapping.yaw(rotatedBySteps: 2, from: 0), Float.pi), "two steps is 180 degrees")
        check(near(PropSupportGridMapping.yaw(rotatedBySteps: 3, from: 0), Float.pi * 1.5), "three steps is 270 degrees")
        check(near(PropSupportGridMapping.yaw(rotatedBySteps: 4, from: 0), 0), "four steps returns to the start")
        check(near(PropSupportGridMapping.yaw(rotatedBySteps: -1, from: 0), Float.pi * 1.5),
              "a negative step wraps instead of going negative")
        check(near(PropSupportGridMapping.normalizedYaw(-Float.pi / 2), Float.pi * 1.5),
              "negative yaw normalises into [0, 2pi)")
        // 反复累加不会漂成大数。
        var yaw: Float = 0
        for _ in 0..<1000 { yaw = PropSupportGridMapping.yaw(rotatedBySteps: 1, from: yaw) }
        check(yaw >= 0 && yaw < Float.pi * 2 && near(yaw, 0), "a thousand quarter turns stays normalised")
        check(PropSupportGridMapping.normalizedYaw(.nan) == 0, "non-finite yaw falls back to zero")

        print("PASS: 30 grid mapping checks, 0 failures")
    }
}
"""#

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-grid-editor-\(UUID())")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let file = temp.appendingPathComponent("main.swift"), exe = temp.appendingPathComponent("check")
try harness.write(to: file, atomically: true, encoding: .utf8)

func run(_ path: String, _ args: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
let result = try run("/usr/bin/nice", ["-n", "15", "/usr/bin/swiftc", "-j1", "-parse-as-library",
                                       mappingFile, presentationFile, pickerFile, file.path, "-o", exe.path])
guard result == 0 else { exit(result) }
exit(try run(exe.path, []))
