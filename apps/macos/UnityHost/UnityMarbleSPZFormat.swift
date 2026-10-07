import Foundation
import zlib

/// Match the real Unity runtime importer before registering a formal package.
/// Full body/attribute validation is additionally performed by SplatIO.
enum UnityMarbleSPZFormat {
    static func requireRuntimeSupported(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw UnityMarbleError.invalidGeometry }
        defer { inflateEnd(&stream) }
        var header = [UInt8](repeating: 0, count: 16)
        let result = data.withUnsafeBytes { input in
            header.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = UInt32(data.count)
                stream.next_out = output.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = 16
                return inflate(&stream, Z_NO_FLUSH)
            }
        }
        guard [Z_OK, Z_STREAM_END].contains(result), stream.total_out == 16 else { throw UnityMarbleError.invalidGeometry }
        func word(_ offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | (UInt32(header[offset + $1]) << ($1 * 8)) } }
        guard word(0) == 0x5053474e, word(4) == 2, word(8) > 0, word(8) <= 8_600_000, header[12] <= 3, header[13] <= 24 else { throw UnityMarbleError.invalidGeometry }
    }
}
