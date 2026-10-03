import Combine
import WorldRuntime

@MainActor
final class StageDecorationMenuStore: ObservableObject {
    static let shared = StageDecorationMenuStore()
    @Published private(set) var isDecorating = false

    func update(isDecorating: Bool) {
        guard self.isDecorating != isDecorating else { return }
        self.isDecorating = isDecorating
    }
}

// These menu data declarations live in the excluded application-bootstrap
// file. Keep this probe-only copy for compiling unchanged production UI types;
// the render host does not instantiate those UI types or menu stores.
struct LivingWorldActivityMenuItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

@MainActor
final class LivingWorldActivityMenuStore: ObservableObject {
    static let shared = LivingWorldActivityMenuStore()
    @Published private(set) var items: [LivingWorldActivityMenuItem] = []
    @Published private(set) var worldID: String?
    @Published private(set) var activeActivityID: String?
    @Published private(set) var message: String?

    func canControl(worldID: String?) -> Bool {
        guard let worldID else { return false }
        return self.worldID == worldID
    }
}
