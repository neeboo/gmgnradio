import Foundation

/// Delivery retries do not grant agent authority. They only reconcile the same
/// durable event IDs; cancellation/world close is owned by the caller's Task.
struct UnityNotificationRetry {
    private(set) var failures = 0
    mutating func failed() -> UInt64 {
        failures = min(failures + 1, 6)
        return UInt64(min(1 << (failures - 1), 30)) * 1_000_000_000
    }
    mutating func succeeded() { failures = 0 }
}
