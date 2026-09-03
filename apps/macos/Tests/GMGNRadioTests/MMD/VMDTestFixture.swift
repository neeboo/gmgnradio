import Foundation

enum VMDTestFixture {
    static func minimalMotion() -> Data {
        var bytes: [UInt8] = []
        appendFixed("Vocaloid Motion Data 0002", length: 30, encoding: .ascii, to: &bytes)
        appendFixed("自作モデル", length: 20, encoding: .shiftJIS, to: &bytes)

        append(UInt32(2), to: &bytes)
        appendBoneFrame(
            name: "上半身",
            frame: 0,
            translation: (0, 0, 0),
            rotation: (0, 0, 0, 1),
            interpolation: (20, 20, 107, 107),
            to: &bytes
        )
        appendBoneFrame(
            name: "上半身",
            frame: 30,
            translation: (1, 2, 3),
            rotation: (0, 0.25881904, 0, 0.9659258),
            interpolation: (32, 8, 96, 120),
            to: &bytes
        )

        append(UInt32(1), to: &bytes)
        appendFixed("笑い", length: 15, encoding: .shiftJIS, to: &bytes)
        append(UInt32(15), to: &bytes)
        append(Float(0.75), to: &bytes)

        // Camera, light, self-shadow and model/IK tracks are intentionally empty.
        append(UInt32(0), to: &bytes)
        append(UInt32(0), to: &bytes)
        append(UInt32(0), to: &bytes)
        append(UInt32(0), to: &bytes)
        return Data(bytes)
    }

    static func malformedMotion() -> Data {
        Data("not a vmd".utf8)
    }

    private static func appendBoneFrame(
        name: String,
        frame: UInt32,
        translation: (Float, Float, Float),
        rotation: (Float, Float, Float, Float),
        interpolation: (UInt8, UInt8, UInt8, UInt8),
        to bytes: inout [UInt8]
    ) {
        appendFixed(name, length: 15, encoding: .shiftJIS, to: &bytes)
        append(frame, to: &bytes)
        append(translation.0, to: &bytes)
        append(translation.1, to: &bytes)
        append(translation.2, to: &bytes)
        append(rotation.0, to: &bytes)
        append(rotation.1, to: &bytes)
        append(rotation.2, to: &bytes)
        append(rotation.3, to: &bytes)

        var block = [UInt8](repeating: 0, count: 64)
        let values = [
            interpolation.0,
            interpolation.1,
            interpolation.2,
            interpolation.3,
        ]
        for controlPointIndex in 0..<4 {
            for channelIndex in 0..<4 {
                block[controlPointIndex * 4 + channelIndex] = values[controlPointIndex]
            }
        }
        bytes.append(contentsOf: block)
    }

    private static func appendFixed(
        _ value: String,
        length: Int,
        encoding: String.Encoding,
        to bytes: inout [UInt8]
    ) {
        let encoded = Array(value.data(using: encoding) ?? Data())
        precondition(encoded.count <= length)
        bytes.append(contentsOf: encoded)
        bytes.append(contentsOf: repeatElement(0, count: length - encoded.count))
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        let value = value.littleEndian
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }

    private static func append(_ value: Float, to bytes: inout [UInt8]) {
        append(value.bitPattern, to: &bytes)
    }
}
