// Run from the repository root: swift tools/test-space-presentation.swift
// Compiles the current production method bodies against inert view/render shims.
// No AppKit, application bundle, network, GPU, or test host is started.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceDirectory = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine")
let controllerSource = try String(contentsOf: sourceDirectory.appendingPathComponent("StageWindowController.swift"), encoding: .utf8)
let storeSource = try String(contentsOf: sourceDirectory.appendingPathComponent("SpatialStageStore.swift"), encoding: .utf8)

// Extract declarations unchanged, including their implementation. Braces in these
// declarations are balanced; extraction failures stop the test rather than pass.
func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else {
        fatalError("Missing production declaration: \(signature)")
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unbalanced production declaration: \(signature)")
}

let storeMethods = [
    "func requestWorldPresentation()", "func finishWorldPresentation()",
    "func exitWorld()", "func observeWorldVisibility(",
    "private func updateWorldVisibility(",
].map { declaration($0, in: storeSource) }.joined(separator: "\n")
let presentationMethod = declaration("private func applySpatialPresentation(", in: controllerSource)
let presentationState = declaration("struct StageSurfacePresentationState:", in: controllerSource)
let destinationContent = declaration("struct StageDestinationContent:", in: controllerSource)
let composerVisibility = declaration("private func updateResidentComposerVisibility()", in: controllerSource)
let composerFocus = declaration("private func residentComposerOwnsFirstResponder()", in: controllerSource)
let panelToggles = ["private func toggleResidentChat()", "private func toggleProgramRail()", "private func toggleVisualPicker()"].map {
    declaration($0, in: controllerSource)
}.joined(separator: "\n")

let harness = #"""
import Foundation
import os

final class StageWindowController {
    static let log = Logger(subsystem: "test.space-presentation", category: "controller")
}
class View {
    var isHidden = false
    weak var parent: View?
    var expanded = false
    var available = false
    func apply(_ content: StageDestinationContent) {}
    func setVisualPickerMode(_ mode: Bool) {}
    func setResidentChatExpanded(_ value: Bool) { expanded = value }
    func setResidentChatAvailable(_ value: Bool) { available = value }
    func setPropEditorAvailable(_ value: Bool) {}
    func setProgramRailExpanded(_ value: Bool) {}
    func setVisualPickerExpanded(_ value: Bool) {}
    func setProgramRailVisible(_ value: Bool) {}
    func isDescendant(of view: View) -> Bool { self === view || parent?.isDescendant(of: view) == true }
}
typealias NSView = View
final class NSTextView: View { weak var delegate: AnyObject? }
final class Window {
    var firstResponder: View?
    func makeFirstResponder(_ view: View) { firstResponder = view }
}
enum StageVisualPickerMode {
    static func resolve(isWorldPresentationRequested: Bool) -> Bool {
        isWorldPresentationRequested
    }
}
final class RenderSurface {
    var isWorldVisible = false
    func setWorldPresentationVisible(_ visible: Bool) { isWorldVisible = visible }
}
final class Store {
    final class RenderOwnership { func invalidate() {} }
    let residentPropRenderOwnership = RenderOwnership()
    var residentPropPreview: String?
    func clearResidentPropRendererHooks() {}
    static let log = Logger(subsystem: "test.space-presentation", category: "store")
    var isWorldPresentationRequested = false
    var isWorldVisible = false
    var selectedWorldID: String? = "gmgn-living-pod-v1"
    var isSpeedBoosted = false
    var worldVisibilityObservers: [UUID: (Bool) -> Void] = [:]
    func clearMovement() {}
    \#(storeMethods)
}

\#(presentationState)
\#(destinationContent)

final class Content {
    final class PropEditor { func close() {} }
    let residentPropEditor = PropEditor()
    let spatialStage: Store
    let renderSurfaceContainer = View()
    let metalView: View? = View()
    let worldInteractionView = View()
    let worldLoadingView = View()
    let destinationButton = View()
    let transportControls = View()
    let residentComposer = View()
    let programRail = View()
    let visualPicker = View()
    let overlayState = View()
    var isResidentChatExpanded = false
    var isProgramRailVisible = false
    var isVisualPickerVisible = false
    let window: Window? = Window()
    let renderSurfaceController = RenderSurface()
    var completesOnAttach = true
    init(_ store: Store) { spatialStage = store; residentComposer.isHidden = true }
    func attachRenderSurface() {
        if completesOnAttach { spatialStage.finishWorldPresentation() }
    }
    func receive(_ visible: Bool) { applySpatialPresentation(isWorldVisible: visible) }
    func refreshComposer() { updateResidentComposerVisibility() }
    func toggleChat() { toggleResidentChat() }
    func toggleSettings() { toggleVisualPicker() }
    func toggleTracks() { toggleProgramRail() }
    \#(presentationMethod)
    \#(composerVisibility)
    \#(composerFocus)
    \#(panelToggles)
}

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

