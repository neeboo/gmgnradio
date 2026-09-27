// Offline red/green checks for the resident public-reference-image downloader.
// No network, no app, no daemon, no GPU: a scripted resolver/transport drives the
// real production validation logic, and a local fake curl subprocess (this same
// test binary re-entered with a production-shaped argv) exercises the real
// curl-based process transport, bounded streaming read, timeouts and reaping.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentWebImageDownloader.swift")
let preparation = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropImagePreparation.swift")
let generation = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift")
guard FileManager.default.fileExists(atPath: source.path),
      FileManager.default.fileExists(atPath: preparation.path) else {
    print("FAIL: resident web image downloader is missing")
    exit(1)
}
let harness = #"""
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Local fixtures

func fixtureImage(_ type: UTType, width: Int, height: Int, metadata: [CFString: Any]? = nil) -> Data {
    let pixels = [UInt8](repeating: 200, count: width * height * 4)
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, metadata as CFDictionary?)
    guard CGImageDestinationFinalize(destination) else { fatalError("fixture image failed") }
    return data as Data
}

func decodes(_ data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    return CGImageSourceGetCount(source) > 0
}

func fakePath(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
}

func fakeURL(_ kind: String, record: URL? = nil) -> URL {
    var text = "https://example.com/\(kind)"
    if let record { text += "/" + fakePath(record.path) }
    return URL(string: text)!
}

/// Encodes the harness's inheritable sentinel descriptor number in the path so
/// the re-entered fake curl child can check whether the transport leaked it.
func fakeSentinelURL(descriptor: Int32, record: URL) -> URL {
    URL(string: "https://example.com/sentinel/\(descriptor)/" + fakePath(record.path))!
}

func helperValue(_ flag: String, _ arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Spawns this test binary in `--hold` mode with no redirection, so the
/// grandchild inherits this child's stdout (the transport's pipe) and keeps the
/// write end open while the direct child is killed. This is the only way to
/// observe that the transport aborts its read instead of waiting for EOF.
func spawnStdoutHolder(seconds: String, pidFile: String) -> pid_t {
    let binary = CommandLine.arguments[0]
    var pid: pid_t = 0
    var argv: [UnsafeMutablePointer<CChar>?] = [
        strdup(binary), strdup("--hold"), strdup(seconds), strdup(pidFile), nil
    ]
    var envp: [UnsafeMutablePointer<CChar>?] = [nil]
    let result: Int32 = argv.withUnsafeMutableBufferPointer { arguments in
        envp.withUnsafeMutableBufferPointer { environment in
            posix_spawn(&pid, binary, nil, nil, arguments.baseAddress, environment.baseAddress)
        }
    }
    for pointer in argv where pointer != nil { free(pointer) }
    for pointer in envp where pointer != nil { free(pointer) }
    return result == 0 ? pid : -1
}

// MARK: - Re-entrant fake curl

func runFakeCurl() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let text = arguments.last, let url = URL(string: text) else { exit(3) }
    let components = url.pathComponents
    let kind = components.count > 1 ? components[1] : ""
    let recordPath = components.count > 2 ? components[2] : nil
    func emit(_ header: String, _ body: Data) {
        FileHandle.standardOutput.write(Data(header.utf8))
        if !body.isEmpty { FileHandle.standardOutput.write(body) }
    }
    func record() {
        guard let recordPath else { return }
        let payload: [String: Any] = ["arguments": arguments, "environment": ProcessInfo.processInfo.environment]
        try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: URL(fileURLWithPath: recordPath))
    }
    let png = fixtureImage(.png, width: 8, height: 8)
    switch kind {
    case "ok":
        emit("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\n\r\n", png)
    case "record":
        record()
        emit("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\n\r\n", png)
    case "sentinel":
        // The harness opened this descriptor without CLOEXEC and encoded its
        // number in the URL. POSIX_SPAWN_CLOEXEC_DEFAULT must close it in this
        // child even though nothing in the argv or environment mentions it.
        let descriptor = Int32(components.count > 2 ? components[2] : "") ?? -1
        let sentinelRecord = components.count > 3 ? components[3] : nil
        let openInChild = descriptor >= 0 ? fcntl(descriptor, F_GETFD) != -1 : true
        if let sentinelRecord {
            let payload: [String: Any] = ["sentinelDescriptor": Int(descriptor), "sentinelOpenInChild": openInChild]
            try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: sentinelRecord))
        }
        emit("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\n\r\n", png)
    case "chunked":
        emit("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nTransfer-Encoding: chunked\r\n\r\n", png)
    case "unknown":
        emit("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n", png)
    case "huge":
        emit("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n", Data(repeating: 65, count: 2 * 1024 * 1024))
    case "okexit7":
        emit("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\n\r\n", png)
        exit(7)
    case "linger":
        // Full response and stdout EOF first, then a delay before the real exit.
        // A transport that kills on success would prevent the marker file below.
        emit("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\n\r\n", png)
        try? FileHandle.standardOutput.close()
        sleep(1)
        if let recordPath {
            try? Data("done".utf8).write(to: URL(fileURLWithPath: recordPath))
        }
        exit(0)
    case "redirect":
        let second = (recordPath ?? "hop") + ".hop2"
        let location = "https://cdn.example.com/record/" + fakePath(second)
        emit("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\n\r\n", Data())
    case "hang":
        if let recordPath {
            try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: URL(fileURLWithPath: recordPath))
        }
        sleep(120)
    case "stubbornok":
        // Ignore SIGTERM so the only way this child ends is its own natural exit.
        // A cancelled request must not be reported as success just because the
        // exit status happens to be zero.
        signal(SIGTERM, SIG_IGN)
        emit("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\n\r\n", png)
        try? FileHandle.standardOutput.close()
        if let recordPath {
            try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: URL(fileURLWithPath: recordPath))
        }
        sleep(1)
        exit(0)
    case "orphanstdout":
        // A descendant inherits stdout and holds it open. Killing the direct
        // child therefore never produces EOF, so a transport that blocks on read
        // hangs until the descendant happens to exit.
        let holderPath = (recordPath ?? "orphan-holder") + ".holder"
        _ = spawnStdoutHolder(seconds: "30", pidFile: holderPath)
        if let recordPath {
            try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: URL(fileURLWithPath: recordPath))
        }
        sleep(120)
    default:
        exit(4)
    }
}

// MARK: - Scripted collaborators

final class RecordingResolver: ResidentWebImageAddressResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: [String]] = [:]
    private var failing: Set<String> = []
    private var queried: [String] = []

    func set(_ host: String, _ addresses: [String]) {
        lock.lock(); table[host] = addresses; lock.unlock()
    }
    func fail(_ host: String) {
        lock.lock(); failing.insert(host); lock.unlock()
    }
    var hosts: [String] {
        lock.lock(); defer { lock.unlock() }; return queried
    }
    func ipv4Addresses(forHost host: String) async throws -> [String] {
        // NSLock.lock()/unlock() are unavailable from async contexts in Swift 6,
        // so the scoped read stays in a synchronous `withLock` closure.
        let (addresses, failing) = lock.withLock { () -> ([String]?, Bool) in
            queried.append(host)
            return (table[host], self.failing.contains(host))
        }
        if failing { throw ResidentWebImageError.dnsFailure }
        guard let addresses else { throw ResidentWebImageError.dnsFailure }
        return addresses
    }
}

