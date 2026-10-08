import CryptoKit
import Foundation
import SplatIO
import WorldRuntime

extension RustMarbleControlClient.World {
    func nativeWorld() throws -> MarbleWorld {
        let coordinates: MarbleColliderSourceCoordinates
        switch colliderCoordinates { case "glTF": coordinates = .glTF
        case "worldLabsOpenCV": coordinates = .worldLabsOpenCV
        default: throw RustMarbleControlError.invalidResponse }
        let assets = try splatFallbacks.map { asset in
            guard let quality = MarbleSplatQuality(rawValue: asset.quality) else { throw RustMarbleControlError.invalidResponse }
            return MarbleSplatAsset(quality: quality, url: asset.url)
        }
        return MarbleWorld(id: id, name: name, model: model, thumbnailURL: thumbnailURL, colliderURL: colliderURL,
            colliderSourceCoordinates: coordinates, semantics: .init(metricScale: semantics.metricScale,
                groundPlaneOffset: semantics.groundPlaneOffset), splatFallbacks: assets)
    }
}

enum UnityMarbleError: LocalizedError {
    case identityMissing, assetMissing, invalidGeometry, invalidPackage, registrationRejected, packageConflict
    case busy, runtimeUnavailable, selectionRejected, selectionTimedOut
    case operationFailed(String)
    var errorDescription: String? {
        switch self {
        case .identityMissing: "Marble 操作没有返回确切的空间编号。"
        case .assetMissing: "Marble 空间缺少 SPZ 或碰撞资源。"
        case .invalidGeometry: "Marble 资源无法解码，或找不到可安全站立的位置。"
        case .invalidPackage: "Marble 正式空间包校验失败。"
        case .registrationRejected: "空间权威注册未通过读回验证。"
        case .packageConflict: "已有同编号的不同空间包，未覆盖原空间。"
        case .busy: "另一个 Marble 操作仍在处理中，请先处理该操作。"
        case .runtimeUnavailable: "当前 Unity 渲染器尚未确认 Marble 空间支持。"
        case .selectionRejected: "空间载入未通过实际运行回执，原空间已保留。"
        case .selectionTimedOut: "等待空间载入回执超时，尚未确认切换完成。"
        case let .operationFailed(message): message
        }
    }
}

