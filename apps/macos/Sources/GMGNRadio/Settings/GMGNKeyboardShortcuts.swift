import AppKit
import Carbon.HIToolbox
import Combine
import MediaPlayer
import SwiftUI

enum GMGNShortcutAction: String, CaseIterable, Codable, Sendable {
    case togglePlayback
    case previousTrack
    case nextTrack
    case volumeUp
    case volumeDown
    case toggleVoice
    case toggleStage
    case toggleLyrics

    var title: String {
        switch self {
        case .togglePlayback:
            "播放 / 暂停"
        case .previousTrack:
            "上一首"
        case .nextTrack:
            "下一首"
        case .volumeUp:
            "音量增加"
        case .volumeDown:
            "音量降低"
        case .toggleVoice:
            "开麦 / 关麦"
        case .toggleStage:
            "显示 / 隐藏舞台"
        case .toggleLyrics:
            "切换歌词视觉"
        }
    }
}

enum GMGNShortcutScope: String, Codable, Sendable {
    case local
    case global
}

struct GMGNShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt

    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var value: Self = []
        if eventFlags.contains(.control) {
            value.insert(.control)
        }
        if eventFlags.contains(.option) {
            value.insert(.option)
        }
        if eventFlags.contains(.shift) {
            value.insert(.shift)
        }
        if eventFlags.contains(.command) {
            value.insert(.command)
        }
        self = value
    }

    var displayPrefix: String {
        var result = ""
        if contains(.control) {
            result += "⌃"
        }
        if contains(.option) {
            result += "⌥"
        }
        if contains(.shift) {
            result += "⇧"
        }
        if contains(.command) {
            result += "⌘"
        }
        return result
    }

    var carbonFlags: UInt32 {
        var result: UInt32 = 0
        if contains(.command) {
            result |= UInt32(cmdKey)
        }
        if contains(.option) {
            result |= UInt32(optionKey)
        }
        if contains(.control) {
            result |= UInt32(controlKey)
        }
        if contains(.shift) {
            result |= UInt32(shiftKey)
        }
        return result
    }
}

struct GMGNKeyCombination: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt16
    let keyLabel: String
    let modifiers: GMGNShortcutModifiers

    var displayName: String {
        modifiers.displayPrefix + keyLabel
    }

    init(
        keyCode: UInt16,
        keyLabel: String,
        modifiers: GMGNShortcutModifiers
    ) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else {
            return nil
        }
        let label: String
        switch event.keyCode {
        case 49:
            label = "空格"
        case 123:
            label = "←"
        case 124:
            label = "→"
        case 125:
            label = "↓"
        case 126:
            label = "↑"
        default:
            guard
                let characters = event.charactersIgnoringModifiers,
                let character = characters.first,
                !character.isWhitespace,
                !character.isNewline
            else {
                return nil
            }
            label = String(character).uppercased()
        }
        self.init(
            keyCode: event.keyCode,
            keyLabel: label,
            modifiers: GMGNShortcutModifiers(
                eventFlags: event.modifierFlags
            )
        )
    }

    func matches(_ event: NSEvent) -> Bool {
        keyCode == event.keyCode
            && modifiers == GMGNShortcutModifiers(
                eventFlags: event.modifierFlags
            )
    }
}

struct GMGNShortcutAssignment: Codable, Equatable, Identifiable, Sendable {
    let action: GMGNShortcutAction
    var local: GMGNKeyCombination
    var global: GMGNKeyCombination

    var id: GMGNShortcutAction { action }