/// Resolver that parks inside its await until the test releases it. This makes
/// the "cancel while the resolver await is in flight" window deterministic.
final class GatedResolver: ResidentWebImageAddressResolving, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    func release() { gate.signal() }

    func ipv4Addresses(forHost host: String) async throws -> [String] {
        entered.signal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                self.gate.wait()
                continuation.resume()
            }
        }
        return ["93.184.216.34"]
    }
}

final class ScriptedTransport: ResidentWebImageTransporting, @unchecked Sendable {
    struct Call: Sendable {
        let url: URL
        let host: String
        let address: String
        let maximumBytes: Int
    }
    private let lock = NSLock()
    private var calls: [Call] = []
    private var handler: (@Sendable (ResidentWebImageTransportRequest) throws -> ResidentWebImageRawResponse)?

    init(_ handler: (@Sendable (ResidentWebImageTransportRequest) throws -> ResidentWebImageRawResponse)? = nil) {
        self.handler = handler
    }
    func setHandler(_ handler: @escaping @Sendable (ResidentWebImageTransportRequest) throws -> ResidentWebImageRawResponse) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    var recordedCalls: [Call] {
        lock.lock(); defer { lock.unlock() }; return calls
    }
    func resetCalls() {
        lock.lock(); calls.removeAll(); lock.unlock()
    }
    func perform(_ request: ResidentWebImageTransportRequest) async throws -> ResidentWebImageRawResponse {
        // As above: the lock scope is synchronous so Swift 6 accepts it.
        let handler = lock.withLock { () -> (@Sendable (ResidentWebImageTransportRequest) throws -> ResidentWebImageRawResponse)? in
            calls.append(Call(url: request.url, host: request.host, address: request.address, maximumBytes: request.maximumBytes))
            return self.handler
        }
        guard let handler else { throw ResidentWebImageError.transportFailure("no-script") }
        return try handler(request)
    }
}

func raw(_ status: Int, _ headers: [String: String], _ body: Data) -> ResidentWebImageRawResponse {
    ResidentWebImageRawResponse(statusCode: status, headers: headers, body: body)
}

func parseStream(_ chunks: [Data], maximum: Int) throws -> ResidentWebImageRawResponse {
    var stream = ResidentWebImageResponseStream(maximumBytes: maximum)
    for chunk in chunks { try stream.consume(chunk) }
    return try stream.finish()
}

func waitForFile(_ url: URL, timeout: TimeInterval = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}

/// Synchronous bridge for `DispatchSemaphore.wait`, which is unavailable from
/// async contexts in Swift 6.
func waitForSemaphore(_ semaphore: DispatchSemaphore, timeout: DispatchTime) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
}

func readStoredPID(_ url: URL) -> Int32 {
    let text = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return Int32(text) ?? -1
}

func alive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0
}

func waitForDeath(_ pid: Int32, timeout: TimeInterval = 5) async -> Bool {
    guard pid > 0 else { return false }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !alive(pid) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return !alive(pid)
}

// MARK: - Checks

