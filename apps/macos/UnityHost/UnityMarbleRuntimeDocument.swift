import Foundation
import WorldRuntime

/// Resource-bound geometry contract shared by navigation and the Unity renderer.
/// Source bounds/origin are SplatIO RDF coordinates; gameplay = (source-origin)*scale.
struct UnityMarbleRuntimeDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let worldID: String
    let splatPath: String
    let colliderPath: String
    let colliderAxisConversion: String
    let origin: [Float]
    let uniformScale: Float
    let minimum: [Float]
    let maximum: [Float]

    var colliderTransform: WorldMeshTransform {
        WorldMeshTransform(axisConversion: colliderAxisConversion == "identity" ? .identity : .flipYAndZ,
            origin: SIMD3(origin[0], origin[1], origin[2]), uniformScale: uniformScale)
    }
    func splatURL(package: BundledLivingWorldPackage) -> URL { package.packageRoot.appendingPathComponent(splatPath) }
    func colliderURL(package: BundledLivingWorldPackage) -> URL { package.packageRoot.appendingPathComponent(colliderPath) }

    static func load(package: BundledLivingWorldPackage) throws -> Self? {
        let resources = package.manifest.resources.filter { $0.kind == "environment.marble" }
        guard !resources.isEmpty else { return nil }
        guard resources.count == 1,
              WorldPackageValidator().validate(package.manifest, packageRoot: package.packageRoot).isEmpty else { throw Invalid.invalid }
        let document = try JSONDecoder().decode(Self.self, from: Data(contentsOf: package.packageRoot.appendingPathComponent(resources[0].path)))
        guard document.schemaVersion == 1, document.worldID == package.manifest.worldID,
              ["identity", "flipYAndZ"].contains(document.colliderAxisConversion),
              document.origin.count == 3, document.minimum.count == 3, document.maximum.count == 3,
              (document.origin + document.minimum + document.maximum).allSatisfy(\.isFinite),
              document.uniformScale.isFinite, document.uniformScale > 0,
              zip(document.minimum, document.maximum).allSatisfy({ $0 < $1 }),
              package.manifest.resources.contains(where: { $0.path == document.splatPath && $0.kind == "environment.spz" }),
              package.manifest.resources.contains(where: { $0.path == document.colliderPath && $0.kind == "environment.collider" }) else { throw Invalid.invalid }
        return document
    }
    private enum Invalid: Error { case invalid }
}