    static let defaults: [Self] = [
        Self(
            action: .togglePlayback,
            local: .init(keyCode: 49, keyLabel: "空格", modifiers: []),
            global: .init(
                keyCode: 35,
                keyLabel: "P",
                modifiers: [.option, .command]
            )
        ),
        Self(
            action: .previousTrack,
            local: .init(
                keyCode: 123,
                keyLabel: "←",
                modifiers: [.command]
            ),
            global: .init(
                keyCode: 123,
                keyLabel: "←",
                modifiers: [.option, .command]
            )
        ),
        Self(
            action: .nextTrack,
            local: .init(
                keyCode: 124,
                keyLabel: "→",
                modifiers: [.command]
            ),
            global: .init(
                keyCode: 124,
                keyLabel: "→",
                modifiers: [.option, .command]
            )
        ),
        Self(
            action: .volumeUp,
            local: .init(
                keyCode: 126,
                keyLabel: "↑",
                modifiers: [.command]
            ),
            global: .init(
                keyCode: 126,
                keyLabel: "↑",
                modifiers: [.option, .command]
            )
        ),
        Self(
            action: .volumeDown,
            local: .init(
                keyCode: 125,
                keyLabel: "↓",
                modifiers: [.command]
            ),
            global: .init(
                keyCode: 125,
                keyLabel: "↓",
                modifiers: [.option, .command]
            )
        ),
        Self(
            action: .toggleVoice,
            local: .init(
                keyCode: 46,
                keyLabel: "M",
                modifiers: [.command]
            ),
            global: .init(
                keyCode: 46,
                keyLabel: "M",
                modifiers: [.option, .command]
            )
        ),
        Self(
            action: .toggleStage,
            local: .init(
                keyCode: 3,
                keyLabel: "F",
                modifiers: [.control, .command]
            ),
            global: .init(
                keyCode: 1,
                keyLabel: "S",
                modifiers: [.option, .command]
            )
        ),
        Self(
            action: .toggleLyrics,
            local: .init(
                keyCode: 15,
                keyLabel: "R",
                modifiers: [.command]
            ),
            global: .init(
                keyCode: 15,
                keyLabel: "R",
                modifiers: [.option, .command]
            )
        ),
    ]
}

struct GMGNShortcutTarget: Equatable, Sendable {
    let action: GMGNShortcutAction
    let scope: GMGNShortcutScope
}

@MainActor
final class GMGNShortcutSettingsStore: ObservableObject {
    @Published private(set) var assignments: [GMGNShortcutAssignment]
    @Published private(set) var recordingTarget: GMGNShortcutTarget?
    @Published private var confirmedGlobalEnabled = false
    @Published private var confirmedMediaKeysEnabled = false
    @Published private(set) var settingsError: String?
    var globalEnabled: Bool {
        get { confirmedGlobalEnabled }
        set { submit(["kind":"globalEnabled", "enabled":newValue]) }
    }
    var mediaKeysEnabled: Bool {
        get { confirmedMediaKeysEnabled }
        set { submit(["kind":"mediaKeysEnabled", "enabled":newValue]) }
    }

    var onChange: (() -> Void)?

    private static let assignmentsKey = "gmgn.keyboardShortcuts.v1"
    private static let globalEnabledKey =
        "gmgn.keyboardShortcuts.globalEnabled"
    private static let mediaKeysEnabledKey =
        "gmgn.keyboardShortcuts.mediaKeysEnabled"
    private let settings: RustProductSettingsClient
    // Only initialized on MainActor; deinit removes the immutable Foundation token.
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, settings: RustProductSettingsClient = .shared) {
        self.settings = settings; assignments = []
        settings.bootstrap(legacy: RustProductSettingsClient.legacySnapshot(defaults))
        settingsObserver = NotificationCenter.default.addObserver(forName: .init("gmgnProductSettingsConfirmed"), object: settings, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.projectConfirmed() }
        }
        projectConfirmed()
        Task { [weak self] in
            guard let self else { return }
            do { try await settings.ensureLoaded(); projectConfirmed() }
            catch { settingsError = "快捷键设置暂时不可用。" }
        }
    }
    deinit { if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) } }
    private func projectConfirmed() {
        guard let value = settings.confirmed?.values,
              let data = try? JSONEncoder().encode(value.shortcutAssignments),
              let decoded = try? JSONDecoder().decode([GMGNShortcutAssignment].self, from: data) else { return }
        assignments = decoded; confirmedGlobalEnabled = value.globalShortcutsEnabled
        confirmedMediaKeysEnabled = value.mediaKeysEnabled; settingsError = nil; onChange?()
    }
    private func submit(_ event: [String: Any]) {
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await settings.shortcutEvent(event); projectConfirmed(); recordingTarget = nil }
            catch { settingsError = "快捷键设置保存失败。"; onChange?() }
        }
    }

    func assignment(
        for action: GMGNShortcutAction
    ) -> GMGNShortcutAssignment {
        assignments.first { $0.action == action }
            ?? GMGNShortcutAssignment.defaults.first {
                $0.action == action
            }!
    }

    func beginRecording(
        action: GMGNShortcutAction,
        scope: GMGNShortcutScope
    ) {
        recordingTarget = GMGNShortcutTarget(
            action: action,
            scope: scope
        )
        onChange?()
    }

    func cancelRecording() {
        recordingTarget = nil
        onChange?()
    }

    func assign(
        _ newCombination: GMGNKeyCombination,
        to action: GMGNShortcutAction,
        scope: GMGNShortcutScope
    ) {
        guard let data = try? JSONEncoder().encode(newCombination),
              let combination = try? JSONSerialization.jsonObject(with: data) else { return }
        submit(["kind":"assign", "action":action.rawValue, "scope":scope.rawValue, "combination":combination])
    }

    func reset() {
        submit(["kind":"reset"])
    }

    func action(
        matching combination: GMGNKeyCombination,
        scope: GMGNShortcutScope
    ) -> GMGNShortcutAction? {
        assignments.first {
            self.combination(for: $0, scope: scope).keyCode == combination.keyCode
                && self.combination(for: $0, scope: scope).modifiers == combination.modifiers
        }?.action
    }

    private func combination(
        for assignment: GMGNShortcutAssignment,
        scope: GMGNShortcutScope
    ) -> GMGNKeyCombination {
        scope == .local ? assignment.local : assignment.global
    }

}

