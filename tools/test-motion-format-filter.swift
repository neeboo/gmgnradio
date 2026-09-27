// Hostless red/green checks for the motion format filter: the single rule
// that decides which installed motions a character's bone engine can play.
// No app, no AppKit, no user data.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let harness = #"""
import Foundation

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

private struct FixtureMotion {
    let id: String
    let format: MotionFormatFilter.Format
}
extension FixtureMotion: MotionLibraryFiltering {
    var libraryMotionID: String { id }
    var boneFormat: MotionFormatFilter.Format { format }
}

@MainActor func run() {
    let vrma = FixtureMotion(id: "dance.vrma", format: .vrma)
    let vmd = FixtureMotion(id: "bow.vmd", format: .vmd)
    let idle = FixtureMotion(id: "natural.idle", format: .procedural)
    let installed = [vrma, vmd, idle]

    // 1. PMX plays VMD and procedural only; VRMA is hidden, not deleted.
    let pmxList = MotionFormatFilter.available(installed, engine: .pmx)
    check(pmxList.map(\.id) == ["bow.vmd", "natural.idle"],
        "PMX keeps VMD and procedural in installation order, hides VRMA")

    // 2. VRM shows its native VRMA + procedural; VMD stays installed but is
    //    PMX's list content — the playback adapter must not duplicate it here.
    check(MotionFormatFilter.available(installed, engine: .vrm).map(\.id)
        == ["dance.vrma", "natural.idle"],
        "VRM keeps VRMA and procedural, hides VMD")

    // 3. Live2D, orb and no-character see nothing.
    check(MotionFormatFilter.available(installed, engine: .live2D).isEmpty,
        "Live2D sees no bone motions")
    check(MotionFormatFilter.available(installed, engine: .orb).isEmpty,
        "orb sees no bone motions")
    check(MotionFormatFilter.available(installed, engine: .unspecified).isEmpty,
        "no character sees no bone motions")

    // 4. The rule is the metadata pair, not a filename suffix, and it is
    //    native-format: adapter playability does not leak into the list.
    check(!MotionFormatFilter.isNativeFormat(engine: .pmx, format: .vrma),
        "PMX x VRMA is incompatible by format metadata")
    check(MotionFormatFilter.isNativeFormat(engine: .pmx, format: .vmd),
        "PMX x VMD is compatible")
    check(MotionFormatFilter.isNativeFormat(engine: .vrm, format: .vrma)
        && MotionFormatFilter.isNativeFormat(engine: .vrm, format: .procedural),
        "VRM x VRMA and procedural are compatible")
    check(!MotionFormatFilter.isNativeFormat(engine: .vrm, format: .vmd),
        "VRM x VMD is adapter playback only, never a list entry")

    // 4b. Catalog format strings map to the same native rule.
    check(MotionFormatFilter.native(catalogFormat: "vrma") == .vrma
        && MotionFormatFilter.native(catalogFormat: "vmd") == .vmd,
        "catalog format strings map to native formats")
    check(MotionFormatFilter.native(catalogFormat: "spine") == nil,
        "unknown catalog formats are filtered out")

    // 5. Notices explain an empty list only when motions exist at all.
    check(MotionFormatFilter.unavailableNotice(engine: .vrm, installedCount: 3) == nil,
        "VRM list has no notice")
    check(MotionFormatFilter.unavailableNotice(engine: .pmx, installedCount: 3) == nil,
        "PMX list has no notice")
    check(MotionFormatFilter.unavailableNotice(engine: .live2D, installedCount: 3)?
        .contains("Live2D") == true, "Live2D explains itself")
    check(MotionFormatFilter.unavailableNotice(engine: .orb, installedCount: 3)?
        .contains("VRM 或 PMX") == true, "orb points at VRM/PMX")
    check(MotionFormatFilter.unavailableNotice(engine: .unspecified, installedCount: 3)?
        .contains("VRM 或 PMX") == true, "no character points at VRM/PMX")
    check(MotionFormatFilter.unavailableNotice(engine: .orb, installedCount: 0) == nil,
        "an empty library keeps the plain empty state, no format notice")

    // 6. Library categories compose after the native-format filter. Fixture ids
    //    are real BONES keys so the mapping is exercised for real.
    let library: [FixtureMotion] = [
        FixtureMotion(id: "gmgn.motion.bones.arpg.interact-button-mid-vrm", format: .vrma), // 工作
        FixtureMotion(id: "gmgn.motion.bones.coffee-button-pmx", format: .vmd),             // 生活
        FixtureMotion(id: "gmgn.motion.bones.walk-loop-pmx", format: .vmd),                 // 运动
        FixtureMotion(id: "natural.idle", format: .procedural),                              // 未归类
    ]
    check(MotionFormatFilter.libraryList(library, engine: .pmx, category: nil).map(\.id)
        == ["gmgn.motion.bones.coffee-button-pmx", "gmgn.motion.bones.walk-loop-pmx", "natural.idle"],
        "全部 keeps unclassified and non-BONES entries after the format filter")
    check(MotionFormatFilter.libraryList(library, engine: .pmx, category: .life).map(\.id)
        == ["gmgn.motion.bones.coffee-button-pmx"], "生活 picks the coffee-button PMX entry")
    check(MotionFormatFilter.libraryList(library, engine: .pmx, category: .exercise).map(\.id)
        == ["gmgn.motion.bones.walk-loop-pmx"], "运动 picks the walk-loop PMX entry")
    check(MotionFormatFilter.libraryList(library, engine: .pmx, category: .drama).isEmpty,
        "an empty category under a character is a clean empty state")
    check(MotionFormatFilter.libraryList(library, engine: .vrm, category: .work).map(\.id)
        == ["gmgn.motion.bones.arpg.interact-button-mid-vrm"],
        "VRM x 工作 shows the VRMA BONES entry")
    check(MotionFormatFilter.libraryList(library, engine: .vrm, category: nil).map(\.id)
        == ["gmgn.motion.bones.arpg.interact-button-mid-vrm", "natural.idle"],
        "switching character changes which categories have content (format ∩ category)")

    // 7. Unknown or non-BONES ids are unclassified: visible in 全部 only.
    check(MotionLibraryCategory.category(forMotionID: "natural.idle") == nil,
        "procedural built-ins are unclassified")
    check(MotionLibraryCategory.category(forMotionID: "gmgn.motion.bones.future-key-vrm") == nil,
        "unmapped BONES keys are unclassified, never guessed")
    check(MotionFormatFilter.libraryList(library, engine: .pmx, category: .life)
        .contains(where: { $0.id == "natural.idle" }) == false,
        "unclassified entries stay out of specific categories")
}

@main struct Tests {
    @MainActor static func main() {
        run()
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) motion format filter checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-motion-filter-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("motion-filter")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
process.arguments = ["-j1", "-parse-as-library",
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/MotionFormatFilter.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/MotionLibraryCategory.swift").path,
    program.path, "-o", executable.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
let test = Process()
test.executableURL = URL(fileURLWithPath: executable.path)
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)
