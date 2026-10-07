import Foundation
import WorldRuntime
@testable import UnityMediaHost

@main struct StaticSeatContractChecks {
    @MainActor static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        func manifest(_ name: String) throws -> WorldManifest {
            try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf:
                resources.appendingPathComponent(name).appendingPathComponent("world.json")))
        }
        let marble = try manifest("marble-living-cabin")
        let catalog = try ActivityCatalog(manifest: marble)
        precondition(!marble.activities.contains { $0.id == "chair.sit" })
        precondition(catalog.definition(id: "chair.sit") == nil)
        precondition(!marble.capabilities.contains { $0.rawValue == "activity:chair.sit" })
        let context = try WorldAgentContext(manifest: marble)
        precondition(!context.snapshot.activities.contains { $0.id == "chair.sit" })
        let before = context.state.agentTransform
        do {
            try context.startActivity(id: "chair.sit")
            fatalError("Unbound spawn-seat activity must reject")
        } catch WorldAgentContextError.unknownActivity(let id) {
            precondition(id == "chair.sit")
        }
        precondition(context.state.agentTransform == before)
        let living = try manifest("living-pod-v1")
        let livingCatalog = try ActivityCatalog(manifest: living)
        precondition(living.activities.contains { $0.id == "bunk.rest" && $0.action == "sit" })
        precondition(livingCatalog.definition(id: "bunk.rest") != nil)
        print("PASS: bogus marble spawn-seat undiscoverable and rejected without movement; valid living-pod bunk preserved")
    }
}
