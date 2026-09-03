import Foundation

public enum WorldMeshAxisConversion: Sendable {
    case identity
    case flipYAndZ
}

public struct WorldMeshTransform: Sendable {
    public let axisConversion: WorldMeshAxisConversion
    public let origin: SIMD3<Float>
    public let uniformScale: Float

    public init(
        axisConversion: WorldMeshAxisConversion = .identity,
        origin: SIMD3<Float> = .zero,
        uniformScale: Float = 1
    ) {
        self.axisConversion = axisConversion
        self.origin = origin
        self.uniformScale = uniformScale
    }

    public func apply(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let converted: SIMD3<Float> = switch axisConversion {
        case .identity:
            point
        case .flipYAndZ:
            SIMD3(point.x, -point.y, -point.z)
        }
        return (converted - origin) * uniformScale
    }
}

public enum GLBColliderError: Error, Equatable, Sendable {
    case invalidHeader
    case unsupportedVersion(UInt32)
    case invalidChunk
    case missingJSON
    case missingBinary
    case malformedDocument
    case unsupportedPrimitiveMode(Int)
    case unsupportedAccessor
    case indexOutOfRange
}

public struct GLBColliderDecoder: Sendable {
    public init() {}

    public func decode(
        data: Data,
        transform: WorldMeshTransform = WorldMeshTransform()
    ) throws -> [WorldTriangle] {
        let chunks = try chunks(in: data)
        guard let json = chunks.json else { throw GLBColliderError.missingJSON }
        guard let binary = chunks.binary else { throw GLBColliderError.missingBinary }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: json)
        } catch {
            throw GLBColliderError.malformedDocument
        }

        let roots: [Int]
        if let sceneIndex = document.scene,
           document.scenes.indices.contains(sceneIndex)
        {
            roots = document.scenes[sceneIndex].nodes
        } else if let firstScene = document.scenes.first {
            roots = firstScene.nodes
        } else {
            let children = Set(document.nodes.flatMap { $0.children ?? [] })
            roots = document.nodes.indices.filter { !children.contains($0) }
        }

        var result: [WorldTriangle] = []
        for root in roots {
            try appendTriangles(
                nodeIndex: root,
                parentTransform: .identity,
                document: document,
                binary: binary,
                worldTransform: transform,
                ancestors: [],
                result: &result
            )
        }
        return result
    }

    private func appendTriangles(
        nodeIndex: Int,
        parentTransform: Matrix4,
        document: Document,
        binary: Data,
        worldTransform: WorldMeshTransform,
        ancestors: Set<Int>,
        result: inout [WorldTriangle]
    ) throws {
        guard document.nodes.indices.contains(nodeIndex),
              !ancestors.contains(nodeIndex)
        else {
            throw GLBColliderError.indexOutOfRange
        }
        let node = document.nodes[nodeIndex]
        let transform = parentTransform * (try Matrix4(node: node))
        if let meshIndex = node.mesh {
            guard document.meshes.indices.contains(meshIndex) else {
                throw GLBColliderError.indexOutOfRange
            }
            for primitive in document.meshes[meshIndex].primitives {
                let mode = primitive.mode ?? 4
                guard mode == 4 else {
                    throw GLBColliderError.unsupportedPrimitiveMode(mode)
                }
                guard let positionAccessor = primitive.attributes["POSITION"] else {
                    throw GLBColliderError.unsupportedAccessor
                }
                let positions = try readPositions(
                    accessorIndex: positionAccessor,
                    document: document,
                    binary: binary
                ).map { worldTransform.apply(transform.apply($0)) }
                let indices = try readIndices(
                    accessorIndex: primitive.indices,
                    vertexCount: positions.count,
                    document: document,
                    binary: binary
                )
                guard indices.count.isMultiple(of: 3) else {
                    throw GLBColliderError.unsupportedAccessor
                }
                for offset in stride(from: 0, to: indices.count, by: 3) {
                    let first = indices[offset]
                    let second = indices[offset + 1]
                    let third = indices[offset + 2]
                    guard positions.indices.contains(first),
                          positions.indices.contains(second),
                          positions.indices.contains(third)
                    else {
                        throw GLBColliderError.indexOutOfRange
                    }
                    result.append(
                        WorldTriangle(
                            positions[first],
                            positions[second],
                            positions[third]
                        )
                    )
                }
            }
        }

        var nextAncestors = ancestors
        nextAncestors.insert(nodeIndex)
        for child in node.children ?? [] {
            try appendTriangles(
                nodeIndex: child,
                parentTransform: transform,
                document: document,
                binary: binary,
                worldTransform: worldTransform,
                ancestors: nextAncestors,
                result: &result
            )
        }
    }

    private func readPositions(
        accessorIndex: Int,
        document: Document,
        binary: Data
    ) throws -> [SIMD3<Float>] {
        guard document.accessors.indices.contains(accessorIndex) else {
            throw GLBColliderError.indexOutOfRange
        }
        let accessor = document.accessors[accessorIndex]
        guard accessor.componentType == 5126,
              accessor.type == "VEC3",
              let viewIndex = accessor.bufferView,
              document.bufferViews.indices.contains(viewIndex)
        else {
            throw GLBColliderError.unsupportedAccessor
        }
        let view = document.bufferViews[viewIndex]
        guard view.buffer == 0 else { throw GLBColliderError.unsupportedAccessor }
        let stride = view.byteStride ?? 12
        guard stride >= 12 else { throw GLBColliderError.unsupportedAccessor }
        let start = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        guard accessor.count >= 0,
              start >= 0,
              accessor.count == 0
                || start + (accessor.count - 1) * stride + 12 <= binary.count
        else {
            throw GLBColliderError.indexOutOfRange
        }
        return try (0 ..< accessor.count).map { index in
            let offset = start + index * stride
            return SIMD3(
                try binary.float32(at: offset),
                try binary.float32(at: offset + 4),
                try binary.float32(at: offset + 8)
            )
        }
    }

    private func readIndices(
        accessorIndex: Int?,
        vertexCount: Int,
        document: Document,
        binary: Data
    ) throws -> [Int] {
        guard let accessorIndex else { return Array(0 ..< vertexCount) }
        guard document.accessors.indices.contains(accessorIndex) else {
            throw GLBColliderError.indexOutOfRange
        }
        let accessor = document.accessors[accessorIndex]
        guard accessor.type == "SCALAR",
              let viewIndex = accessor.bufferView,
              document.bufferViews.indices.contains(viewIndex)
        else {
            throw GLBColliderError.unsupportedAccessor
        }
        let byteWidth: Int = switch accessor.componentType {
        case 5121: 1
        case 5123: 2
        case 5125: 4
        default: throw GLBColliderError.unsupportedAccessor
        }
        let view = document.bufferViews[viewIndex]
        guard view.buffer == 0 else { throw GLBColliderError.unsupportedAccessor }
        let stride = view.byteStride ?? byteWidth
        guard stride >= byteWidth else { throw GLBColliderError.unsupportedAccessor }
        let start = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        guard accessor.count >= 0,
              start >= 0,
              accessor.count == 0
                || start + (accessor.count - 1) * stride + byteWidth <= binary.count
        else {
            throw GLBColliderError.indexOutOfRange
        }
        return try (0 ..< accessor.count).map { index in
            let offset = start + index * stride
            return switch accessor.componentType {
            case 5121: Int(try binary.uint8(at: offset))
            case 5123: Int(try binary.uint16(at: offset))
            case 5125: Int(try binary.uint32(at: offset))
            default: throw GLBColliderError.unsupportedAccessor
            }
        }
    }

    private func chunks(in data: Data) throws -> (json: Data?, binary: Data?) {
        guard data.count >= 12,
              try data.uint32(at: 0) == 0x46546C67
        else {
            throw GLBColliderError.invalidHeader
        }
        let version = try data.uint32(at: 4)
        guard version == 2 else { throw GLBColliderError.unsupportedVersion(version) }
        let declaredLength = Int(try data.uint32(at: 8))
        guard declaredLength == data.count else { throw GLBColliderError.invalidHeader }

        var json: Data?
        var binary: Data?
        var offset = 12
        while offset < data.count {
            guard offset + 8 <= data.count else { throw GLBColliderError.invalidChunk }
            let length = Int(try data.uint32(at: offset))
            let type = try data.uint32(at: offset + 4)
            let start = offset + 8
            let end = start + length
            guard length >= 0, end <= data.count else {
                throw GLBColliderError.invalidChunk
            }
            switch type {
            case 0x4E4F534A where json == nil:
                json = data.subdata(in: start ..< end)
            case 0x004E4942 where binary == nil:
                binary = data.subdata(in: start ..< end)
            default:
                break
            }
            offset = end
        }
        return (json, binary)
    }
}