@main struct Checks {
    static func main() async throws {
        // Re-entrant mode for the stdout-holding descendant that `orphanstdout`
        // spawns: record the pid, then keep the inherited stdout open.
        if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--hold" {
            let seconds = UInt32(CommandLine.arguments[2]) ?? 30
            if let data = "\(ProcessInfo.processInfo.processIdentifier)".data(using: .utf8) {
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            }
            sleep(seconds)
            exit(0)
        }
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--disable" { runFakeCurl(); return }
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(message)") }
        }
        func rejected(_ label: String, _ matches: @escaping (ResidentWebImageError) -> Bool = { _ in true },
                      _ body: () async throws -> Void) async {
            do {
                try await body()
                checks += 1; failures += 1; print("FAIL(accepted): \(label)")
            } catch let error as ResidentWebImageError {
                checks += 1
                if !matches(error) { failures += 1; print("FAIL(wrong error \(error)): \(label)") }
            } catch {
                checks += 1; failures += 1; print("FAIL(other error \(error)): \(label)")
            }
        }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-web-image-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let checkBinary = URL(fileURLWithPath: CommandLine.arguments[0])

        // The production default must never use the local system resolver: the
        // proxy in front of this machine answers public names with a benchmarking
        // fake IP (for example 198.18.0.161) that screening then refuses.
        check(ResidentWebImageDownloader.makeDefaultResolver() is ResidentWebImagePublicDNSResolver,
            "default resolver is the pinned public DoH resolver")
        check(!(ResidentWebImageDownloader.makeDefaultResolver() is ResidentWebImageSystemResolver),
            "default resolver never falls back to the fake-IP-polluted system resolver")

        let png = fixtureImage(.png, width: 8, height: 8)
        let jpeg = fixtureImage(.jpeg, width: 8, height: 8)
        let gpsJPEG = fixtureImage(.jpeg, width: 8, height: 8,
            metadata: [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 42.0, kCGImagePropertyGPSLongitude: 13.0]])
        let html = Data("<html><body>not an image</body></html>".utf8)
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)

        // 1. curl argv: curlrc first, no proxy/redirect/TLS downgrade/credentials, exact IP pin.
        let sample = ResidentWebImageTransportRequest(url: URL(string: "https://example.com/a.png")!,
            host: "example.com", address: "93.184.216.34", maximumBytes: 4096, timeout: 30)
        let arguments = ResidentWebImageCurlTransport.arguments(for: sample)
        check(arguments.first == "--disable", "curlrc is disabled as the first argument")
        check(helperValue("--proxy", arguments) == "", "proxy is overridden to empty")
        check(helperValue("--noproxy", arguments) == "*", "noproxy wildcard is set")
        check(helperValue("--proto", arguments) == "=https", "https is the only allowed protocol")
        check(helperValue("--resolve", arguments) == "example.com:443:93.184.216.34",
            "validated public IPv4 is pinned to the exact hostname on 443")
        check(!arguments.contains("--location") && !arguments.contains("-L") && !arguments.contains("--max-redirs"),
            "automatic redirects are never enabled")
        check(!arguments.contains("--insecure") && !arguments.contains("-k") && !arguments.contains("--cacert"),
            "TLS verification is never weakened")
        check(helperValue("--cookie", arguments) == nil && helperValue("-b", arguments) == nil
            && helperValue("--user", arguments) == nil && helperValue("-u", arguments) == nil,
            "no cookie or auth credentials are attached")
        check(helperValue("--request", arguments) == "GET", "the method is pinned to GET")
        check(arguments.last == sample.url.absoluteString && arguments[arguments.count - 2] == "--",
            "url is the final explicit operand after --")
        let literal = ResidentWebImageTransportRequest(url: URL(string: "https://93.184.216.34/a.png")!,
            host: "93.184.216.34", address: "93.184.216.34", maximumBytes: 4096, timeout: 30)
        check(helperValue("--resolve", ResidentWebImageCurlTransport.arguments(for: literal)) == nil,
            "an IP-literal host is already pinned by the URL itself")

        // 2. URL shape validation.
        let resolver = RecordingResolver()
        resolver.set("example.com", ["93.184.216.34"])
        let transport = ScriptedTransport { _ in raw(200, ["content-type": "image/png"], png) }
        let downloader = ResidentWebImageDownloader(resolver: resolver, transport: transport)
        await rejected("http scheme rejected", { $0 == .unsupportedScheme }) {
            _ = try await downloader.fetchPublicData(URL(string: "http://example.com/a.png")!, maximumBytes: 4096)
        }
        await rejected("file scheme rejected", { $0 == .unsupportedScheme }) {
            _ = try await downloader.fetchPublicData(URL(string: "file:///tmp/a.png")!, maximumBytes: 4096)
        }
        await rejected("non standard port rejected", { $0 == .unsupportedPort }) {
            _ = try await downloader.fetchPublicData(URL(string: "https://example.com:8443/a.png")!, maximumBytes: 4096)
        }
        await rejected("userinfo rejected", { $0 == .invalidURL }) {
            _ = try await downloader.fetchPublicData(URL(string: "https://user:pass@example.com/a.png")!, maximumBytes: 4096)
        }
        await rejected("fragment rejected", { $0 == .invalidURL }) {
            _ = try await downloader.fetchPublicData(URL(string: "https://example.com/a.png#frag")!, maximumBytes: 4096)
        }
        for hostile in ["https://example.com/a\u{01}.png", "https://example.com/a\u{7f}.png"] {
            if let url = URL(string: hostile) {
                await rejected("control character rejected", { $0 == .invalidURL }) {
                    _ = try await downloader.fetchPublicData(url, maximumBytes: 4096)
                }
            } else {
                check(true, "control character url is unparseable")
            }
        }
        await rejected("IPv6 literal rejected", { $0 == .ipv6Unsupported }) {
            _ = try await downloader.fetchPublicData(URL(string: "https://[2606:4700:4700::1111]/a.png")!, maximumBytes: 4096)
        }
        for local in ["https://localhost/a.png", "https://foo.local/a.png", "https://printer.local/a.png"] {
            await rejected("local name \(local) rejected", { if case .nonPublicAddress = $0 { return true }; return false }) {
                _ = try await downloader.fetchPublicData(URL(string: local)!, maximumBytes: 4096)
            }
        }
        await rejected("zero maximum rejected", { $0 == .invalidArgument }) {
            _ = try await downloader.fetchPublicData(URL(string: "https://example.com/a.png")!, maximumBytes: 0)
        }

        // 3. DNS screening: every non-public IPv4 class is refused, mixed answers are refused.
        let privateHosts: [(String, String)] = [
            ("a.example", "0.0.0.1"), ("b.example", "10.1.2.3"), ("c.example", "100.64.0.1"),
            ("d.example", "127.0.0.1"), ("e.example", "169.254.10.1"), ("f.example", "172.16.5.5"),
            ("g.example", "172.31.255.255"), ("h.example", "192.0.0.1"), ("i.example", "192.0.2.10"),
            ("j.example", "192.88.99.1"), ("k.example", "192.168.1.1"), ("l.example", "198.18.0.1"),
            ("m.example", "198.51.100.7"), ("n.example", "203.0.113.9"), ("o.example", "224.0.0.1"),
            ("p.example", "240.0.0.1"), ("q.example", "255.255.255.255")
        ]
        let privateTransport = ScriptedTransport { _ in raw(200, ["content-type": "image/png"], png) }
        let privateDownloader = ResidentWebImageDownloader(resolver: resolver, transport: privateTransport)
        for (host, address) in privateHosts {
            resolver.set(host, [address])
            await rejected("non public IPv4 \(address) rejected", { if case .nonPublicAddress = $0 { return true }; return false }) {
                _ = try await privateDownloader.fetchPublicData(URL(string: "https://\(host)/a.png")!, maximumBytes: 4096)
            }
        }
        resolver.set("mixed.example", ["93.184.216.34", "10.0.0.1"])
        await rejected("mixed public/private DNS rejected", { $0 == .mixedPublicPrivateDNS }) {
            _ = try await privateDownloader.fetchPublicData(URL(string: "https://mixed.example/a.png")!, maximumBytes: 4096)
        }
        resolver.set("mixedloop.example", ["127.0.0.1", "93.184.216.34"])
        await rejected("mixed public/loopback DNS rejected", { $0 == .mixedPublicPrivateDNS }) {
            _ = try await privateDownloader.fetchPublicData(URL(string: "https://mixedloop.example/a.png")!, maximumBytes: 4096)
        }
        resolver.set("v6.example", ["2606:4700:4700::1111"])
        await rejected("IPv6-only DNS rejected", { $0 == .ipv6Unsupported }) {
            _ = try await privateDownloader.fetchPublicData(URL(string: "https://v6.example/a.png")!, maximumBytes: 4096)
        }
        resolver.set("empty.example", [])
        await rejected("empty DNS rejected", { $0 == .dnsFailure }) {
            _ = try await privateDownloader.fetchPublicData(URL(string: "https://empty.example/a.png")!, maximumBytes: 4096)
        }
        check(privateTransport.recordedCalls.isEmpty, "no transport call happens before address screening")

        // 4. Bounded response stream parser (the production curl stdout reader).
        let crlfHeader = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\n\r\n".utf8)
        let parsed = try parseStream([crlfHeader + png], maximum: 65536)
        check(parsed.statusCode == 200 && parsed.headers["content-type"] == "image/png" && parsed.body == png,
            "CRLF header block and body are split exactly")
        let split = try parseStream([crlfHeader.prefix(20), crlfHeader.dropFirst(20) + png], maximum: 65536)
        check(split.body == png, "header terminator split across reads is handled")
        let lfOnly = Data("HTTP/1.1 200 OK\nContent-Type: image/jpeg\n\n".utf8) + jpeg
        check(try parseStream([lfOnly], maximum: 65536).headers["content-type"] == "image/jpeg",
            "LF-only header block is handled")
        let http2 = Data("HTTP/2 200\r\nContent-Type: image/png\r\n\r\n".utf8) + png
        check(try parseStream([http2], maximum: 65536).statusCode == 200, "HTTP/2 style status line is parsed")
        let chunked = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nTransfer-Encoding: chunked\r\n\r\n".utf8) + png
        check(try parseStream([chunked], maximum: 65536).body == png, "chunked response without content-length is accepted")
        let unknown = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n".utf8) + png
        check(try parseStream([unknown], maximum: 65536).body == png, "unknown length response is accepted")
        let declared = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 999999\r\n\r\n".utf8)
        do { _ = try parseStream([declared], maximum: 1024); check(false, "declared oversize rejected") }
        catch ResidentWebImageError.responseTooLarge { check(true, "declared oversize rejected") }
        catch { check(false, "declared oversize wrong error \(error)") }
        let oversizedBody = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n".utf8) + Data(repeating: 65, count: 4096)
        do { _ = try parseStream([oversizedBody], maximum: 1024); check(false, "streamed oversize rejected") }
        catch ResidentWebImageError.responseTooLarge { check(true, "streamed oversize rejected") }
        catch { check(false, "streamed oversize wrong error \(error)") }
        let oversizedHeaders = Data(repeating: 65, count: 70 * 1024)
        do { _ = try parseStream([oversizedHeaders], maximum: 4096); check(false, "oversized headers rejected") }
        catch ResidentWebImageError.responseTooLarge { check(true, "oversized headers rejected") }
        catch { check(false, "oversized headers wrong error \(error)") }
        // A present terminator must not launder a header block that is itself over
        // the header budget; the length is checked first either way.
        let oversizedHeadersWithTerminator = Data("HTTP/1.1 200 OK\r\nX-Pad: ".utf8)
            + Data(repeating: 65, count: 70 * 1024) + Data("\r\n\r\n".utf8)
        do { _ = try parseStream([oversizedHeadersWithTerminator], maximum: 4096); check(false, "terminated oversized headers rejected") }
        catch ResidentWebImageError.responseTooLarge { check(true, "terminated oversized headers rejected") }
        catch { check(false, "terminated oversized headers wrong error \(error)") }
        let nearCapPrefix = "HTTP/1.1 200 OK\r\nX-Pad: "
        let maxHeaderBlock = Data(nearCapPrefix.utf8)
            + Data(repeating: 65, count: 64 * 1024 - nearCapPrefix.utf8.count) + Data("\r\n\r\n".utf8)
        check(try parseStream([maxHeaderBlock], maximum: 4096).statusCode == 200,
            "a header block exactly at the 64 KiB budget is still accepted")
        let bodyChunks = [Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n".utf8)] + (0..<8).map { _ in Data(repeating: 65, count: 512) }
        do { _ = try parseStream(bodyChunks, maximum: 2048); check(false, "multi-chunk oversize rejected") }
        catch ResidentWebImageError.responseTooLarge { check(true, "multi-chunk oversize rejected") }
        catch { check(false, "multi-chunk oversize wrong error \(error)") }
        do { _ = try parseStream([Data()], maximum: 4096); check(false, "missing header block rejected") }
        catch { check(true, "missing header block rejected") }

        // 5. Structured fetch: a generic bounded 200 fetch. It returns normalized
        // MIME plus bytes and never forces image decoding; image-format validation
        // lives in download().
        let fetchResolver = RecordingResolver()
        fetchResolver.set("example.com", ["93.184.216.34"])
        fetchResolver.set("cdn.example.com", ["1.1.1.1"])
        let fetchTransport = ScriptedTransport()
        let fetcher = ResidentWebImageDownloader(resolver: fetchResolver, transport: fetchTransport)
        fetchTransport.setHandler { _ in raw(200, ["content-type": "image/png"], png) }
        let ok = try await fetcher.fetchPublicData(URL(string: "https://example.com/a.png")!, maximumBytes: 4096)
        check(ok.data == png && ok.mimeType == "image/png" && ok.finalURL.absoluteString == "https://example.com/a.png",
            "public PNG fetch returns data, mime and final url")
        check(fetchTransport.recordedCalls.last?.address == "93.184.216.34"
            && fetchTransport.recordedCalls.last?.maximumBytes == 4096,
            "transport receives the screened public IPv4 and the caller byte budget")
        // The exact root-probe contract: a real Commons-style search JSON response
        // behind application/json; charset=utf-8 must be delivered, not decoded as an image.
        let searchJSON = Data(#"{"query":{"pages":{}}}"#.utf8)
        fetchTransport.setHandler { _ in raw(200, ["content-type": "application/json; charset=utf-8"], searchJSON) }
        let searchResponse = try await fetcher.fetchPublicData(URL(string: "https://example.com/api")!, maximumBytes: 4096)
        check(searchResponse.mimeType == "application/json" && searchResponse.data == searchJSON,
            "generic fetch delivers bounded JSON with a normalized MIME instead of image decoding")
        fetchTransport.setHandler { _ in raw(200, ["content-type": "TEXT/HTML; charset=UTF-8"], html) }
        check(try await fetcher.fetchPublicData(URL(string: "https://example.com/a")!, maximumBytes: 4096).mimeType == "text/html",
            "generic fetch normalizes and returns a non-image MIME for the caller to judge")
        fetchTransport.setHandler { _ in raw(200, ["content-type": "application/octet-stream"], png) }
        check(try await fetcher.fetchPublicData(URL(string: "https://example.com/a")!, maximumBytes: 4096).mimeType == "application/octet-stream",
            "generic fetch does not require an image media type")
        fetchTransport.setHandler { _ in raw(200, ["content-type": "image/jpg"], jpeg) }
        check(try await fetcher.fetchPublicData(URL(string: "https://example.com/b.jpg")!, maximumBytes: 4096).mimeType == "image/jpeg",
            "the legacy image/jpg alias is normalized to image/jpeg")
        fetchTransport.setHandler { _ in raw(200, [:], png) }
        await rejected("missing content type rejected", { $0 == .missingContentType }) {
            _ = try await fetcher.fetchPublicData(URL(string: "https://example.com/a.png")!, maximumBytes: 4096)
        }
        fetchTransport.setHandler { _ in raw(200, ["content-type": "image/png"], Data()) }
        await rejected("empty body rejected", { $0 == .emptyResponse }) {
            _ = try await fetcher.fetchPublicData(URL(string: "https://example.com/a.png")!, maximumBytes: 4096)
        }
        // The caller byte budget must hold even for an injected transport that
        // ignores its own streaming cap.
        fetchTransport.setHandler { _ in raw(200, ["content-type": "application/json"], Data(repeating: 65, count: 5000)) }
        await rejected("injected transport body above the caller cap rejected", { $0 == .responseTooLarge }) {
            _ = try await fetcher.fetchPublicData(URL(string: "https://example.com/a")!, maximumBytes: 1024)
        }
        fetchTransport.setHandler { _ in raw(404, ["content-type": "text/html"], html) }
        await rejected("non success status rejected", { $0 == .httpStatus(404) }) {
            _ = try await fetcher.fetchPublicData(URL(string: "https://example.com/a.png")!, maximumBytes: 4096)
        }
        fetchTransport.setHandler { _ in raw(301, [:], Data()) }
        await rejected("redirect without location rejected", { $0 == .redirectWithoutLocation }) {
            _ = try await fetcher.fetchPublicData(URL(string: "https://example.com/a.png")!, maximumBytes: 4096)
        }
        fetchTransport.setHandler { request in
            if request.url.host == "example.com" {
                return raw(302, ["location": "https://cdn.example.com/b.png"], Data())
            }
            return raw(200, ["content-type": "image/png"], png)
        }
        fetchTransport.resetCalls()
        let redirected = try await fetcher.fetchPublicData(URL(string: "https://example.com/a.png")!, maximumBytes: 4096)
        check(redirected.finalURL.absoluteString == "https://cdn.example.com/b.png", "redirect final url is reported")
        check(fetchTransport.recordedCalls.count == 2
            && fetchTransport.recordedCalls[0].address == "93.184.216.34"
            && fetchTransport.recordedCalls[1].host == "cdn.example.com"
            && fetchTransport.recordedCalls[1].address == "1.1.1.1",
            "every redirect hop re-resolves and pins its own public IPv4")
        fetchTransport.setHandler { request in
            if request.url.host == "example.com" { return raw(302, ["location": "https://private.example/b.png"], Data()) }
            return raw(200, ["content-type": "image/png"], png)
        }
        fetchResolver.set("private.example", ["10.0.0.9"])
        await rejected("redirect into private network rejected", { if case .nonPublicAddress = $0 { return true }; return false }) {
            _ = try await fetcher.fetchPublicData(URL(string: "https://example.com/a.png")!, maximumBytes: 4096)
        }
        fetchTransport.setHandler { _ in raw(302, ["location": "http://example.com/b.png"], Data()) }
        await rejected("redirect downgrade to http rejected", { $0 == .unsupportedScheme }) {
            _ = try await fetcher.fetchPublicData(URL(string: "https://example.com/a.png")!, maximumBytes: 4096)
        }
        fetchTransport.setHandler { _ in raw(302, ["location": "https://example.com/loop"], Data()) }
        await rejected("more than three redirects rejected", { $0 == .tooManyRedirects }) {
            _ = try await fetcher.fetchPublicData(URL(string: "https://example.com/a.png")!, maximumBytes: 4096)
        }
        fetchTransport.setHandler { request in
            let hops = fetchTransport.recordedCalls.count
            return hops <= 3 ? raw(302, ["location": "https://example.com/hop\(hops)"], Data())
                             : raw(200, ["content-type": "image/png"], png)
        }
        fetchTransport.resetCalls()
        let threeHops = try await fetcher.fetchPublicData(URL(string: "https://example.com/a.png")!, maximumBytes: 4096)
        check(threeHops.data == png && fetchTransport.recordedCalls.count == 4, "exactly three redirects are allowed")

        // 5b. Cancellation after each await must surface as CancellationError, and a
        // cancelled resolver await must not fall through to a transport call.
        let gatedResolver = GatedResolver()
        let gatedTransport = ScriptedTransport { _ in raw(200, ["content-type": "application/json"], Data("{}".utf8)) }
        let gatedFetcher = ResidentWebImageDownloader(resolver: gatedResolver, transport: gatedTransport)
        let gatedTask = Task { try await gatedFetcher.fetchPublicData(URL(string: "https://example.com/a.json")!, maximumBytes: 4096) }
        _ = waitForSemaphore(gatedResolver.entered, timeout: .now() + 5)
        gatedTask.cancel()
        gatedResolver.release()
        do {
            _ = try await gatedTask.value
            check(false, "cancellation observed at the resolver await")
        } catch is CancellationError { check(true, "cancellation observed at the resolver await") }
        catch { check(false, "cancellation at resolver await wrong error \(error)") }
        check(gatedTransport.recordedCalls.isEmpty, "no transport call happens after cancellation at the resolver await")

        let transportCancel = ScriptedTransport { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return raw(200, ["content-type": "application/json"], Data("{}".utf8))
        }
        let transportCancelFetcher = ResidentWebImageDownloader(resolver: resolver, transport: transportCancel)
        let transportCancelTask = Task {
            try await transportCancelFetcher.fetchPublicData(URL(string: "https://example.com/a.json")!, maximumBytes: 4096)
        }
        do {
            _ = try await transportCancelTask.value
            check(false, "cancellation observed at the transport await")
        } catch is CancellationError { check(true, "cancellation observed at the transport await") }
        catch { check(false, "cancellation at transport await wrong error \(error)") }

        // 6. download(): the only place image media types and decodability are
        // enforced, plus production preparation, bounded PNG and metadata stripping.
        let downloadTransport = ScriptedTransport { _ in raw(200, ["content-type": "image/png"], png) }
        let imageDownloader = ResidentWebImageDownloader(resolver: resolver, transport: downloadTransport)
        let downloaded = try await imageDownloader.download(URL(string: "https://example.com/a.png")!)
        check(downloaded.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) && downloaded.count <= 8 * 1024 * 1024
            && decodes(downloaded), "download returns a decodable PNG under the API byte limit")
        downloadTransport.setHandler { _ in raw(200, ["content-type": "image/jpeg"], gpsJPEG) }
        let stripped = try await imageDownloader.download(URL(string: "https://example.com/a.jpg")!)
        let strippedSource = CGImageSourceCreateWithData(stripped as CFData, nil)!
        let strippedProperties = CGImageSourceCopyPropertiesAtIndex(strippedSource, 0, nil)! as NSDictionary
        check(stripped.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10])
            && strippedProperties[kCGImagePropertyGPSDictionary] == nil,
            "download re-encodes to PNG and removes location metadata")
        downloadTransport.setHandler { _ in raw(200, ["content-type": "image/png"], html) }
        await rejected("download rejects a mime-fake image", { $0 == .notAnImage }) {
            _ = try await imageDownloader.download(URL(string: "https://example.com/a.png")!)
        }
        downloadTransport.setHandler { _ in raw(200, ["content-type": "image/png"], jpeg) }
        await rejected("download rejects a mismatched jpeg body declared png", { $0 == .notAnImage }) {
            _ = try await imageDownloader.download(URL(string: "https://example.com/a.png")!)
        }
        downloadTransport.setHandler { _ in raw(200, ["content-type": "text/html; charset=utf-8"], html) }
        await rejected("download rejects an html media type", { if case .unsupportedContentType = $0 { return true }; return false }) {
            _ = try await imageDownloader.download(URL(string: "https://example.com/a.png")!)
        }
        downloadTransport.setHandler { _ in raw(200, ["content-type": "image/svg+xml"], svg) }
        await rejected("download rejects svg", { if case .unsupportedContentType = $0 { return true }; return false }) {
            _ = try await imageDownloader.download(URL(string: "https://example.com/a.png")!)
        }
        downloadTransport.setHandler { _ in raw(200, ["content-type": "application/octet-stream"], png) }
        await rejected("download rejects a non-image media type", { if case .unsupportedContentType = $0 { return true }; return false }) {
            _ = try await imageDownloader.download(URL(string: "https://example.com/a.png")!)
        }
        downloadTransport.setHandler { _ in raw(200, [:], png) }
        await rejected("download rejects a missing media type", { $0 == .missingContentType }) {
            _ = try await imageDownloader.download(URL(string: "https://example.com/a.png")!)
        }
        downloadTransport.setHandler { _ in raw(200, ["content-type": "image/png"], Data()) }
        await rejected("download rejects an empty body", { $0 == .emptyResponse }) {
            _ = try await imageDownloader.download(URL(string: "https://example.com/a.png")!)
        }

        // 6b. Cancellation must never be wrapped in preparationFailed, and a
        // cancellation that lands after preparation must still be observed.
        let cancellationPreparation = ResidentWebImageDownloader(resolver: resolver,
            transport: ScriptedTransport { _ in raw(200, ["content-type": "image/png"], png) },
            preparation: { _ in throw CancellationError() })
        do {
            _ = try await cancellationPreparation.download(URL(string: "https://example.com/a.png")!)
            check(false, "a CancellationError from preparation is propagated as CancellationError")
        } catch is CancellationError { check(true, "a CancellationError from preparation is propagated as CancellationError") }
        catch { check(false, "CancellationError from preparation was wrapped as \(error)") }

        let failedPreparation = ResidentWebImageDownloader(resolver: resolver,
            transport: ScriptedTransport { _ in raw(200, ["content-type": "image/png"], png) },
            preparation: { _ in throw ResidentWebImageError.transportFailure("scripted-preparation") })
        await rejected("a real preparation failure stays preparationFailed", { $0 == .preparationFailed }) {
            _ = try await failedPreparation.download(URL(string: "https://example.com/a.png")!)
        }

        let lateCancellationPreparation = ResidentWebImageDownloader(resolver: resolver,
            transport: ScriptedTransport { _ in raw(200, ["content-type": "image/png"], png) },
            preparation: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return png
            })
        let lateCancellationTask = Task {
            try await lateCancellationPreparation.download(URL(string: "https://example.com/a.png")!)
        }
        do {
            _ = try await lateCancellationTask.value
            check(false, "cancellation arriving during preparation is observed")
        } catch is CancellationError { check(true, "cancellation arriving during preparation is observed") }
        catch { check(false, "late preparation cancellation wrong error \(error)") }

        // 7. Private temporary directory and file permissions.
        let directory = try ResidentWebImageDownloader.makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        check((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "temporary directory is private 0700")
        let file = try ResidentWebImageDownloader.writePrivate(png, in: directory)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        check((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "temporary image file is private 0600")
        try? FileManager.default.removeItem(at: directory)

        // 8. Real subprocess transport against a local fake curl (no network).
        let curl = ResidentWebImageCurlTransport(executableURL: checkBinary, timeout: 30)
        let recordFile = scratch.appendingPathComponent("argv-\(UUID().uuidString).json")
        let recordRequest = ResidentWebImageTransportRequest(url: fakeURL("record", record: recordFile),
            host: "example.com", address: "93.184.216.34", maximumBytes: 1 << 20, timeout: 30)
        let recorded = try await curl.perform(recordRequest)
        check(recorded.statusCode == 200 && recorded.headers["content-type"] == "image/png" && decodes(recorded.body),
            "real process transport returns the streamed response")
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: recordFile)) as! [String: Any]
        let recordedArguments = payload["arguments"] as! [String]
        check(recordedArguments.first == "--disable", "child curl runs with --disable first")
        check(helperValue("--resolve", recordedArguments) == "example.com:443:93.184.216.34",
            "child curl receives the pinned public IPv4")
        check(helperValue("--proto", recordedArguments) == "=https" && helperValue("--noproxy", recordedArguments) == "*",
            "child curl receives the protocol and proxy lockdown")
        check((payload["environment"] as? [String: String])?.keys.allSatisfy({ key in
            let lowered = key.lowercased()
            return !lowered.contains("proxy")
                && !["home", "curl_home", "xdg_config_home", "cookie", "cookiejar", "netrc", "path"].contains(lowered)
        }) == true, "child curl runs with a clean environment")
        // 8a. POSIX_SPAWN_CLOEXEC_DEFAULT: a descriptor the harness opens without
        // CLOEXEC (standing in for an app socket or another download's pipe) must
        // not survive into the spawned child, while explicit stdio still does.
        let sentinel = open("/dev/null", O_RDONLY)
        check(sentinel >= 0, "harness opened a sentinel descriptor")
        if sentinel >= 0 {
            check((fcntl(sentinel, F_GETFD) & FD_CLOEXEC) == 0,
                "sentinel descriptor is inheritable (no FD_CLOEXEC) in the harness")
            let sentinelRecord = scratch.appendingPathComponent("sentinel-\(UUID().uuidString).json")
            let sentinelRequest = ResidentWebImageTransportRequest(
                url: fakeSentinelURL(descriptor: sentinel, record: sentinelRecord),
                host: "example.com", address: "93.184.216.34", maximumBytes: 1 << 20, timeout: 30)
            let sentinelResponse = try await curl.perform(sentinelRequest)
            check(sentinelResponse.statusCode == 200 && decodes(sentinelResponse.body),
                "the isolated child still returns the streamed response")
            let sentinelPayload = try JSONSerialization.jsonObject(with: Data(contentsOf: sentinelRecord)) as! [String: Any]
            check(sentinelPayload["sentinelOpenInChild"] as? Bool == false,
                "POSIX_SPAWN_CLOEXEC_DEFAULT closes the inherited sentinel descriptor in the child")
            check(fcntl(sentinel, F_GETFD) != -1,
                "the sentinel descriptor stays open in the harness after the spawn")
            close(sentinel)
        }
        let chunkedRequest = ResidentWebImageTransportRequest(url: fakeURL("chunked"),
            host: "example.com", address: "93.184.216.34", maximumBytes: 1 << 20, timeout: 30)
        check(decodes(try await curl.perform(chunkedRequest).body), "chunked subprocess response is read fully")
        let unknownRequest = ResidentWebImageTransportRequest(url: fakeURL("unknown"),
            host: "example.com", address: "93.184.216.34", maximumBytes: 1 << 20, timeout: 30)
        check(decodes(try await curl.perform(unknownRequest).body), "unknown-length subprocess response is read fully")
        let hugeRequest = ResidentWebImageTransportRequest(url: fakeURL("huge"),
            host: "example.com", address: "93.184.216.34", maximumBytes: 4096, timeout: 30)
        do {
            _ = try await curl.perform(hugeRequest)
            check(false, "oversized subprocess response rejected")
        } catch ResidentWebImageError.responseTooLarge { check(true, "oversized subprocess response rejected") }
        catch { check(false, "oversized subprocess wrong error \(error)") }

        // Repeated immediate-exit successes: the child is already gone (and may
        // already be reaped by Foundation) before the transport finishes reading,
        // which is exactly the race that used to hang `Process.waitUntilExit()`.
        // The runner-level watchdog keeps any regression from wedging the suite.
        for index in 0..<20 {
            let request = ResidentWebImageTransportRequest(url: fakeURL("ok"),
                host: "example.com", address: "93.184.216.34", maximumBytes: 1 << 20, timeout: 30)
            let response = try await curl.perform(request)
            check(response.statusCode == 200 && decodes(response.body), "repeated immediate-exit success \(index) is reaped")
        }

        // Success must let curl exit naturally. The child closes stdout, sleeps,
        // then writes its marker and exits 0: a transport that terminates on
        // success would kill it before the marker exists.
        let lingerMarker = scratch.appendingPathComponent("linger-\(UUID().uuidString).done")
        let lingerRequest = ResidentWebImageTransportRequest(url: fakeURL("linger", record: lingerMarker),
            host: "example.com", address: "93.184.216.34", maximumBytes: 1 << 20, timeout: 30)
        do {
            let lingerResponse = try await curl.perform(lingerRequest)
            check(lingerResponse.statusCode == 200, "a lingering successful curl still returns its response")
            check(await waitForFile(lingerMarker, timeout: 5), "a successful curl is allowed to exit naturally")
        } catch {
            check(false, "lingering success path threw \(error)")
        }

        let exitSevenRequest = ResidentWebImageTransportRequest(url: fakeURL("okexit7"),
            host: "example.com", address: "93.184.216.34", maximumBytes: 1 << 20, timeout: 30)
        do {
            _ = try await curl.perform(exitSevenRequest)
            check(false, "a non-zero curl exit is rejected")
        } catch ResidentWebImageError.transportFailure(let reason) {
            check(reason == "curl-exit-7", "a non-zero curl exit is rejected with its status (\(reason))")
        } catch { check(false, "non-zero curl exit wrong error \(error)") }

        let hangPIDFile = scratch.appendingPathComponent("hang-\(UUID().uuidString).pid")
        let hangURL = fakeURL("hang", record: hangPIDFile)
        let hangRequest = ResidentWebImageTransportRequest(url: hangURL,
            host: "example.com", address: "93.184.216.34", maximumBytes: 4096, timeout: 30)
        let hangTask = Task { try await curl.perform(hangRequest) }
        check(await waitForFile(hangPIDFile), "fake subprocess reported its pid")
        let hangPID = readStoredPID(hangPIDFile)
        hangTask.cancel()
        var cancelled = false
        do { _ = try await hangTask.value } catch is CancellationError { cancelled = true } catch { print("cancel error: \(error)") }
        check(cancelled, "cancellation surfaces as CancellationError")
        check(!alive(hangPID), "cancelled subprocess is terminated and reaped")

        let timeoutPIDFile = scratch.appendingPathComponent("timeout-\(UUID().uuidString).pid")
        let timeoutURL = fakeURL("hang", record: timeoutPIDFile)
        let timeoutRequest = ResidentWebImageTransportRequest(url: timeoutURL,
            host: "example.com", address: "93.184.216.34", maximumBytes: 4096, timeout: 1)
        let timeoutCurl = ResidentWebImageCurlTransport(executableURL: checkBinary, timeout: 1)
        let timeoutTask = Task { try await timeoutCurl.perform(timeoutRequest) }
        check(await waitForFile(timeoutPIDFile), "timeout subprocess reported its pid")
        let timeoutPID = readStoredPID(timeoutPIDFile)
        do {
            _ = try await timeoutTask.value
            check(false, "subprocess deadline enforced")
        } catch ResidentWebImageError.timeout { check(true, "subprocess deadline enforced") }
        catch { check(false, "subprocess deadline wrong error \(error)") }
        check(!alive(timeoutPID), "timed out subprocess is terminated and reaped")

        // 9. Redirects across real subprocess hops keep per-hop pinning.
        let hopOne = scratch.appendingPathComponent("hop-\(UUID().uuidString).json")
        let hopTwo = URL(fileURLWithPath: hopOne.path + ".hop2")
        let hopResolver = RecordingResolver()
        hopResolver.set("example.com", ["93.184.216.34"])
        hopResolver.set("cdn.example.com", ["1.1.1.1"])
        let hopDownloader = ResidentWebImageDownloader(resolver: hopResolver, transport: curl)
        let hopURL = fakeURL("redirect", record: hopOne)
        let hopResponse = try await hopDownloader.fetchPublicData(hopURL, maximumBytes: 1 << 20)
        check(hopResponse.finalURL.host == "cdn.example.com" && decodes(hopResponse.data),
            "real subprocess redirect is validated and followed to the second host")
        let hopPayload = try JSONSerialization.jsonObject(with: Data(contentsOf: hopTwo)) as! [String: Any]
        check(helperValue("--resolve", hopPayload["arguments"] as! [String]) == "cdn.example.com:443:1.1.1.1",
            "each real redirect hop pins its own freshly resolved IPv4")

        // 10. End-to-end download over the real process transport.
        let e2eResolver = RecordingResolver()
        e2eResolver.set("example.com", ["93.184.216.34"])
        let e2e = ResidentWebImageDownloader(resolver: e2eResolver, transport: curl)
        let e2eData = try await e2e.download(fakeURL("ok"))
        check(decodes(e2eData) && e2eData.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
            "download over the real subprocess transport yields a prepared PNG")

        // 11. A finished download leaves no private staging directory behind.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?
            .filter { $0.hasPrefix("gmgn-public-image-") } ?? []
        check(leftovers.isEmpty, "no temporary staging directory survives a download")

        // 12. A cancellation that lands while a naturally-exiting child is being
        // awaited must not be reported as success. The child ignores SIGTERM,
        // closes stdout, reports its pid, then exits 0 on its own.
        let stubbornPIDFile = scratch.appendingPathComponent("stubborn-\(UUID().uuidString).pid")
        let stubbornRequest = ResidentWebImageTransportRequest(url: fakeURL("stubbornok", record: stubbornPIDFile),
            host: "example.com", address: "93.184.216.34", maximumBytes: 1 << 20, timeout: 30)
        let stubbornTask = Task { try await curl.perform(stubbornRequest) }
        check(await waitForFile(stubbornPIDFile), "stubborn fake subprocess reported its pid")
        let stubbornPID = readStoredPID(stubbornPIDFile)
        try? await Task.sleep(nanoseconds: 300_000_000)
        stubbornTask.cancel()
        do {
            _ = try await stubbornTask.value
            check(false, "cancel during a natural exit wait is not reported as success")
        } catch is CancellationError { check(true, "cancel during a natural exit wait is not reported as success") }
        catch { check(false, "cancel during natural exit wrong error \(error)") }
        check(!alive(stubbornPID), "a SIGTERM-immune child that exits naturally is still reaped")

        // 13. A descendant that inherits stdout must not keep a killed request
        // alive: once the direct child is killed the read aborts instead of
        // waiting for the grandchild's EOF. The test reaps its own grandchild.
        let orphanPIDFile = scratch.appendingPathComponent("orphan-\(UUID().uuidString).pid")
        let orphanHolderFile = URL(fileURLWithPath: orphanPIDFile.path + ".holder")
        let orphanRequest = ResidentWebImageTransportRequest(url: fakeURL("orphanstdout", record: orphanPIDFile),
            host: "example.com", address: "93.184.216.34", maximumBytes: 4096, timeout: 30)
        let orphanTask = Task { try await curl.perform(orphanRequest) }
        check(await waitForFile(orphanPIDFile), "orphan fake subprocess reported its pid")
        check(await waitForFile(orphanHolderFile), "orphan fake subprocess spawned a stdout-holding descendant")
        let orphanPID = readStoredPID(orphanPIDFile)
        let orphanHolderPID = readStoredPID(orphanHolderFile)
        defer { if orphanHolderPID > 0 { kill(orphanHolderPID, SIGKILL) } }
        orphanTask.cancel()
        do {
            _ = try await orphanTask.value
            check(false, "cancel returns while a descendant still holds stdout")
        } catch is CancellationError { check(true, "cancel returns while a descendant still holds stdout") }
        catch { check(false, "orphan cancel wrong error \(error)") }
        check(!alive(orphanPID), "orphan direct child is terminated and reaped")
        kill(orphanHolderPID, SIGKILL)
        check(await waitForDeath(orphanHolderPID), "test reaps its own stdout-holding descendant")

        // 14. The same boundary under timeout: the deadline must fire and return
        // while a descendant still holds stdout, and both pids must be cleaned up.
        let orphanTimeoutPIDFile = scratch.appendingPathComponent("orphan-timeout-\(UUID().uuidString).pid")
        let orphanTimeoutHolderFile = URL(fileURLWithPath: orphanTimeoutPIDFile.path + ".holder")
        let orphanTimeoutCurl = ResidentWebImageCurlTransport(executableURL: checkBinary, timeout: 1)
        let orphanTimeoutRequest = ResidentWebImageTransportRequest(url: fakeURL("orphanstdout", record: orphanTimeoutPIDFile),
            host: "example.com", address: "93.184.216.34", maximumBytes: 4096, timeout: 1)
        let orphanTimeoutTask = Task { try await orphanTimeoutCurl.perform(orphanTimeoutRequest) }
        check(await waitForFile(orphanTimeoutPIDFile), "orphan timeout fake subprocess reported its pid")
        check(await waitForFile(orphanTimeoutHolderFile), "orphan timeout fake subprocess spawned a stdout-holding descendant")
        let orphanTimeoutPID = readStoredPID(orphanTimeoutPIDFile)
        let orphanTimeoutHolderPID = readStoredPID(orphanTimeoutHolderFile)
        defer { if orphanTimeoutHolderPID > 0 { kill(orphanTimeoutHolderPID, SIGKILL) } }
        do {
            _ = try await orphanTimeoutTask.value
            check(false, "timeout returns while a descendant still holds stdout")
        } catch ResidentWebImageError.timeout { check(true, "timeout returns while a descendant still holds stdout") }
        catch { check(false, "orphan timeout wrong error \(error)") }
        check(!alive(orphanTimeoutPID), "orphan timed out direct child is terminated and reaped")
        kill(orphanTimeoutHolderPID, SIGKILL)
        check(await waitForDeath(orphanTimeoutHolderPID), "test reaps its own timed-out descendant")

        // 15. One transport instance serves many concurrent immediate-exit
        // requests, and keeps serving them afterwards. Each request owns its own
        // child and its own reaper, so no state is shared across them.
        var concurrentFailures = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let request = ResidentWebImageTransportRequest(url: fakeURL("ok"),
                        host: "example.com", address: "93.184.216.34", maximumBytes: 1 << 20, timeout: 30)
                    do {
                        let response = try await curl.perform(request)
                        return response.statusCode == 200 && decodes(response.body)
                    } catch {
                        return false
                    }
                }
            }
            for await succeeded in group { if !succeeded { concurrentFailures += 1 } }
        }
        check(concurrentFailures == 0, "concurrent immediate-exit requests on one transport instance all succeed")
        for index in 0..<5 {
            let request = ResidentWebImageTransportRequest(url: fakeURL("ok"),
                host: "example.com", address: "93.184.216.34", maximumBytes: 1 << 20, timeout: 30)
            let response = try await curl.perform(request)
            check(response.statusCode == 200 && decodes(response.body),
                "immediate-exit rerun \(index) after concurrent use is reaped")
        }

        print(failures == 0 ? "PASS: \(checks) resident web image checks" : "FAIL: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-web-image-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Checks.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("checks")

/// Bounded child wait that never calls `waitUntilExit`, which can hang on the
/// same Foundation exit-notification race the downloader must survive. On a
/// watchdog hit the stuck child and its descendants are sampled to disk before
/// being killed, so a hang can be diagnosed without starting another run.
final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    func store(_ status: Int32) { lock.lock(); value = status; lock.unlock() }
    var status: Int32? { lock.lock(); defer { lock.unlock() }; return value }
}

