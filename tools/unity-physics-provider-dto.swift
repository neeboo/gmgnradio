import WorldRuntime
// Compile-only exact consumer DTOs; no policy or authority simulation.
enum RustPropCapabilityClient {
    struct Probe: Sendable {let key:String;let position:WorldVector3;let from:WorldVector3?}
    struct Measurement: Sendable {let key:String;let position:WorldVector3;let grounded:WorldVector3?;let canTraverse:Bool}
}
enum WorldAgentContext {
    typealias NativePhysics = @MainActor @Sendable (NativePhysicsRequest) async throws -> [RustPropCapabilityClient.Measurement]
    struct NativePhysicsRequest: Sendable {
        let worldID:String;let hostSessionID:String;let layoutRevision:UInt64;let physicsGeneration:UInt64
        let probes:[RustPropCapabilityClient.Probe];let capsuleRadius:Float;let capsuleHeight:Float
    }
}

@MainActor
func compileNativePhysicsBinding(_ provider: UnityWorldPhysicsProvider?) -> WorldAgentContext.NativePhysics? {
    let nativePhysics: WorldAgentContext.NativePhysics?
    if let provider {
        nativePhysics = { @MainActor @Sendable request in try await provider.measure(request) }
    } else {
        nativePhysics = nil
    }
    return nativePhysics
}