enum UnityMarblePackageBuilder {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func packageRoot(root: URL, worldID: String) -> URL {
        root.appendingPathComponent("gmgn radio/WorldPackages", isDirectory: true).appendingPathComponent(digest(Data(worldID.utf8)), isDirectory: true)
    }
    static func registeredRoots(root: URL) -> [URL] {
        let parent = root.appendingPathComponent("gmgn radio/WorldPackages", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []).filter { url in
            guard url.standardizedFileURL == url.resolvingSymlinksInPath(),
                  let data = try? Data(contentsOf: url.appendingPathComponent("world.json")),
                  let marker = try? String(contentsOf: url.appendingPathComponent("registered.sha256"), encoding: .utf8),
                  marker == digest(data), let manifest = try? JSONDecoder().decode(WorldManifest.self, from: data),
                  WorldPackageValidator().validate(manifest, packageRoot: url).isEmpty else { return false }
            return (try? UnityMarbleRuntimeDocument.load(package: BundledLivingWorldPackage(manifest: manifest, packageRoot: url))) != nil
        }
    }
    static func publish(world: MarbleWorld, splat: URL, collider: URL, root: URL,
                        geometry: RustMarbleGeometryClient, blobRoot: URL) async throws -> BundledLivingWorldPackage {
        try UnityMarbleSPZFormat.requireRuntimeSupported(splat)
        let points = try await SPZSceneReader(splat).readAll()
        try Task.checkCancellation()
        guard !points.isEmpty, points.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite }) else { throw UnityMarbleError.invalidGeometry }
        let sampling = try await geometry.samplePlan(pointCount: points.count)
        struct Sample: Encodable, Sendable { let index: Int; let position: [Float] }
        let samples = try sampling.indices.map { index -> Sample in
            guard points.indices.contains(index) else { throw WorldAuthorityError.invalidResponse }
            let p = points[index].position
            return Sample(index:index,position:[p.x,p.y,p.z])
        }
        // Decode node transforms only. Axis conversion and framing arrive from Rust.
        let rawTriangles = try GLBColliderDecoder().decode(data: Data(contentsOf:collider),transform:WorldMeshTransform())
        struct TriangleChunk: Encodable, Sendable { let offset: Int; let triangles: [[[Float]]] }
        var triangleChunks: [String] = []
        for offset in stride(from:0,to:rawTriangles.count,by:1024) {
            try Task.checkCancellation()
            let end = min(offset+1024,rawTriangles.count)
            let rows = rawTriangles[offset..<end].map { triangle in
                [triangle.first,triangle.second,triangle.third].map { [$0.x,$0.y,$0.z] }
            }
            let chunk = TriangleChunk(offset:offset,triangles:rows)
            let bytes = try await Task.detached { let e=JSONEncoder(); e.outputFormatting=[.sortedKeys]; return try e.encode(chunk) }.value
            triangleChunks.append(try await geometry.registerFact(bytes,blobRoot:blobRoot))
        }
        struct GeometryManifest: Encodable, Sendable {
            let sourcePointCount: Int; let samples: [Sample]; let sourceCoordinates: String
            let triangleCount: Int; let triangleChunks: [String]
        }
        let coordinates = world.colliderSourceCoordinates == .glTF ? "glTF" : "worldLabsOpenCV"
        let source = GeometryManifest(sourcePointCount:points.count,samples:samples,sourceCoordinates:coordinates,
            triangleCount:rawTriangles.count,triangleChunks:triangleChunks)
        let geometryManifest = try await Task.detached { let e=JSONEncoder(); e.outputFormatting=[.sortedKeys]; return try e.encode(source) }.value
        struct Plan: Decodable {
            struct Framing: Decodable { let origin: [Float]; let uniformScale: Float; let runtimeMinimum: [Float]; let runtimeMaximum: [Float] }
            struct Mesh: Decodable { let axisConversion: String; let origin: [Float]; let uniformScale: Float }
            let framing: Framing; let meshTransform: Mesh
        }
        let firstPage = try await geometry.firstPage(geometryManifest:geometryManifest)
        let plan = try JSONDecoder().decode(Plan.self,from:firstPage)
        guard plan.meshTransform.origin.count == 3 else { throw WorldAuthorityError.invalidResponse }
        let axis: WorldMeshAxisConversion
        switch plan.meshTransform.axisConversion {
        case "identity": axis = .identity
        case "flipYAndZ": axis = .flipYAndZ
        default: throw WorldAuthorityError.invalidResponse
        }
        let mesh = WorldMeshTransform(axisConversion:axis,
            origin:SIMD3(plan.meshTransform.origin[0],plan.meshTransform.origin[1],plan.meshTransform.origin[2]),
            uniformScale:plan.meshTransform.uniformScale)
        let collision = TriangleMeshCollisionWorld(triangles:rawTriangles.map { WorldTriangle(mesh.apply($0.first),mesh.apply($0.second),mesh.apply($0.third)) })
        let resolution = try await geometry.resolvePaged(geometryManifest:geometryManifest,firstPage:firstPage,
            measure: { probe in
                guard probe.position.count == 3 else { throw WorldAuthorityError.invalidResponse }
                let p=SIMD3(probe.position[0],probe.position[1],probe.position[2])
                return RustMarbleGeometryClient.Measurement(groundHeight:collision.groundHeight(at:p),
                    canOccupy:collision.canOccupy(WorldCapsule(radius:probe.capsule.radius,height:probe.capsule.height),at:p))
            }, registerFact: { try await geometry.registerFact($0,blobRoot:blobRoot) })
        struct Resolution: Decodable { let spawn: WorldTransform; let waypoint: WorldWaypoint; let camera: WorldCameraAnchor }
        let resolved = try JSONDecoder().decode(Resolution.self,from:resolution)
        let document = UnityMarbleRuntimeDocument(schemaVersion: 1, worldID: world.id, splatPath: "scene.spz", colliderPath: "collider.glb",
            colliderAxisConversion:plan.meshTransform.axisConversion,
            origin:plan.framing.origin,uniformScale:plan.framing.uniformScale,
            minimum:plan.framing.runtimeMinimum,maximum:plan.framing.runtimeMaximum)
        let destination = packageRoot(root: root, worldID: world.id)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.copyItem(at: splat, to: stage.appendingPathComponent("scene.spz"))
        try FileManager.default.copyItem(at: collider, to: stage.appendingPathComponent("collider.glb"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: stage.appendingPathComponent("marble-runtime.json"), options: .atomic)
        let resources = try [("environment.spz", "scene.spz"), ("environment.collider", "collider.glb"), ("environment.marble", "marble-runtime.json")].map { kind, path in
            WorldResource(id: kind, path: path, sha256: digest(try Data(contentsOf: stage.appendingPathComponent(path))), kind: kind)
        }
        let manifest = WorldManifest(schemaVersion: 1, packageID: "marble-" + digest(Data(world.id.utf8)), packageVersion: "1.0.0", worldID: world.id,
            displayName: world.name, calibration: WorldCalibration(visualToGameplay: [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1], metersPerUnit: 1),
            spawn:resolved.spawn,collisionVolumes:[],waypoints:[resolved.waypoint],
            routes:[],activities:[],cameras:[resolved.camera],
            capabilities: [], resources: resources)
        guard WorldPackageValidator().validate(manifest, packageRoot: stage).isEmpty else { throw UnityMarbleError.invalidPackage }
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: stage.appendingPathComponent("world.json"), options: .atomic)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination.appendingPathComponent("world.json")) == manifestData,
                  WorldPackageValidator().validate(manifest, packageRoot: destination).isEmpty else { throw UnityMarbleError.packageConflict }
        } else { try FileManager.default.moveItem(at: stage, to: destination) }
        return BundledLivingWorldPackage(manifest: manifest, packageRoot: destination)
    }
}

extension UnityMarblePackageBuilder {
    /// Shared physical cache/decode/package leaf; lifecycle and registration remain Rust.
    static func prepare(world: MarbleWorld, root: URL, cache: MarbleWorldCache,
                        geometry: RustMarbleGeometryClient, blobRoot: URL) async throws -> String {
        guard let asset = world.preferredSplat, world.colliderURL != nil else { throw UnityMarbleError.assetMissing }
        let splat = try await cache.localSplat(for: world, asset: asset)
        guard let collider = try await cache.localCollider(for: world) else { throw UnityMarbleError.assetMissing }
        let package = try await publish(world:world,splat:splat,collider:collider,root:root,geometry:geometry,blobRoot:blobRoot)
        return digest(try Data(contentsOf: package.packageRoot.appendingPathComponent("world.json")))
    }
}
