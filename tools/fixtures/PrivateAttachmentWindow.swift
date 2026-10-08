import AppKit

/// Only the unused default parent-window constructor is replaced. Tests pass their own real temporary windows.
@MainActor final class UnityWindowModeBridge {
    static let shared = UnityWindowModeBridge()
    var targetWindow: NSWindow? { nil }
}