struct BoundedResult {
    let launched: Bool
    let status: Int32?
    let timedOut: Bool
    let pid: Int32
}

func runBounded(_ process: Process, timeout: TimeInterval) -> BoundedResult {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ExitBox()
    process.terminationHandler = { finished in
        box.store(finished.terminationStatus)
        semaphore.signal()
    }
    do { try process.run() } catch {
        return BoundedResult(launched: false, status: nil, timedOut: false, pid: -1)
    }
    let pid = process.processIdentifier
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        return BoundedResult(launched: true, status: nil, timedOut: true, pid: pid)
    }
    return BoundedResult(launched: true, status: box.status, timedOut: false, pid: pid)
}

func diagnostics(for pid: Int32) {
    let samplePath = "/tmp/gmgn-web-download-test-\(pid).sample.txt"
    let sample = Process()
    sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    sample.arguments = ["\(pid)", "1", "1", "-file", samplePath]
    sample.standardOutput = FileHandle.nullDevice
    sample.standardError = FileHandle.nullDevice
    let sampleResult = runBounded(sample, timeout: 30)
    if sampleResult.timedOut { kill(sampleResult.pid, SIGKILL) }
    let children = Process()
    children.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    children.arguments = ["-P", "\(pid)"]
    let pipe = Pipe()
    children.standardOutput = pipe
    children.standardError = FileHandle.nullDevice
    _ = runBounded(children, timeout: 10)
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    print("watchdog: sample=\(samplePath) children=[\(out)]")
}

func requireBounded(_ result: BoundedResult, label: String, timeout: TimeInterval) -> Int32 {
    if result.timedOut {
        print("FAIL: \(label) watchdog killed a hung child after \(Int(timeout))s (pid \(result.pid))")
        diagnostics(for: result.pid)
        kill(result.pid, SIGKILL)
        exit(75)
    }
    guard result.launched else { print("FAIL: \(label) failed to launch"); exit(70) }
    guard let status = result.status else { print("FAIL: \(label) exited without an observable status"); exit(76) }
    return status
}

let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
compile.arguments = ["-n", "15", "/usr/bin/swiftc", "-j1", "-swift-version", "6", "-parse-as-library",
    generation.path, preparation.path, source.path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentWebImagePublicDNSResolver.swift").path,
    program.path, "-o", executable.path]
let compileStatus = requireBounded(runBounded(compile, timeout: 300), label: "compile", timeout: 300)
guard compileStatus == 0 else { exit(compileStatus) }
let test = Process()
test.executableURL = executable
let testStatus = requireBounded(runBounded(test, timeout: 120), label: "resident web image checks", timeout: 120)
exit(testStatus)
