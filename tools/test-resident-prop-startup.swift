// Exercise the claimed-prop launch recovery decision without Metal, AppKit or a host.
//
// At launch the MarbleSpatialView installs the resident-prop handlers on its
// first eligible draw. synchronizeOwnedResidentProps used to call
// prepareResidentProp immediately, so the store threw renderUnavailable
// ("请重新进入空间") although the claimed task, ownership and model records
// were intact. The recovery entry must query readiness, defer silently while
// the renderer is still assembling, and let the existing refreshWishMachine
// cycle retry. Losing render ownership or cancellation during prepare is not
// an asset error; real corruption/dimension/GPU-budget failures still report.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func source(_ relativePath: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}
let storeSource = try source("apps/macos/Sources/GMGNRadio/VisualEngine/SpatialStageStore.swift")
let descriptorSource = try source("apps/macos/Sources/GMGNRadio/Presence/WishMachineOutputDescriptor.swift")
let appSource = try source("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")

/// Extract a top-level declaration by matching braces so the test compiles the
/// real production text rather than a copy.
func declaration(_ signature: String, in text: String) -> String {
    guard let start = text.range(of: signature)?.lowerBound,
          let open = text[start...].firstIndex(of: "{") else {
        fatalError("missing declaration: \(signature)")
    }
    var depth = 0
    for index in text[open...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("unbalanced declaration: \(signature)")
}

func require(_ value: Bool, _ message: String) {
    if !value {
        print("FAIL: \(message)")
        exit(1)
    }
}

// Production wiring: the recovery entry checks readiness before preparing and
// classifies the caught error, and no new polling is introduced.
require(storeSource.contains("func canPrepareResidentProp(worldID: String) -> Bool"),
        "spatial store must expose an explicit resident-prop readiness query")
let sync = declaration("private func synchronizeOwnedResidentProps()", in: appSource)
require(sync.contains("spatialStage.canPrepareResidentProp(worldID:"),
        "claimed-prop recovery must check renderer readiness before prepare")
require(sync.contains("ResidentPropStartupRecovery.action("),
        "claimed-prop recovery must classify prepare failures")
require(sync.contains("case .ignoreRendererLoss"),
        "recovery must ignore renderer loss/cancellation instead of reporting it")
require(!sync.contains("rendererReady: false"),
        "caught prepare failures must be classified with the live renderer readiness, not a hardcoded false")
require(sync.contains("try await spatialStage.prepareResidentProp(descriptor)"),
        "ready recovery must still prepare the claimed prop")
if let ready = sync.range(of: "canPrepareResidentProp")?.lowerBound,
   let assign = sync.range(of: "residentOwnedPropAssets[job.objectID] =")?.lowerBound {
    require(ready < assign, "readiness deferral must happen before any ownership record is written")
} else {
    require(false, "recovery must both query readiness and record ownership")
}
let scheduling = declaration("private func startResidentLoopScheduling()", in: appSource)
require(scheduling.contains("try await Task.sleep(for: .seconds(5))"),
        "the existing 5s cycle must still drive recovery")
require(scheduling.contains("await refreshWishMachine()"),
        "the existing cycle must call refreshWishMachine so readiness is retried")
require(!sync.contains("Task.sleep"),
        "recovery must not add its own polling loop")

let harness = #"""
import Foundation

\#(declaration("enum WishMachineOutputError", in: descriptorSource))

\#(declaration("enum ResidentPropStartupRecovery", in: storeSource))

struct CorruptLocalAsset: LocalizedError {
    var errorDescription: String? {
        "已领取物件的本地文件缺失或校验失败，没有删除或重新生成，请检查许愿任务。"
    }
}

@main struct Check {
    static func main() {
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(message)") }
        }

        // Readiness query: only a visible world whose renderer published both
        // handlers for the selected world may attempt a prepare.
        func ready(isWorldVisible: Bool = true, hasActiveRenderer: Bool = true,
                   selectedWorldID: String? = "wish.machine",
                   descriptorWorldID: String = "wish.machine",
                   hasPrepareHandler: Bool = true) -> Bool {
            ResidentPropStartupRecovery.canPrepare(
                isWorldVisible: isWorldVisible,
                hasActiveRenderer: hasActiveRenderer,
                selectedWorldID: selectedWorldID,
                descriptorWorldID: descriptorWorldID,
                hasPrepareHandler: hasPrepareHandler)
        }
        check(ready(), "selected visible world with both handlers is ready")
        check(!ready(isWorldVisible: false), "hidden world must defer")
        check(!ready(hasActiveRenderer: false), "renderer without ownership must defer")
        check(!ready(selectedWorldID: nil), "missing selected world must defer")
        check(!ready(descriptorWorldID: "other.world"), "world mismatch must defer")
        check(!ready(hasPrepareHandler: false), "missing prepare handler must defer")

        // Launch window: not-ready defers silently; ready retries.
        check(ResidentPropStartupRecovery.action(rendererReady: false, error: nil) == .deferUntilRendererReady,
              "unready renderer defers instead of failing the claimed prop")
        check(ResidentPropStartupRecovery.action(rendererReady: true, error: nil) == .prepare,
              "ready renderer prepares the claimed prop")

        // Losing render ownership / cancellation during prepare is not an asset error.
        check(ResidentPropStartupRecovery.action(rendererReady: true, error: CancellationError()) == .ignoreRendererLoss,
              "cancellation during prepare must be ignored")
        check(ResidentPropStartupRecovery.action(rendererReady: false, error: CancellationError()) == .ignoreRendererLoss,
              "cancellation while switching worlds must be ignored")
        check(ResidentPropStartupRecovery.action(rendererReady: false, error: WishMachineOutputError.renderUnavailable) == .ignoreRendererLoss,
              "renderer ownership loss must be ignored")
        check(ResidentPropStartupRecovery.action(rendererReady: true, error: WishMachineOutputError.renderUnavailable) ==
              .report(WishMachineOutputError.renderUnavailable.localizedDescription),
              "a ready renderer that still fails to prepare must report instead of being swallowed")

        // Real damage/dimension/GPU-budget failures stay reported.
        check(ResidentPropStartupRecovery.action(rendererReady: true, error: CorruptLocalAsset()) ==
              .report("已领取物件的本地文件缺失或校验失败，没有删除或重新生成，请检查许愿任务。"),
              "corrupt local asset must still report")
        for error: WishMachineOutputError in [.invalidAsset, .invalidDimensions, .textureBudget, .invalidTexture] {
            check(ResidentPropStartupRecovery.action(rendererReady: true, error: error) ==
                  .report(error.localizedDescription),
                  "\(error) must still report its real message")
        }
        check(ResidentPropStartupRecovery.action(rendererReady: true, error: CorruptLocalAsset()) !=
              .report(WishMachineOutputError.renderUnavailable.localizedDescription),
              "real failures must not be folded into the retry message")

        if failures == 0 { print("PASS: \(checks) claimed-prop startup recovery checks") }
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-prop-startup-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Check.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("check")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", "-parse-as-library", program.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
