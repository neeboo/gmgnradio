import CryptoKit
import Foundation

public struct WorldPackageValidator: Sendable {
    public let supportedSchemaVersions: Set<Int>

    public init(supportedSchemaVersions: Set<Int> = [1]) {
        self.supportedSchemaVersions = supportedSchemaVersions
    }

    public func validate(
        _ manifest: WorldManifest,
        packageRoot: URL
    ) -> [WorldPackageError] {
        var findings: [WorldPackageError] = []

        if !supportedSchemaVersions.contains(manifest.schemaVersion) {
            findings.append(
                .unsupportedSchemaVersion(
                    found: manifest.schemaVersion,
                    supported: supportedSchemaVersions.sorted()
                )
            )
        }

        findings.append(contentsOf: calibrationFindings(in: manifest))
        findings.append(contentsOf: duplicateIDFindings(in: manifest))
        findings.append(contentsOf: routeFindings(in: manifest))
        findings.append(contentsOf: activityFindings(in: manifest))
        findings.append(
            contentsOf: activityDefinitionFindings(
                in: manifest,
                packageRoot: packageRoot
            )
        )
        findings.append(contentsOf: cameraFindings(in: manifest))
        findings.append(contentsOf: resourceFindings(in: manifest, packageRoot: packageRoot))
        findings.append(contentsOf: capabilityFindings(in: manifest))

        return findings
    }

    private func calibrationFindings(
        in manifest: WorldManifest
    ) -> [WorldPackageError] {
        var findings: [WorldPackageError] = []
        let calibration = manifest.calibration
        if calibration.visualToGameplay.count != 16
            || calibration.visualToGameplay.contains(where: { !$0.isFinite })
        {
            findings.append(.invalidCalibrationVisualToGameplay)
        }
        if !calibration.metersPerUnit.isFinite || calibration.metersPerUnit <= 0 {
            findings.append(.invalidCalibrationMetersPerUnit)
        }
        return findings
    }

    private func duplicateIDFindings(
        in manifest: WorldManifest
    ) -> [WorldPackageError] {
        let collections: [(name: String, ids: [String])] = [
            ("collisionVolumes", manifest.collisionVolumes.map(\.id)),
            ("waypoints", manifest.waypoints.map(\.id)),
            ("routes", manifest.routes.map(\.id)),
            ("activities", manifest.activities.map(\.id)),
            ("cameras", manifest.cameras.map(\.id)),
            ("resources", manifest.resources.map(\.id)),
        ]
        var counts: [String: Int] = [:]
        var memberships: [String: Set<String>] = [:]
        for collection in collections {
            for id in collection.ids {
                counts[id, default: 0] += 1
                memberships[id, default: []].insert(collection.name)
            }
        }

        return counts
            .filter { $0.value > 1 }
            .map(\.key)
            .sorted()
            .map { id in
                let collectionNames = collections
                    .map(\.name)
                    .filter { memberships[id, default: []].contains($0) }
                    .joined(separator: ",")
                return .duplicateID(collection: collectionNames, id: id)
            }
    }

    private func routeFindings(
        in manifest: WorldManifest
    ) -> [WorldPackageError] {
        let waypointIDs = Set(manifest.waypoints.map(\.id))
        return manifest.routes
            .flatMap { route in
                Set(route.waypointIDs)
                    .subtracting(waypointIDs)
                    .map { (route.id, $0) }
            }
            .sorted {
                ($0.0, $0.1) < ($1.0, $1.1)
            }
            .map {
                .missingRouteWaypoint(routeID: $0.0, waypointID: $0.1)
            }
    }

