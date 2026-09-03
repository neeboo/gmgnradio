import Foundation

public struct WaypointNavigationGraph: WorldNavigationRouting {
    private struct Edge: Sendable {
        let destinationID: String
        let length: Float
    }

    private let waypointsByID: [String: WorldWaypoint]
    private let adjacency: [String: [Edge]]

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
    }

    public init(manifest: WorldManifest) {
        self.init(waypoints: manifest.waypoints, routes: manifest.routes)
    }

    public func route(
        from position: SIMD3<Float>,
        to anchorID: String
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

        guard let start = nearestReachableWaypoint(
            to: position,
            destinationID: destination.id
        ) else {
            throw WorldNavigationError.unreachable(
                destinationID: destination.id
            )
        }

        if start.id == destination.id {
            return WorldPath(
                destinationID: destination.id,
                waypointIDs: [destination.id],
                points: [destination.position],
                totalLength: directDistance,
                arrivalTolerance: arrivalTolerance
            )
        }

        let result = shortestPath(from: start.id, to: destination.id)
        guard let result else {
            throw WorldNavigationError.unreachable(destinationID: destination.id)
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

    private func nearestReachableWaypoint(
        to position: SIMD3<Float>,
        destinationID: String
    ) -> WorldWaypoint? {
        waypointsByID.values
            .filter(\.enabled)
            .filter {
                $0.id != destinationID
                    && shortestPath(from: $0.id, to: destinationID) != nil
            }
            .min { lhs, rhs in
                let lhsDistance = worldDistance(position, lhs.position.simd3)
                let rhsDistance = worldDistance(position, rhs.position.simd3)
                if lhsDistance == rhsDistance {
                    return lhs.id < rhs.id
                }
                return lhsDistance < rhsDistance
            }
    }

    private func shortestPath(
        from startID: String,
        to destinationID: String
    ) -> (waypointIDs: [String], length: Float)? {
        var distances = [startID: Float.zero]
        var previous: [String: String] = [:]
        var unvisited = Set(waypointsByID.values.filter(\.enabled).map(\.id))

        while !unvisited.isEmpty {
            guard let currentID = unvisited.min(by: { lhs, rhs in
                let lhsDistance = distances[lhs] ?? .infinity
                let rhsDistance = distances[rhs] ?? .infinity
                if lhsDistance == rhsDistance {
                    return lhs < rhs
                }
                return lhsDistance < rhsDistance
            }), let currentDistance = distances[currentID], currentDistance.isFinite
            else {
                break
            }

            unvisited.remove(currentID)
            if currentID == destinationID {
                break
            }

            for edge in adjacency[currentID, default: []]
            where unvisited.contains(edge.destinationID) {
                let candidate = currentDistance + edge.length
                let known = distances[edge.destinationID] ?? .infinity
                if candidate < known {
                    distances[edge.destinationID] = candidate
                    previous[edge.destinationID] = currentID
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