private let gmgnGlobalHotKeySignature: OSType = 0x474D474E

@MainActor
final class GMGNShortcutCoordinator {
    private let settings: GMGNShortcutSettingsStore
    private let performAction: @MainActor (GMGNShortcutAction) -> Void
    private var localMonitor: Any?
    private var carbonEventHandler: EventHandlerRef?
    private var registeredHotKeys: [EventHotKeyRef] = []
    private var actionByHotKeyID: [UInt32: GMGNShortcutAction] = [:]
    private var mediaCommandTargets: [(MPRemoteCommand, Any)] = []
    private var textInputActive = false
    private var applicationObservers: [NSObjectProtocol] = []

    static func suppressKeyboardShortcuts(textInputActive: Bool, applicationActive: Bool) -> Bool {
        textInputActive && applicationActive
    }
    private var suppressKeyboardShortcuts: Bool {
        Self.suppressKeyboardShortcuts(textInputActive: textInputActive, applicationActive: NSApplication.shared.isActive)
    }
    func setTextInputActive(_ value: Bool) {
        guard textInputActive != value else { return }
        textInputActive = value
        if localMonitor != nil { refreshRegistrations() }
    }

    init(
        settings: GMGNShortcutSettingsStore,
        performAction: @escaping @MainActor (GMGNShortcutAction) -> Void
    ) {
        self.settings = settings
        self.performAction = performAction
    }

    func start() {
        guard localMonitor == nil else {
            return
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let combination = GMGNKeyCombination(event: event) else {
                return event
            }
            let handled = MainActor.assumeIsolated {
                guard let self else {
                    return false
                }
                guard self.settings.recordingTarget == nil else {
                    return false
                }
                guard !self.suppressKeyboardShortcuts else { return false }
                if NSApplication.shared.keyWindow?.firstResponder
                    is NSTextView
                {
                    return false
                }
                guard
                    let action = self.settings.action(
                        matching: combination,
                        scope: .local
                    )
                else {
                    return false
                }
                self.performAction(action)
                return true
            }
            return handled ? nil : event
        }
        settings.onChange = { [weak self] in
            self?.refreshRegistrations()
        }
        applicationObservers = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRegistrations() }
            }
        }
        refreshRegistrations()
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        settings.onChange = nil
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        applicationObservers.removeAll()
        textInputActive = false
        unregisterGlobalHotKeys()
        unregisterMediaCommands()
    }

    fileprivate func performGlobalHotKey(id: UInt32) {
        guard !suppressKeyboardShortcuts else { return }
        guard let action = actionByHotKeyID[id] else {
            return
        }
        performAction(action)
    }

    private func refreshRegistrations() {
        unregisterGlobalHotKeys()
        unregisterMediaCommands()
        // Carbon grabs keys before the Unity view receives them. Unregister while
        // this app edits text; restore on blur or switching to another app.
        if settings.globalEnabled && settings.recordingTarget == nil && !suppressKeyboardShortcuts {
            registerGlobalHotKeys()
        }
        if settings.mediaKeysEnabled {
            registerMediaCommands()
        }
    }

    private func registerGlobalHotKeys() {
        if carbonEventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let event, let userData else {
                        return OSStatus(eventNotHandledErr)
                    }
                    var hotKeyID = EventHotKeyID()
                    let status = GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                    )
                    guard status == noErr else {
                        return status
                    }
                    let coordinator = Unmanaged<GMGNShortcutCoordinator>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    Task { @MainActor in
                        coordinator.performGlobalHotKey(id: hotKeyID.id)
                    }
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &carbonEventHandler
            )
        }

        for (index, assignment) in settings.assignments.enumerated() {
            let id = UInt32(index + 1)
            let hotKeyID = EventHotKeyID(
                signature: gmgnGlobalHotKeySignature,
                id: id
            )
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(assignment.global.keyCode),
                assignment.global.modifiers.carbonFlags,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                registeredHotKeys.append(reference)
                actionByHotKeyID[id] = assignment.action
            }
        }
    }

    private func unregisterGlobalHotKeys() {
        registeredHotKeys.forEach { UnregisterEventHotKey($0) }
        registeredHotKeys.removeAll()
        actionByHotKeyID.removeAll()
        if let carbonEventHandler {
            RemoveEventHandler(carbonEventHandler)
            self.carbonEventHandler = nil
        }
    }

    private func registerMediaCommands() {
        let center = MPRemoteCommandCenter.shared()
        mediaCommandTargets = [
            register(center.togglePlayPauseCommand, action: .togglePlayback),
            register(center.previousTrackCommand, action: .previousTrack),
            register(center.nextTrackCommand, action: .nextTrack),
        ]
    }

    private func register(
        _ command: MPRemoteCommand,
        action: GMGNShortcutAction
    ) -> (MPRemoteCommand, Any) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.performAction(action)
            }
            return .success
        }
        return (command, target)
    }

    private func unregisterMediaCommands() {
        for (command, target) in mediaCommandTargets {
            command.removeTarget(target)
        }
        mediaCommandTargets.removeAll()
    }
}

