import AppKit
import Foundation

/// Original shortcut authority with explicit Unity storage and action consumer.
/// GPUI records keys in its own process and forwards `shortcuts.capture`.
@MainActor
final class UnityShortcutSettingsBridge {
    let store: GMGNShortcutSettingsStore
    private let coordinator: GMGNShortcutCoordinator
    private var validationMessage: String?

    static let supportedCommands = ["shortcuts.record", "shortcuts.capture", "shortcuts.cancel", "shortcuts.reset", "shortcuts.save", "shortcuts.global", "shortcuts.media"]

    init(defaults: UserDefaults, performAction: @escaping @MainActor (GMGNShortcutAction) -> Void) {
        store = GMGNShortcutSettingsStore(defaults: defaults)
        coordinator = GMGNShortcutCoordinator(settings: store, performAction: performAction)
    }

    func start() { coordinator.start() }
    func stop() { coordinator.stop(); store.cancelRecording() }
    func updateTextInput(_ value: [String: Any]) -> Bool {
        guard let focused = value["focused"] as? Bool, let composing = value["composing"] as? Bool else { return false }
        coordinator.setTextInputActive(focused || composing)
        return true
    }

    var snapshot: [String: Any] {
        ["assignments": store.assignments.map {
            ["id": $0.action.rawValue, "title": $0.action.title,
             "local": $0.local.displayName, "global": $0.global.displayName]
        }, "globalEnabled": store.globalEnabled, "mediaKeysEnabled": store.mediaKeysEnabled,
         "recordingID": store.recordingTarget?.action.rawValue as Any? ?? NSNull(),
         "recordingScope": store.recordingTarget?.scope.rawValue as Any? ?? NSNull(),
         "validationMessage": validationMessage as Any? ?? NSNull(), "notice": NSNull()]
    }

    func command(_ value: [String: Any]) -> Bool {
        guard let op = value["op"] as? String else { return false }
        switch op {
        case "shortcuts.record":
            guard let id = value["id"] as? String, let action = GMGNShortcutAction(rawValue: id),
                  let raw = value["scope"] as? String, let scope = GMGNShortcutScope(rawValue: raw) else { return false }
            validationMessage = nil; store.beginRecording(action: action, scope: scope)
        case "shortcuts.capture":
            guard let target = store.recordingTarget,
                  let code = value["keyCode"] as? Int, (0...127).contains(code),
                  let label = value["keyLabel"] as? String, !label.isEmpty, label.count <= 20,
                  let flags = value["modifiers"] as? UInt, flags <= 15 else { return false }
            let modifiers = GMGNShortcutModifiers(rawValue: flags)
            guard target.scope != .global || !modifiers.isEmpty else {
                validationMessage = "全局快捷键至少需要一个修饰键。"; return false
            }
            store.assign(GMGNKeyCombination(keyCode: UInt16(code), keyLabel: label, modifiers: modifiers), to: target.action, scope: target.scope)
            validationMessage = nil
        case "shortcuts.cancel": store.cancelRecording(); validationMessage = nil
        case "shortcuts.reset": store.reset(); validationMessage = nil
        case "shortcuts.save":
            guard value["globalEnabled"] is Bool || value["mediaKeysEnabled"] is Bool else { return false }
            if let enabled = value["globalEnabled"] as? Bool { store.globalEnabled = enabled }
            if let enabled = value["mediaKeysEnabled"] as? Bool { store.mediaKeysEnabled = enabled }
        case "shortcuts.global", "shortcuts.media":
            guard let enabled = value["value"] as? Bool else { return false }
            if op == "shortcuts.global" { store.globalEnabled = enabled } else { store.mediaKeysEnabled = enabled }
        default: return false
        }
        return true
    }
}
