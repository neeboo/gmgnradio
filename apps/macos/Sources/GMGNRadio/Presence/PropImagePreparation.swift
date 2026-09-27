import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PropImagePreparation {
    /// Decode a bounded thumbnail off the main thread; re-encoding drops EXIF/GPS metadata.
    static func prepare(url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard url.isFileURL,
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 64 * 1024 * 1024,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue * height.doubleValue <= 100_000_000 else { throw PropGenerationError.invalidInput }
            // A noisy 2048px PNG can exceed the API's 8 MiB limit. Bound both pixels and encoded bytes.
            for maxPixelSize in [2048, 1536, 1024] {
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw PropGenerationError.invalidInput }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw PropGenerationError.invalidInput }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw PropGenerationError.invalidInput }
                if data.length <= 8 * 1024 * 1024 { return data as Data }
            }
            throw PropGenerationError.invalidInput
        }.value
    }
}