private struct Document: Decodable {
    let scene: Int?
    let scenes: [Scene]
    let nodes: [Node]
    let meshes: [Mesh]
    let accessors: [Accessor]
    let bufferViews: [BufferView]

    private enum CodingKeys: String, CodingKey {
        case scene, scenes, nodes, meshes, accessors, bufferViews
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scene = try container.decodeIfPresent(Int.self, forKey: .scene)
        scenes = try container.decodeIfPresent([Scene].self, forKey: .scenes) ?? []
        nodes = try container.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        meshes = try container.decodeIfPresent([Mesh].self, forKey: .meshes) ?? []
        accessors = try container.decodeIfPresent([Accessor].self, forKey: .accessors) ?? []
        bufferViews = try container.decodeIfPresent([BufferView].self, forKey: .bufferViews) ?? []
    }
}

private struct Scene: Decodable { let nodes: [Int] }

private struct Node: Decodable {
    let mesh: Int?
    let children: [Int]?
    let matrix: [Float]?
    let translation: [Float]?
    let rotation: [Float]?
    let scale: [Float]?
}

private struct Mesh: Decodable { let primitives: [Primitive] }
private struct Primitive: Decodable {
    let attributes: [String: Int]
    let indices: Int?
    let mode: Int?
}

private struct Accessor: Decodable {
    let bufferView: Int?
    let byteOffset: Int?
    let componentType: Int
    let count: Int
    let type: String
}

