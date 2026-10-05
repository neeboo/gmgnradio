// Compile with the actual UnityWorldBridge.swift. Stubs below deliberately
// prohibit transport: this is lossless wire-boundary coverage, not App E2E.
import Foundation

enum WorldAuthorityError: Error { case daemon(String), invalidResponse, unavailable(String) }
struct WorldAuthorityEndpoint {
    let socketPath = "unused", helperPath = "unused"
    init(applicationSupportBase: URL) {}
}
struct WorldAuthorityClient { static func decodeState(_ state: [String: Any]) throws {} }
struct LoopbackJSONClient {
    static let maximumFrame = 12 * 1024 * 1024
    init(socketPath: String, helperPath: String, allowsLaunching: Bool, timeout: Double) {}
    func call(method: String, params: [String: Any]) throws -> [String: Any] { fatalError("test must not call transport") }
}

@main struct PlacementWireTest {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    static func expanded(_ value: Any) throws -> [[[NSNumber]]] {
        if let faces = value as? [[[NSNumber]]] { return faces }
        let indexed = value as! [String: Any]
        let vertices = indexed["vertices"] as! [[NSNumber]]
        let indices = indexed["indices"] as! [[NSNumber]]
        return indices.map { face in face.map { vertices[$0.intValue] } }
    }
    static func equalBits(_ first: [[[NSNumber]]], _ second: [[[NSNumber]]]) -> Bool {
        guard first.count == second.count else { return false }
        for i in first.indices {
            for j in 0..<3 { for axis in 0..<3 {
                if first[i][j][axis].floatValue.bitPattern != second[i][j][axis].floatValue.bitPattern { return false }
            } }
        }
        return true
    }
    static func main() throws {
        let bridge = UnityWorldBridge(root: URL(fileURLWithPath: "/tmp/unused-unity-placement-wire"))
        let faces: [[[NSNumber]]] = [[[0, 0, 0], [1, 0, 0], [0, 0, 1]], [[0, 0, 1], [1, 0, 0], [1, 1, 1]]]
        let input: [String: Any] = ["triangles": faces,
            "placedObstacles": [["shape": "mesh", "id": "prop", "isClosed": true, "triangles": faces]],
            "blockingVolumes": [["shape": "mesh", "id": "blocking", "isClosed": false, "triangles": faces],
                ["shape": "box", "id": "box", "volume": ["center": [0, 0, 0]]]]]
        let compact = try bridge.preparePlacementGeometry(input)
        try require(equalBits(faces, try expanded(compact["triangles"]!)), "top-level winding and vertex bits")
        let placed = compact["placedObstacles"] as! [[String: Any]]
        try require(equalBits(faces, try expanded(placed[0]["triangles"]!)), "nested prop winding and vertex bits")
        try require(placed[0]["id"] as? String == "prop" && placed[0]["isClosed"] as? Bool == true, "identity and closedness")
        let blocking = compact["blockingVolumes"] as! [[String: Any]]
        try require(equalBits(faces, try expanded(blocking[0]["triangles"]!)), "blocking mesh preserved")
        try require(blocking[1]["shape"] as? String == "box", "box shape untouched")
        let replay = try bridge.preparePlacementGeometry(compact)
        try require(equalBits(faces, try expanded((replay["placedObstacles"] as! [[String: Any]])[0]["triangles"]!)), "already indexed pass-through")
        do {
            _ = try bridge.preparePlacementGeometry(["placedObstacles": [["shape": "mesh", "triangles": [[[0, 0, 0], [1, 0, 0]]]]]])
            throw NSError(domain: "malformed nested face accepted", code: 1)
        } catch WorldAuthorityError.daemon { }
        // More than the real transport limit before compaction; repeated faces
        // must remain present after compaction, not be decimated or dropped.
        let large = Array(repeating: faces[0], count: 170_000)
        let dense: [String: Any] = ["triangles": large,
            "placedObstacles": (0..<4).map { ["shape": "mesh", "id": "mesh-\($0)", "triangles": large] as [String: Any] }]
        let before = try JSONSerialization.data(withJSONObject: dense).count
        let shrunk = try bridge.preparePlacementGeometry(dense)
        let after = try JSONSerialization.data(withJSONObject: shrunk).count
        try require(before > LoopbackJSONClient.maximumFrame, "fixture must exceed old frame limit")
        try require(after < LoopbackJSONClient.maximumFrame - 4096, "indexed nested payload must fit unchanged frame limit")
        try require(try expanded(shrunk["triangles"]!).count == large.count, "no collider faces lost")
        for obstacle in shrunk["placedObstacles"] as! [[String: Any]] {
            try require(equalBits(large, try expanded(obstacle["triangles"]!)), "no obstacle faces lost")
        }
        print("PASS actual Swift bridge: nested indexing, exact f32/winding, closedness, malformed rejection, cache/pass-through; bytes \(before) → \(after); no transport/App E2E")
    }
}
