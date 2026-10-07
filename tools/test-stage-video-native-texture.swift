import AVFoundation
import CoreVideo
import Metal
import ImageIO

private var retainedPixels: CVPixelBuffer?
private var retainedWrapped: CVMetalTexture?
private var retainedTexture: MTLTexture?
private var retainedPlayer: AVPlayer?
private var textureLeases: [(CVPixelBuffer, CVMetalTexture, MTLTexture)] = []

@_cdecl("stage_fixture_texture")
public func stageFixtureTexture() -> UnsafeMutableRawPointer? {
    guard let path = ProcessInfo.processInfo.environment["GMGN_STAGE_VIDEO_FIXTURE_PATH"],
          let device = MTLCreateSystemDefaultDevice() else { return nil }
    do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let pixels: CVPixelBuffer
        if ProcessInfo.processInfo.environment["GMGN_STAGE_VIDEO_FIXTURE_PLAYER"] == "1" {
            let item = AVPlayerItem(asset: asset)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            let player = AVPlayer(playerItem: item); player.isMuted = true; player.volume = 0; player.play()
            var frame: CVPixelBuffer?
            let deadline = Date().addingTimeInterval(8)
            while frame == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                let time = item.currentTime()
                if output.hasNewPixelBuffer(forItemTime: time) { frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) }
            }
            player.pause(); retainedPlayer = player
            guard let frame else { return nil }; pixels = frame
        } else {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
            reader.add(output)
            guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
                  let frame = CMSampleBufferGetImageBuffer(sample) else { return nil }; pixels = frame
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil, .bgra8Unorm,
              CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &wrapped) == kCVReturnSuccess,
              let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else { return nil }
        retainedPixels = pixels; retainedWrapped = wrapped; retainedTexture = texture
        textureLeases.append((pixels, wrapped, texture)); textureLeases = Array(textureLeases.suffix(8))
        if let path = ProcessInfo.processInfo.environment["GMGN_STAGE_VIDEO_FIXTURE_CPU_PNG"] {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                let stride = CVPixelBufferGetBytesPerRow(pixels), height = CVPixelBufferGetHeight(pixels)
                let data = Data(bytes: base, count: stride * height)
                if let provider = CGDataProvider(data: data as CFData),
                   let image = CGImage(width: CVPixelBufferGetWidth(pixels), height: height, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                   let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        return Unmanaged.passUnretained(texture as AnyObject).toOpaque()
    } catch { return nil }
}

@_cdecl("stage_fixture_width") public func stageFixtureWidth() -> Int32 { Int32(retainedTexture?.width ?? 0) }
@_cdecl("stage_fixture_height") public func stageFixtureHeight() -> Int32 { Int32(retainedTexture?.height ?? 0) }
@_cdecl("stage_fixture_pixel")
public func stageFixturePixel(_ x: Int32, _ y: Int32) -> UInt32 {
    guard let pixels = retainedPixels else { return 0 }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixels) else { return 0 }
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let index = Int(y) * CVPixelBufferGetBytesPerRow(pixels) + Int(x) * 4
    return UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index])
}