    private func activityFindings(
        in manifest: WorldManifest
    ) -> [WorldPackageError] {
        let waypointIDs = Set(manifest.waypoints.map(\.id))
        let waypointsByID = Dictionary(
            manifest.waypoints.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let resourceIDs = Set(manifest.resources.map(\.id))
        let entryFindings: [WorldPackageError] = manifest.activities
            .filter { !waypointIDs.contains($0.entryWaypointID) }
            .sorted {
                ($0.id, $0.entryWaypointID) < ($1.id, $1.entryWaypointID)
            }
            .map {
                .missingActivityEntryWaypoint(
                    activityID: $0.id,
                    waypointID: $0.entryWaypointID
                )
            }
        let transformFindings: [WorldPackageError] = manifest.activities
            .compactMap { activity -> (String, String, Float)? in
                guard let waypoint = waypointsByID[activity.entryWaypointID]
                else {
                    return nil
                }
                let distance = worldDistance(
                    activity.transform.position.simd3,
                    waypoint.position.simd3
                )
                guard distance > 0.08 else { return nil }
                return (activity.id, activity.entryWaypointID, distance)
            }
            .sorted {
                ($0.0, $0.1) < ($1.0, $1.1)
            }
            .map {
                .activityEntryTransformMismatch(
                    activityID: $0.0,
                    waypointID: $0.1,
                    distance: $0.2,
                    maximumDistance: 0.08
                )
            }
        let propFindings: [WorldPackageError] = manifest.activities
            .flatMap { activity in
                Set(activity.propIDs)
                    .subtracting(resourceIDs)
                    .map { (activity.id, $0) }
            }
            .sorted {
                ($0.0, $0.1) < ($1.0, $1.1)
            }
            .map {
                .missingActivityPropResource(
                    activityID: $0.0,
                    resourceID: $0.1
                )
            }
        return entryFindings + transformFindings + propFindings
    }

    private func activityDefinitionFindings(
        in manifest: WorldManifest,
        packageRoot: URL
    ) -> [WorldPackageError] {
        guard hasAuthoredActivityDefinitions(in: manifest, packageRoot: packageRoot) else {
            return []
        }

        let anchorsByID = Dictionary(
            manifest.activities.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let anchorIDs = Set(anchorsByID.keys)
        let definitionsByID = Dictionary(
            grouping: manifest.activityDefinitions,
            by: \.id
        )

        var findings: [WorldPackageError] = []
        findings += anchorIDs
            .filter { definitionsByID[$0] == nil }
            .sorted()
            .map { .missingActivityDefinition(activityID: $0) }
        findings += anchorIDs
            .filter { definitionsByID[$0, default: []].count > 1 }
            .sorted()
            .map { .duplicateActivityDefinition(activityID: $0) }
        findings += Set(definitionsByID.keys)
            .subtracting(anchorIDs)
            .sorted()
            .map { .orphanActivityDefinition(activityID: $0) }

        for activityID in anchorIDs.sorted() {
            guard let anchor = anchorsByID[activityID],
                  let definitions = definitionsByID[activityID],
                  definitions.count == 1,
                  let definition = definitions.first
            else {
                continue
            }
            let anchorAction = LifeActivity.canonicalTypeID(for: anchor.action)
            if anchorAction != definition.activity.typeID {
                findings.append(
                    .activityDefinitionActionMismatch(
                        activityID: activityID,
                        anchorAction: anchor.action,
                        definitionAction: definition.activity.typeID
                    )
                )
            }
            if case let .walk(destinationID) = definition.activity,
               anchor.entryWaypointID != destinationID
            {
                findings.append(
                    .activityWalkDestinationMismatch(
                        activityID: activityID,
                        entryWaypointID: anchor.entryWaypointID,
                        destinationWaypointID: destinationID
                    )
                )
            }
        }

        var missingPhasesByID: [String: Set<LifeActivityPhase>] = [:]
        var duplicatePhasesByID: [String: Set<LifeActivityPhase>] = [:]
        for definition in manifest.activityDefinitions {
            let counts = Dictionary(
                grouping: definition.phases,
                by: \.phase
            ).mapValues(\.count)
            for phase in LifeActivityPhase.allCases {
                if counts[phase] == nil {
                    missingPhasesByID[definition.id, default: []].insert(phase)
                } else if counts[phase, default: 0] > 1 {
                    duplicatePhasesByID[definition.id, default: []].insert(phase)
                }
            }
        }

        for activityID in missingPhasesByID.keys.sorted() {
            for phase in LifeActivityPhase.allCases
            where missingPhasesByID[activityID, default: []].contains(phase) {
                findings.append(
                    .missingActivityDefinitionPhase(
                        activityID: activityID,
                        phase: phase
                    )
                )
            }
        }
        for activityID in duplicatePhasesByID.keys.sorted() {
            for phase in LifeActivityPhase.allCases
            where duplicatePhasesByID[activityID, default: []].contains(phase) {
                findings.append(
                    .duplicateActivityDefinitionPhase(
                        activityID: activityID,
                        phase: phase
                    )
                )
            }
        }
        return findings
    }

    private func hasAuthoredActivityDefinitions(
        in manifest: WorldManifest,
        packageRoot: URL
    ) -> Bool {
        if !manifest.activityDefinitions.isEmpty {
            return true
        }

        let manifestURL = packageRoot.appendingPathComponent("world.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return false
        }
        return dictionary.keys.contains("activityDefinitions")
    }

    private func cameraFindings(
        in manifest: WorldManifest
    ) -> [WorldPackageError] {
        manifest.cameras
            .filter {
                !$0.nearPlane.isFinite
                    || !$0.farPlane.isFinite
                    || $0.nearPlane <= 0
                    || $0.farPlane <= $0.nearPlane
            }
            .sorted {
                ($0.id, $0.nearPlane.bitPattern, $0.farPlane.bitPattern)
                    < ($1.id, $1.nearPlane.bitPattern, $1.farPlane.bitPattern)
            }
            .map {
                .invalidCameraPlanes(
                    cameraID: $0.id,
                    nearPlane: $0.nearPlane,
                    farPlane: $0.farPlane
                )
            }
    }

    private func resourceFindings(
        in manifest: WorldManifest,
        packageRoot: URL
    ) -> [WorldPackageError] {
        let root = packageRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var findings: [WorldPackageError] = []

        for resource in manifest.resources.sorted(by: {
            ($0.id, $0.path, $0.sha256, $0.kind)
                < ($1.id, $1.path, $1.sha256, $1.kind)
        }) {
            guard !resource.path.isEmpty,
                  !NSString(string: resource.path).isAbsolutePath
            else {
                findings.append(
                    .resourcePathEscapesPackageRoot(
                        resourceID: resource.id,
                        path: resource.path
                    )
                )
                continue
            }

            let resourceURL = root
                .appendingPathComponent(resource.path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard resourceURL.path.hasPrefix(rootPrefix) else {
                findings.append(
                    .resourcePathEscapesPackageRoot(
                        resourceID: resource.id,
                        path: resource.path
                    )
                )
                continue
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: resourceURL.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else {
                findings.append(
                    .resourceNotFound(resourceID: resource.id, path: resource.path)
                )
                continue
            }

            guard let actualHash = try? sha256(of: resourceURL) else {
                findings.append(
                    .resourceUnreadable(resourceID: resource.id, path: resource.path)
                )
                continue
            }

            guard actualHash == resource.sha256.lowercased() else {
                findings.append(
                    .resourceSHA256Mismatch(
                        resourceID: resource.id,
                        expected: resource.sha256,
                        actual: actualHash
                    )
                )
                continue
            }
        }

        return findings
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }

    private func capabilityFindings(
        in manifest: WorldManifest
    ) -> [WorldPackageError] {
        let activityIDs = Set(manifest.activities.map(\.id))
        let cameraIDs = Set(manifest.cameras.map(\.id))

        return manifest.capabilities
            .filter { capability in
                if capability.rawValue.hasPrefix("activity:") {
                    let id = String(capability.rawValue.dropFirst("activity:".count))
                    return id.isEmpty || !activityIDs.contains(id)
                }
                if capability.rawValue.hasPrefix("camera:") {
                    let id = String(capability.rawValue.dropFirst("camera:".count))
                    return id.isEmpty || !cameraIDs.contains(id)
                }
                return true
            }
            .sorted()
            .map { .unmatchedCapability(capability: $0) }
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { byte in
            let value = String(byte, radix: 16)
            return value.count == 1 ? "0" + value : value
        }
        .joined()
    }
}
