import Foundation

@main struct UnityShortcutTests {
    @MainActor static func main() throws {
        let suite = "gmgn.unity.shortcuts.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var actions: [GMGNShortcutAction] = []
        let bridge = UnityShortcutSettingsBridge(defaults: defaults) { actions.append($0) }
        precondition(bridge.command(["op": "shortcuts.record", "id": "nextTrack", "scope": "global"]))
        precondition(!bridge.command(["op": "shortcuts.capture", "keyCode": 0, "keyLabel": "A", "modifiers": UInt(0)]))
        precondition(bridge.store.recordingTarget != nil)
        precondition(bridge.command(["op": "shortcuts.capture", "keyCode": 0, "keyLabel": "A", "modifiers": UInt(1)]))
        precondition(bridge.store.recordingTarget == nil)
        precondition(bridge.store.assignment(for: .nextTrack).global.keyCode == 0)
        precondition(!bridge.command(["op": "shortcuts.capture", "keyCode": 1, "keyLabel": "S", "modifiers": UInt(1)]))
        let restored = UnityShortcutSettingsBridge(defaults: defaults) { _ in }
        precondition(restored.store.assignment(for: .nextTrack).global.displayName == "⌘A")
        precondition(restored.store.action(matching: GMGNKeyCombination(keyCode: 0, keyLabel: "Different keyboard label", modifiers: .command), scope: .global) == .nextTrack)
        precondition(bridge.command(["op": "shortcuts.save", "globalEnabled": false, "mediaKeysEnabled": false]))
        precondition(!bridge.store.globalEnabled && !bridge.store.mediaKeysEnabled)
        precondition(bridge.command(["op": "shortcuts.reset"]))
        precondition(bridge.store.assignment(for: .nextTrack).global == GMGNShortcutAssignment.defaults.first(where: { $0.action == .nextTrack })!.global)
        precondition(!bridge.command(["op": "shortcuts.record", "id": "invalid", "scope": "local"]))
        precondition(actions.isEmpty) // Tests never register global/media hooks.
        precondition(bridge.updateTextInput(["focused": true, "composing": false]))
        precondition(bridge.updateTextInput(["focused": false, "composing": true]))
        precondition(bridge.updateTextInput(["focused": false, "composing": false]))
        precondition(!bridge.updateTextInput(["focused": true]))
        precondition(GMGNShortcutCoordinator.suppressKeyboardShortcuts(textInputActive: true, applicationActive: true))
        precondition(!GMGNShortcutCoordinator.suppressKeyboardShortcuts(textInputActive: true, applicationActive: false))
        precondition(!GMGNShortcutCoordinator.suppressKeyboardShortcuts(textInputActive: false, applicationActive: true))
        print("Unity shortcut isolation, validation, persistence, reset: passed")
    }
}