@MainActor
struct GMGNShortcutSettingsView: View {
    @ObservedObject var settings: GMGNShortcutSettingsStore
    @State private var recorderMonitor: Any?
    @State private var validationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("快捷键")
                    .font(.title2.weight(.semibold))
                Text("点击按键框，再按下新的组合键")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            Form {
                Section {
                    Grid(alignment: .leading, horizontalSpacing: 16) {
                        GridRow {
                            Text("功能")
                            Text("应用内")
                            Text("全局")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        Divider().gridCellColumns(3)

                        ForEach(settings.assignments) { assignment in
                            GridRow {
                                Text(assignment.action.title)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                                shortcutButton(
                                    assignment.local,
                                    action: assignment.action,
                                    scope: .local
                                )
                                shortcutButton(
                                    assignment.global,
                                    action: assignment.action,
                                    scope: .global
                                )
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Section {
                    Toggle("启用全局快捷键", isOn: $settings.globalEnabled)
                    Text("gmgn radio 在后台时也能响应。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "使用系统媒体快捷键",
                        isOn: $settings.mediaKeysEnabled
                    )
                    Text("响应键盘上的播放、暂停、上一首和下一首。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        if let validationMessage {
                            Text(validationMessage)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("恢复默认") {
                            validationMessage = nil
                            settings.reset()
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { installRecorderMonitor() }
        .onDisappear {
            removeRecorderMonitor()
            settings.cancelRecording()
        }
    }

    @ViewBuilder
    private func shortcutButton(
        _ combination: GMGNKeyCombination,
        action: GMGNShortcutAction,
        scope: GMGNShortcutScope
    ) -> some View {
        let isRecording = settings.recordingTarget
            == GMGNShortcutTarget(action: action, scope: scope)
        Button {
            validationMessage = nil
            settings.beginRecording(action: action, scope: scope)
        } label: {
            Text(isRecording ? "请按快捷键" : combination.displayName)
                .font(.body.monospaced())
                .frame(width: 112, alignment: .leading)
                .contentTransition(.numericText())
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .cyan : nil)
    }

    private func installRecorderMonitor() {
        guard recorderMonitor == nil else {
            return
        }
        recorderMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            let keyCode = event.keyCode
            let combination = GMGNKeyCombination(event: event)
            let handled = MainActor.assumeIsolated {
                guard let target = settings.recordingTarget else {
                    return false
                }
                if keyCode == 53 {
                    settings.cancelRecording()
                    validationMessage = nil
                    return true
                }
                guard let combination else {
                    validationMessage = "请按一个完整的按键组合。"
                    return true
                }
                if target.scope == .global && combination.modifiers.isEmpty {
                    validationMessage = "全局快捷键至少需要一个修饰键。"
                    return true
                }
                settings.assign(
                    combination,
                    to: target.action,
                    scope: target.scope
                )
                validationMessage = nil
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeRecorderMonitor() {
        guard let recorderMonitor else {
            return
        }
        NSEvent.removeMonitor(recorderMonitor)
        self.recorderMonitor = nil
    }
}