// Install callbacks in the dictionary's actual traversal order, independent of
// randomized UUID hashes. Replacing values leaves its keys and layout intact.
for uiFirst in [true, false] {
    let store = Store()
    let content = Content(store)
    let firstID = store.observeWorldVisibility { _ in }
    let secondID = store.observeWorldVisibility { _ in }
    let ids = Array(store.worldVisibilityObservers.keys)
    let uiIndex = uiFirst ? 0 : 1
    var renderCache = false
    store.worldVisibilityObservers[ids[uiIndex]] = { content.receive($0) }
    store.worldVisibilityObservers[ids[1 - uiIndex]] = { renderCache = $0 }
    for visit in 1...2 {
        let label = "uiFirst=\(uiFirst) visit=\(visit)"
        store.requestWorldPresentation()
        check(store.isWorldVisible, "\(label): store is visible")
        check(!content.renderSurfaceContainer.isHidden, "\(label): world remains shown after synchronous attach")
        check(!content.worldInteractionView.isHidden, "\(label): world accepts input")
        check(content.worldLoadingView.isHidden, "\(label): loading indicator is hidden")
        check(content.renderSurfaceController.isWorldVisible, "\(label): render visibility is current")
        check(renderCache, "\(label): other observer does not retain stale false")
        store.exitWorld()
        check(!store.isWorldVisible && !renderCache, "\(label): exit reaches all observers")
        check(content.renderSurfaceContainer.isHidden, "\(label): exited world is hidden")
        check(content.worldLoadingView.isHidden, "\(label): exit does not leave loading")
    }
    // Remote/asynchronous loading must still show loading until finish arrives.
    content.completesOnAttach = false
    store.requestWorldPresentation()
    check(!content.worldLoadingView.isHidden, "pending load shows indicator")
    check(content.renderSurfaceContainer.isHidden, "pending load hides world")
    store.finishWorldPresentation()
    check(content.worldLoadingView.isHidden && !content.renderSurfaceContainer.isHidden,
          "asynchronous finish reveals world")
    check(content.residentComposer.isHidden, "composer defaults collapsed in entered space")
    content.toggleChat()
    check(!content.residentComposer.isHidden && content.transportControls.expanded, "chat button expands composer")
    let editor = NSTextView()
    let field = View()
    field.parent = content.residentComposer
    editor.delegate = field
    content.window?.firstResponder = editor
    content.receive(true)
    check(content.window?.firstResponder === editor, "world refresh preserves focused text editor")
    content.toggleSettings()
    check(content.residentComposer.isHidden, "settings panel does not overlap resident composer")
    check(content.window?.firstResponder === content.worldInteractionView, "hidden composer releases text focus")
    let settingsEditor = NSTextView()
    content.window?.firstResponder = settingsEditor
    content.receive(true)
    check(content.window?.firstResponder === settingsEditor, "refresh does not steal settings text focus")
    content.toggleSettings()
    check(content.residentComposer.isHidden, "closing settings does not reopen chat")
    content.toggleChat()
    content.toggleChat()
    check(content.residentComposer.isHidden && content.window?.firstResponder === settingsEditor,
          "collapsing chat leaves unrelated editor focus untouched")
    content.toggleTracks()
    content.toggleChat()
    check(!content.residentComposer.isHidden && content.programRail.isHidden && content.visualPicker.isHidden,
          "opening chat closes existing panels")
    content.toggleTracks()
    check(content.residentComposer.isHidden && !content.isResidentChatExpanded, "opening tracks collapses chat")
    content.toggleChat()
    store.exitWorld()
    check(content.residentComposer.isHidden && !content.transportControls.available, "leaving space hides chat")
    check(content.window?.firstResponder === settingsEditor, "leaving space preserves unrelated input focus")
    content.toggleChat()
    check(content.residentComposer.isHidden, "player mode cannot expose space composer")
    _ = (firstID, secondID)
}
if failures > 0 { print("\(failures) assertions failed"); exit(1) }
print("PASS: both observer orders, initial entry, reentry, exit, and asynchronous loading")
"""#

func runHarness() throws -> Int32 {
    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-space-regression-\(UUID())")
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let harnessURL = temporaryDirectory.appendingPathComponent("main.swift")
    try harness.write(to: harnessURL, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [harnessURL.path]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
exit(try runHarness())