private struct BufferView: Decodable {
    let buffer: Int
    let byteOffset: Int?
    let byteStride: Int?
}

private struct Matrix4 {
    var values: [Float]

    static let identity = Matrix4(values: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])

    init(values: [Float]) {
        self.values = values
    }

    init(node: Node) throws {
        if let matrix = node.matrix {
            guard matrix.count == 16, matrix.allSatisfy(\.isFinite) else {
                throw GLBColliderError.malformedDocument
            }
            values = matrix
            return
        }
        let translation = node.translation ?? [0, 0, 0]
        let rotation = node.rotation ?? [0, 0, 0, 1]
        let scale = node.scale ?? [1, 1, 1]
        guard translation.count == 3, rotation.count == 4, scale.count == 3,
              (translation + rotation + scale).allSatisfy(\.isFinite)
        else {
            throw GLBColliderError.malformedDocument
        }
        let length = sqrt(rotation.reduce(0) { $0 + $1 * $1 })
        guard length > 0.000001 else { throw GLBColliderError.malformedDocument }
        let x = rotation[0] / length
        let y = rotation[1] / length
        let z = rotation[2] / length
        let w = rotation[3] / length
        let sx = scale[0], sy = scale[1], sz = scale[2]
        values = [
            (1 - 2 * (y * y + z * z)) * sx,
            (2 * (x * y + z * w)) * sx,
            (2 * (x * z - y * w)) * sx,
            0,
            (2 * (x * y - z * w)) * sy,
            (1 - 2 * (x * x + z * z)) * sy,
            (2 * (y * z + x * w)) * sy,
            0,
            (2 * (x * z + y * w)) * sz,
            (2 * (y * z - x * w)) * sz,
            (1 - 2 * (x * x + y * y)) * sz,
            0,
            translation[0], translation[1], translation[2], 1,
        ]
    }

    func apply(_ point: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            values[0] * point.x + values[4] * point.y + values[8] * point.z + values[12],
            values[1] * point.x + values[5] * point.y + values[9] * point.z + values[13],
            values[2] * point.x + values[6] * point.y + values[10] * point.z + values[14]
        )
    }

    static func * (lhs: Self, rhs: Self) -> Self {
        var result = Array(repeating: Float.zero, count: 16)
        for column in 0 ..< 4 {
            for row in 0 ..< 4 {
                result[column * 4 + row] = (0 ..< 4).reduce(0) { partial, index in
                    partial + lhs.values[index * 4 + row] * rhs.values[column * 4 + index]
                }
            }
        }
        return Matrix4(values: result)
    }
}

private extension Data {
    func uint8(at offset: Int) throws -> UInt8 {
        guard indices.contains(offset) else { throw GLBColliderError.indexOutOfRange }
        return self[offset]
    }

    func uint16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw GLBColliderError.indexOutOfRange
        }
        return withUnsafeBytes {
            UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw GLBColliderError.indexOutOfRange
        }
        return withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    func float32(at offset: Int) throws -> Float {
        Float(bitPattern: try uint32(at: offset))
    }
}
