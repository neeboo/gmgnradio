import Foundation

public struct WaypointNavigationGraph: WorldNavigationRouting {
    private struct Edge: Sendable {
        let destinationID: String
        let length: Float
    }

    private struct DirectedEdge: Hashable {
        let originID: String
        let destinationID: String
    }

    private struct PathQueue {
        private struct Entry {
            let id: String
            let distance: Float

            func precedes(_ other: Entry) -> Bool {
                (distance, id) < (other.distance, other.id)
            }
        }

        private var entries: [Entry] = []

        mutating func insert(id: String, distance: Float) {
            entries.append(Entry(id: id, distance: distance))
            var index = entries.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard entries[index].precedes(entries[parent]) else { break }
                entries.swapAt(index, parent)
                index = parent
            }
        }

        mutating func removeMinimum() -> (id: String, distance: Float)? {
            guard let first = entries.first else { return nil }
            let last = entries.removeLast()
            if !entries.isEmpty {
                entries[0] = last
                var index = 0
                while index * 2 + 1 < entries.count {
                    let left = index * 2 + 1
                    let right = left + 1
                    let child = right < entries.count && entries[right].precedes(entries[left])
                        ? right : left
                    guard entries[child].precedes(entries[index]) else { break }
                    entries.swapAt(child, index)
                    index = child
                }
            }
            return (first.id, first.distance)
        }
    }

    private let waypointsByID: [String: WorldWaypoint]
    private let adjacency: [String: [Edge]]
    private let reverseAdjacency: [String: [String]]

    public init(waypoints: [WorldWaypoint], routes: [WorldRoute]) {
        let indexedWaypoints = Dictionary(
            waypoints.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        waypointsByID = indexedWaypoints

        var authoredEdges: [String: [Edge]] = [:]
        for route in routes where route.enabled {
            for pair in zip(route.waypointIDs, route.waypointIDs.dropFirst()) {
                guard let origin = indexedWaypoints[pair.0], origin.enabled,
                      let destination = indexedWaypoints[pair.1], destination.enabled
                else {
                    continue
                }

                let length = worldDistance(
                    origin.position.simd3,
                    destination.position.simd3
                )
                authoredEdges[origin.id, default: []].append(
                    Edge(destinationID: destination.id, length: length)
                )
                if route.bidirectional {
                    authoredEdges[destination.id, default: []].append(
                        Edge(destinationID: origin.id, length: length)
                    )
                }
            }
        }

        adjacency = authoredEdges.mapValues { edges in
            edges.sorted {
                ($0.destinationID, $0.length) < ($1.destinationID, $1.length)
            }
        }
        var incoming: [String: [String]] = [:]
        for (originID, edges) in authoredEdges {
            for edge in edges {
                incoming[edge.destinationID, default: []].append(originID)
            }
        }
        reverseAdjacency = incoming.mapValues { $0.sorted() }
    }

    public init(manifest: WorldManifest) {
        self.init(waypoints: manifest.waypoints, routes: manifest.routes)
    }

    public func route(
        from position: SIMD3<Float>,
        to anchorID: String
    ) throws -> WorldPath {
        try route(from: position, to: anchorID, canTraverse: { _, _ in true })
    }

    public func route(
        from position: SIMD3<Float>,
        to anchorID: String,
        canTraverse: (SIMD3<Float>, SIMD3<Float>) -> Bool
    ) throws -> WorldPath {
        guard let destination = waypointsByID[anchorID] else {
            throw WorldNavigationError.unknownAnchor(anchorID: anchorID)
        }
        guard destination.enabled else {
            throw WorldNavigationError.disabledAnchor(anchorID: anchorID)
        }

        let arrivalTolerance = max(destination.arrivalRadius, 0)
        let directDistance = worldDistance(position, destination.position.simd3)
        if directDistance <= arrivalTolerance {
            return WorldPath(
                destinationID: destination.id,
                waypointIDs: [],
                points: [],
                totalLength: 0,
                arrivalTolerance: arrivalTolerance
            )
        }

        var traversableEdges: [DirectedEdge: Bool] = [:]
        func canTraverseEdge(_ originID: String, _ destinationID: String) -> Bool {
            let key = DirectedEdge(originID: originID, destinationID: destinationID)
            if let cached = traversableEdges[key] { return cached }
            guard let origin = waypointsByID[originID],
                  let destination = waypointsByID[destinationID] else { return false }
            let allowed = canTraverse(origin.position.simd3, destination.position.simd3)
            traversableEdges[key] = allowed
            return allowed
        }

        var traversableEntries: [String: Bool] = [:]
        var blockedEdges: Set<DirectedEdge> = []
        // Each retry excludes a newly discovered blocked directed edge. The
        // graph's edge count bounds retries; each candidate entry is tested once.
        let edgeCount = adjacency.values.reduce(0) { $0 + $1.count }
        for _ in 0...edgeCount {
            func allowsKnownEdge(_ originID: String, _ destinationID: String) -> Bool {
                !blockedEdges.contains(DirectedEdge(originID: originID, destinationID: destinationID))
            }
            let reachableIDs = reverseReachableWaypoints(
                destinationID: destination.id,
                canTraverseEdge: allowsKnownEdge
            )
            guard let start = nearestReachableWaypoint(
                to: position,
                destinationID: destination.id,
                reachableIDs: reachableIDs,
                canEnter: { candidate in
                    if let cached = traversableEntries[candidate.id] { return cached }
                    let allowed = canTraverse(position, candidate.position.simd3)
                    traversableEntries[candidate.id] = allowed
                    return allowed
                }
            ) else {
                throw WorldNavigationError.unreachable(destinationID: destination.id)
            }

            guard let result = shortestPath(
                from: start.id,
                to: destination.id,
                canTraverseEdge: allowsKnownEdge
            ) else {
                throw WorldNavigationError.unreachable(destinationID: destination.id)
            }

            // Collision queries are expensive on real meshes. Validate only the
            // proposed path, then replan with any failed edge removed.
            if let blocked = zip(result.waypointIDs, result.waypointIDs.dropFirst())
                .first(where: { !canTraverseEdge($0.0, $0.1) }) {
                blockedEdges.insert(DirectedEdge(originID: blocked.0, destinationID: blocked.1))
                continue
            }

            var futureIDs = result.waypointIDs
            var totalLength = result.length
            let entryDistance = worldDistance(position, start.position.simd3)
            if entryDistance <= max(start.arrivalRadius, 0) {
                futureIDs.removeFirst()
            } else {
                totalLength += entryDistance
            }

            return WorldPath(
                destinationID: destination.id,
                waypointIDs: futureIDs,
                points: futureIDs.compactMap { waypointsByID[$0]?.position },
                totalLength: totalLength,
                arrivalTolerance: arrivalTolerance
            )
        }
        throw WorldNavigationError.unreachable(destinationID: destination.id)
    }

    private func nearestReachableWaypoint(
        to position: SIMD3<Float>,
        destinationID: String,
        reachableIDs: Set<String>,
        canEnter: (WorldWaypoint) -> Bool
    ) -> WorldWaypoint? {
        waypointsByID.values
            .filter(\.enabled)
            .filter {
                $0.id != destinationID
                    && reachableIDs.contains($0.id)
            }
            .sorted { lhs, rhs in
                let lhsDistance = worldDistance(position, lhs.position.simd3)
                let rhsDistance = worldDistance(position, rhs.position.simd3)
                if lhsDistance == rhsDistance {
                    return lhs.id < rhs.id
                }
                return lhsDistance < rhsDistance
            }
            .first(where: canEnter)
    }

    private func reverseReachableWaypoints(
        destinationID: String,
        canTraverseEdge: (String, String) -> Bool
    ) -> Set<String> {
        var reachable: Set<String> = [destinationID]
        var pending = [destinationID]
        while let currentID = pending.popLast() {
            for originID in reverseAdjacency[currentID, default: []]
            where !reachable.contains(originID) {
                // The reverse search must still test the authored forward direction.
                if canTraverseEdge(originID, currentID) {
                    reachable.insert(originID)
                    pending.append(originID)
                }
            }
        }
        return reachable
    }

    private func shortestPath(
        from startID: String,
        to destinationID: String,
        canTraverseEdge: (String, String) -> Bool
    ) -> (waypointIDs: [String], length: Float)? {
        var distances = [startID: Float.zero]
        var previous: [String: String] = [:]
        var settled: Set<String> = []
        var queue = PathQueue()
        queue.insert(id: startID, distance: 0)

        while let current = queue.removeMinimum() {
            let currentID = current.id
            let currentDistance = current.distance
            // A shorter route can enqueue the same waypoint again before its
            // earlier entry is popped. Only settle its current best distance.
            guard currentDistance == distances[currentID],
                  settled.insert(currentID).inserted else { continue }

            if currentID == destinationID {
                break
            }

            for edge in adjacency[currentID, default: []]
            where !settled.contains(edge.destinationID)
                && canTraverseEdge(currentID, edge.destinationID) {
                let candidate = currentDistance + edge.length
                let known = distances[edge.destinationID] ?? .infinity
                if candidate < known {
                    distances[edge.destinationID] = candidate
                    previous[edge.destinationID] = currentID
                    queue.insert(id: edge.destinationID, distance: candidate)
                }
            }
        }

        guard let length = distances[destinationID], length.isFinite else {
            return nil
        }

        var path = [destinationID]
        var cursor = destinationID
        while cursor != startID {
            guard let predecessor = previous[cursor] else {
                return nil
            }
            path.append(predecessor)
            cursor = predecessor
        }
        path.reverse()
        return (path, length)
    }
}
