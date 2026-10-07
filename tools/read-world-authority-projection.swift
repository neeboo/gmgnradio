import Foundation
import WorldRuntime

@main struct ReadAuthorityProjection {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { exit(64) }
        let client = WorldAuthorityClient(worldID: CommandLine.arguments[1], endpointFile: CommandLine.arguments[2],
            helperPath: CommandLine.arguments[3], allowsLaunching: false)
        guard let record = try client.snapshot() else { throw WorldAuthorityError.noAuthorityRecord }
        let summary: [String: Any] = ["worldID": record.state.worldID, "recordRevision": record.recordRevision,
            "stateSHA256": record.stateSha256, "objectCount": record.state.objectStates.count,
            "boundarySeq": record.boundarySeq]
        print(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
