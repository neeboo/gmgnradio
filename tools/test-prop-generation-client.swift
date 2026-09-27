import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let files = ["PropGenerationClient", "PropImagePreparation"].map {
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/\($0).swift")
}
guard files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
    print("FAIL: image generation core is missing")
    exit(1)
}
let program = #"""
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class Stub: URLProtocol {
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    static var body = Data()
    static var status = 200
    static var fail = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let body = request.httpBody { Self.bodies.append(body) }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer.prefix(n))
            }
            Self.bodies.append(data)
        }
        if Self.fail { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        finish()
    }
    func finish() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { guard value else { fatalError("FAIL: " + label) }; count += 1 }
        func rejects(_ label: String, _ action: () throws -> Void) { do { try action(); fatalError("FAIL: " + label) } catch { count += 1 } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let session = URLSession(configuration: config)
        let endpoint = URL(string: "http://127.0.0.1:8191")!
        for invalid in ["http://example.com", "https://u:p@example.com", "https://example.com?token=x", "file:///tmp/a", "https://example.com/path"] {
            rejects("unsafe endpoint rejected") { _ = try PropGenerationClient(endpoint: URL(string: invalid)!, token: "secret", session: session) }
        }
        let client = try PropGenerationClient(endpoint: endpoint, token: "secret", session: session)
        Stub.body = Data(#"{"status":"api_ready","generation":{"ready":true}}"#.utf8)
        let ready = try await client.health()
        check(ready.isReady && ready.message == "许愿机已就绪，可以生成道具。", "service health reports real generation readiness")
        check(Stub.requests.last?.url?.path == "/health" && Stub.requests.last?.httpMethod == "GET"
              && Stub.requests.last?.httpBody == nil, "health never creates a generation task")
        check(Stub.requests.last?.timeoutInterval == 5, "connection check has a short timeout")
        check(Stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer secret", "health uses stored credentials")
        Stub.body = Data(#"{"status":"api_ready","generation":{"ready":false,"reason":"shared_memory_busy"}}"#.utf8)
        let waiting = try await client.health()
        check(!waiting.isReady && waiting.message.contains("等待"), "connected service can still be waiting for generation resources")
        Stub.body = Data(#"{"status":"api_ready","generation":{"ready":false,"reason":"secret/path/private"}}"#.utf8)
        let unknown = try await client.health()
        check(!unknown.isReady && !unknown.message.contains("secret/path"), "unknown service detail is not copied into UI")
        Stub.body = Data(#"{"status":"unrecognized","generation":{"ready":true}}"#.utf8)
        do { _ = try await client.health(); fatalError("FAIL: unknown health schema accepted") }
        catch PropGenerationError.invalidResponse { count += 1 }
        Stub.status = 401
        do { _ = try await client.health(); fatalError("FAIL: unauthorized health accepted") }
        catch PropGenerationError.http(401) { count += 1 }
        Stub.status = 200
        rejects("cross origin model URL") { _ = try client.modelURL(path: "https://evil.example/a.glb", jobID: String(repeating: "a", count: 32)) }
        rejects("other job model URL") { _ = try client.modelURL(path: "/v1/jobs/other/model.glb", jobID: String(repeating: "a", count: 32)) }
        let fixture = #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","state":"interrupted","reason":"service_restarted_no_resubmit","name":"coffee","source":{"author":"me","license":"own"},"height_meters":0.42,"result":null,"compute_may_continue":true,"created_at":1,"updated_at":2}"#
        Stub.body = Data(fixture.utf8)
        let receipt = try await client.status(id: String(repeating: "a", count: 32))
        check(receipt.state == .interrupted && receipt.computeMayContinue, "typed state and compute warning decoded")
        check(Stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer secret", "authentication on private request")
        var completedJSON = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
        completedJSON["state"] = "completed"
        completedJSON["compute_may_continue"] = false
        completedJSON["result"] = ["model_url": "/v1/jobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/model.glb", "suggested_height_meters": 0.42,
            "scale_requires_confirmation": true, "interaction_status": "unbound", "workflow_profile": "trellis2-prop-low-v1",
            "source": ["author": "me", "license": "own"], "affordance_candidates": ["inspect", "place"], "interaction_bindings": [],
            "inspection": ["sha256": "abc", "bytes": 20, "triangles": 12, "primitives": 1, "materials": 1, "accessors": 1,
                "accessor_bounds": ["0": ["min": [0,0,0], "max": [1,1,1]]],
                "bounds": ["min": [0,0,0], "max": [1,1,1], "dimensions": [1,1,1], "units": "model_units", "space": "mesh_local"],
                "scale_calibrated": false, "meters_per_model_unit": NSNull(), "scene_transform_count": 0]]
        Stub.body = try JSONSerialization.data(withJSONObject: completedJSON)
        let completed = try await client.status(id: receipt.id)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(completed)) as! [String: Any]
        let resultJSON = encoded["result"] as! [String: Any]
        check(resultJSON["inspection"] != nil && resultJSON["affordance_candidates"] != nil, "receipt retains inspection and interaction metadata")
        Stub.body = Data(fixture.utf8)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("input.png")
        let pixels = [UInt8](repeating: 200, count: 64 * 32 * 4)
        let cg = CGImage(width: 64, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 42]] as CFDictionary)
        check(CGImageDestinationFinalize(dest), "image fixture")
        let png = try await PropImagePreparation.prepare(url: source)
        let imageSource = CGImageSourceCreateWithData(png as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)! as NSDictionary
        check(props[kCGImagePropertyGPSDictionary] == nil && png.count <= 8 * 1024 * 1024, "prepared PNG strips location metadata")
        let submissionSource = PropGenerationSource(author: "me", license: "own")
        let submissionKey = UUID().uuidString
        Stub.fail = true
        do {
            _ = try await client.submit(png: png, name: "coffee", source: submissionSource,
                heightMeters: 0.42, idempotencyKey: submissionKey)
            fatalError("FAIL: uncertain submit accepted")
        } catch { count += 1 }
        let submittedJSON = try JSONSerialization.jsonObject(with: Stub.bodies.last!) as! [String: Any]
        check(Set(submittedJSON.keys) == ["image_base64", "name", "source", "height_meters"],
              "submission matches exact snake case contract")
        check(submittedJSON["height_meters"] as? Double == 0.42
              && Data(base64Encoded: submittedJSON["image_base64"] as! String) == png,
              "submitted dimensions and normalized image are exact")
        check(Stub.requests.last?.value(forHTTPHeaderField: "Idempotency-Key") == submissionKey,
              "submission preserves caller allocated idempotency key")
        Stub.fail = false
        let retried = try await client.submit(png: png, name: "coffee", source: submissionSource,
            heightMeters: 0.42, idempotencyKey: submissionKey)
        check(retried.state == .interrupted
              && Stub.requests.last?.value(forHTTPHeaderField: "Idempotency-Key") == submissionKey,
              "explicit retry can reuse exact request identity")
        rejects("invalid height rejected") {
            try PropGenerationClient.validateInput(png: png, name: "coffee", source: submissionSource, heightMeters: 4)
        }
        rejects("empty attribution rejected") {
            try PropGenerationClient.validateInput(png: png, name: "coffee",
                source: PropGenerationSource(author: "", license: "own"), heightMeters: 0.42)
        }
        let noisyURL = dir.appendingPathComponent("noise.png")
        var random: UInt32 = 17
        let noisyPixels: [UInt8] = (0..<(2048 * 2048 * 4)).map { _ in
            random ^= random << 13; random ^= random >> 17; random ^= random << 5
            return UInt8(truncatingIfNeeded: random)
        }
        let noisyImage = CGImage(width: 2048, height: 2048, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 2048 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(noisyPixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let noisyDestination = CGImageDestinationCreateWithURL(noisyURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(noisyDestination, noisyImage, nil)
        check(CGImageDestinationFinalize(noisyDestination), "large PNG fixture")
        let reduced = try await PropImagePreparation.prepare(url: noisyURL)
        check(reduced.count <= 8 * 1024 * 1024, "large valid PNG is reduced to API byte limit")
        let badImage = dir.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: badImage)
        do { _ = try await PropImagePreparation.prepare(url: badImage); fatalError("FAIL: bad image accepted") } catch { count += 1 }
        var glb = Data([0x67,0x6c,0x54,0x46,2,0,0,0,20,0,0,0,0,0,0,0,0x4a,0x53,0x4f,0x4e])
        try PropGenerationClient.validateGLB(glb)
        Stub.body = glb
        let downloaded = try await client.download(completed)
        check(downloaded == glb && Stub.requests.last?.url?.path.hasSuffix("/model.glb") == true, "completed result downloads from exact private route")
        glb[8] = 21
        rejects("GLB byte length verified") { try PropGenerationClient.validateGLB(glb) }
        rejects("GLB size bounded") { try PropGenerationClient.validateGLB(Data(count: 32 * 1024 * 1024 + 1)) }
        Stub.body = Data(fixture.utf8)
        _ = try await client.cancel(id: receipt.id)
        check(Stub.requests.last?.httpMethod == "POST" && Stub.bodies.last == Data("{}".utf8), "cancel posts exact empty JSON")
        Stub.status = 401
        do { _ = try await client.status(id: receipt.id); fatalError("FAIL: unauthorized accepted") }
        catch { check(error.localizedDescription.contains("401") && !error.localizedDescription.contains("secret"), "service errors sanitized") }
        Stub.status = 200
        print("PASS: \(count) prop generation checks")
    }
}
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("prop-generation-check-" + UUID().uuidString)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let test = tmp.appendingPathComponent("checks.swift"), binary = tmp.appendingPathComponent("checks")
try program.write(to: test, atomically: true, encoding: .utf8)
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
compile.arguments = ["-n", "15", "swiftc", "-j1", "-parse-as-library"] + files.map(\.path) + [test.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit(); guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let run = Process(); run.executableURL = binary; try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
