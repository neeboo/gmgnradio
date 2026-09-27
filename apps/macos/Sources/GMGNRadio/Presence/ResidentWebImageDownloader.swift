import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One bounded public HTTPS response.
///
/// `data` is the exact response body, `mimeType` is the normalized media type
/// (lowercased, parameters removed) and `finalURL` is the last hop actually
/// fetched after redirects. The type is generic on purpose: JSON search APIs and
/// images both travel through it, and only `download` additionally requires an
/// image media type and a decodable body. Callers must not resolve or re-fetch
/// `finalURL` themselves; the address used for it was already screened and pinned.
struct ResidentWebImageResponse: Sendable {
    let data: Data
    let mimeType: String
    let finalURL: URL
}

/// One request handed to a transport.
///
/// `host` is the URL hostname and `address` is the public IPv4 that the downloader
/// selected for it. A transport must pin `address` to `host` (curl `--resolve`) so
/// that no second, unscreened DNS lookup can happen. `address == host` only for an
/// IPv4-literal URL, where the URL itself already carries the screened address.
struct ResidentWebImageTransportRequest: Sendable {
    let url: URL
    let host: String
    let address: String
    let maximumBytes: Int
    let timeout: TimeInterval
}

/// A response after bounded streaming parse. Header names are lowercased.
struct ResidentWebImageRawResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

enum ResidentWebImageError: Error, Equatable {
    case unsupportedScheme
    case unsupportedPort
    case invalidURL
    case ipv6Unsupported
    case invalidArgument
    case dnsFailure
    case nonPublicAddress(String)
    case mixedPublicPrivateDNS
    case redirectWithoutLocation
    case tooManyRedirects
    case httpStatus(Int)
    case missingContentType
    case unsupportedContentType(String)
    case notAnImage
    case responseTooLarge
    case emptyResponse
    case timeout
    case transportFailure(String)
    case preparationFailed
}

/// Resolves a hostname to candidate IPv4 addresses. Production uses the system
/// resolver; tests inject a scripted one.
protocol ResidentWebImageAddressResolving: Sendable {
    func ipv4Addresses(forHost host: String) async throws -> [String]
}

/// Performs exactly one already-validated HTTPS request with the address pinned.
protocol ResidentWebImageTransporting: Sendable {
    func perform(_ request: ResidentWebImageTransportRequest) async throws -> ResidentWebImageRawResponse
}

/// A validated URL plus the address form it must be fetched with.
struct ResidentWebImageTarget: Sendable {
    let url: URL
    let host: String
    let literalAddress: String?
}

/// Downloads public HTTPS reference images for the wish machine.
///
/// The default initializer is the only production path: it adds the system
/// resolver and the curl subprocess transport, both of which keep URL screening
/// and `--resolve` pinning. Only the offline tests inject replacements, and even
/// then all validation, redirect handling and per-hop pinning stays in this type.
struct ResidentWebImageDownloader: Sendable {
    static let maximumRedirects = 3
    static let defaultTimeout: TimeInterval = 30
    /// Bounded response cap for `download`; preparation shrinks the result to <= 8 MiB.
    static let maximumDownloadBytes = 16 * 1024 * 1024
    /// Header bytes allowed on top of the body budget before a response is refused.
    static let maximumHeaderBytes = 64 * 1024
    /// Must stay in sync with `PropImagePreparation`'s own pixel ceiling.
    static let maximumPixelCount = 100_000_000

    /// Re-encodes a staged file into the bounded PNG the API accepts. Production
    /// always uses `PropImagePreparation`; the offline tests inject a scripted
    /// preparation so cancellation and failure mapping stay deterministic.
    typealias Preparation = @Sendable (URL) async throws -> Data

    private let resolver: any ResidentWebImageAddressResolving
    private let transport: any ResidentWebImageTransporting
    private let preparation: Preparation
    private let redirectLimit: Int
    private let requestTimeout: TimeInterval

    /// The production resolver. It is intentionally not the system resolver: the
    /// network in front of this machine answers many public names with a fake
    /// address in the benchmarking range (for example `commons.wikimedia.org` ->
    /// `198.18.0.161`), which screening refuses, so real downloads would fail.
    /// The public DoH resolver reaches a pinned trusted resolver instead, and its
    /// answers are still screened here before any address becomes trusted.
    static func makeDefaultResolver() -> any ResidentWebImageAddressResolving {
        ResidentWebImagePublicDNSResolver()
    }

    init(resolver: any ResidentWebImageAddressResolving = ResidentWebImageDownloader.makeDefaultResolver(),
         transport: any ResidentWebImageTransporting = ResidentWebImageCurlTransport(),
         preparation: @escaping Preparation = { try await PropImagePreparation.prepare(url: $0) },
         maximumRedirects: Int = 3,
         timeout: TimeInterval = 30) {
        self.resolver = resolver
        self.transport = transport
        self.preparation = preparation
        self.redirectLimit = max(0, maximumRedirects)
        self.requestTimeout = timeout
    }

    /// Downloads, validates and prepares a public reference image as a PNG.
    ///
    /// The generic response is first required to carry an image media type and a
    /// body that really decodes as that type; only then is it prepared. The
    /// prepared PNG is at most 8 MiB and has no EXIF/GPS metadata because
    /// `PropImagePreparation` re-encodes it. The bounded temp file is always
    /// removed, including on cancellation and failure.
    func download(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let response = try await fetchPublicData(url, maximumBytes: Self.maximumDownloadBytes)
        try Task.checkCancellation()
        let mimeType = try Self.allowedImageMIMEType(response.mimeType)
        try Self.verifyImageBody(response.data, declaredMIMEType: mimeType)
        try Task.checkCancellation()
        let directory = try Self.makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.writePrivate(response.data, in: directory)
        let prepared: Data
        do {
            prepared = try await preparation(file)
        } catch is CancellationError {
            // A cancelled download is not a preparation failure; keep its identity.
            throw CancellationError()
        } catch {
            throw ResidentWebImageError.preparationFailed
        }
        // `PropImagePreparation.prepare` awaits a detached task that cannot see
        // this task's cancellation, so a cancellation that landed while it ran is
        // only observable here.
        try Task.checkCancellation()
        return prepared
    }

    /// Fetches bounded bytes from a public HTTPS URL after full validation.
    ///
    /// This is the generic surface: any 2xx response with a content type is
    /// returned with its normalized MIME and at most `maximumBytes` of body. It
    /// deliberately does not require an image media type or decode the body, so
    /// JSON search responses travel through it; `download` adds the image checks.
    func fetchPublicData(_ url: URL, maximumBytes: Int) async throws -> ResidentWebImageResponse {
        guard maximumBytes > 0 else { throw ResidentWebImageError.invalidArgument }
        var target = try Self.validatedTarget(url)
        var redirects = 0
        while true {
            try Task.checkCancellation()
            let address = try await pinnedAddress(for: target)
            try Task.checkCancellation()
            let request = ResidentWebImageTransportRequest(url: target.url, host: target.host,
                address: address, maximumBytes: maximumBytes, timeout: requestTimeout)
            let response = try await transport.perform(request)
            try Task.checkCancellation()
            if (300..<400).contains(response.statusCode) {
                guard redirects < redirectLimit else { throw ResidentWebImageError.tooManyRedirects }
                guard let location = response.headers["location"], !location.isEmpty else {
                    throw ResidentWebImageError.redirectWithoutLocation
                }
                guard let next = URL(string: location, relativeTo: target.url) else {
                    throw ResidentWebImageError.invalidURL
                }
                target = try Self.validatedTarget(next.absoluteURL)
                redirects += 1
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw ResidentWebImageError.httpStatus(response.statusCode)
            }
            // An injected transport may ignore the streaming cap, so the caller
            // budget is enforced here too.
            guard response.body.count <= maximumBytes else { throw ResidentWebImageError.responseTooLarge }
            guard !response.body.isEmpty else { throw ResidentWebImageError.emptyResponse }
            let mimeType = try Self.normalizedMIMEType(response.headers["content-type"])
            return ResidentWebImageResponse(data: response.body, mimeType: mimeType, finalURL: target.url)
        }
    }

    private func pinnedAddress(for target: ResidentWebImageTarget) async throws -> String {
        if let literal = target.literalAddress {
            return try Self.screenedPublicAddress(target.host, [literal])
        }
        let addresses = try await resolver.ipv4Addresses(forHost: target.host)
        return try Self.screenedPublicAddress(target.host, addresses)
    }

    // MARK: URL validation

    /// Rejects every URL that is not a plain HTTPS request to a public hostname
    /// on the standard port, with no credentials, fragment or control characters.
    static func validatedTarget(_ url: URL) throws -> ResidentWebImageTarget {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { throw ResidentWebImageError.unsupportedScheme }
        guard url.user == nil, url.password == nil else { throw ResidentWebImageError.invalidURL }
        guard url.fragment == nil else { throw ResidentWebImageError.invalidURL }
        if let port = url.port, port != 443 { throw ResidentWebImageError.unsupportedPort }
        guard url.absoluteString.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw ResidentWebImageError.invalidURL
        }
        // `URL` percent-encodes raw control characters before we see them, so also
        // refuse their escapes; nothing legitimate needs %00-%1F or %7F in a URL.
        guard !containsEncodedControlCharacter(url.absoluteString) else { throw ResidentWebImageError.invalidURL }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty else { throw ResidentWebImageError.invalidURL }
        // IPv6 is explicitly unsupported in this version, literals included.
        guard !host.contains(":") && !host.hasPrefix("[") else { throw ResidentWebImageError.ipv6Unsupported }
        let allowedHostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.unicodeScalars.allSatisfy({ allowedHostCharacters.contains($0) }) else {
            throw ResidentWebImageError.invalidURL
        }
        guard !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { throw ResidentWebImageError.invalidURL }
        guard !isLocalHostName(host) else { throw ResidentWebImageError.nonPublicAddress(host) }
        components.host = host
        components.scheme = "https"
        guard let normalized = components.url, normalized.scheme?.lowercased() == "https" else {
            throw ResidentWebImageError.invalidURL
        }
        let literal = isIPv4Literal(host) ? host : nil
        return ResidentWebImageTarget(url: normalized, host: host, literalAddress: literal)
    }

    /// mDNS/local names never reach a resolver.
    static func isLocalHostName(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost")
            || host == "local" || host.hasSuffix(".local")
            || host == "internal" || host.hasSuffix(".internal")
    }

    static func isIPv4Literal(_ host: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }

    /// True when the text contains a `%XX` escape for a C0 control or DEL byte.
    static func containsEncodedControlCharacter(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index + 2 < scalars.count {
            if scalars[index] == "%" {
                let hex = String(String.UnicodeScalarView(scalars[(index + 1)...(index + 2)]))
                if let value = UInt8(hex, radix: 16), value < 0x20 || value == 0x7F { return true }
                index += 3
                continue
            }
            index += 1
        }
        return false
    }

    // MARK: Address screening

    /// Picks one public IPv4. Any private answer together with a public one, or
    /// only private/loopback/link-local/reserved answers, or IPv6-only answers,
    /// is refused. This is the only place an address becomes trusted.
    static func screenedPublicAddress(_ host: String, _ addresses: [String]) throws -> String {
        guard !addresses.isEmpty else { throw ResidentWebImageError.dnsFailure }
        var publicAddresses: [String] = []
        var sawNonPublic = false
        var sawIPv6 = false
        for candidate in addresses {
            let address = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if address.contains(":") { sawIPv6 = true; continue }
            guard isIPv4Literal(address) else { throw ResidentWebImageError.dnsFailure }
            if isPublicIPv4(address) { publicAddresses.append(address) } else { sawNonPublic = true }
        }
        if sawNonPublic, !publicAddresses.isEmpty { throw ResidentWebImageError.mixedPublicPrivateDNS }
        if sawNonPublic { throw ResidentWebImageError.nonPublicAddress(host) }
        guard let pinned = publicAddresses.first else {
            if sawIPv6 { throw ResidentWebImageError.ipv6Unsupported }
            throw ResidentWebImageError.dnsFailure
        }
        return pinned
    }

    /// Every range that must never be dialed: this-network, private, CGNAT,
    /// loopback, link-local, IETF/documentation/benchmark reservations,
    /// multicast and the reserved class E / broadcast block.
    static func isPublicIPv4(_ address: String) -> Bool {
        var raw = in_addr()
        guard inet_pton(AF_INET, address, &raw) == 1 else { return false }
        let value = UInt32(bigEndian: raw.s_addr)
        return !forbiddenIPv4Ranges.contains { network, mask in (value & mask) == network }
    }

    private static let forbiddenIPv4Ranges: [(network: UInt32, mask: UInt32)] = [
        (0x00000000, 0xFF000000), // 0.0.0.0/8 this network
        (0x0A000000, 0xFF000000), // 10.0.0.0/8 private
        (0x64400000, 0xFFC00000), // 100.64.0.0/10 shared CGNAT
        (0x7F000000, 0xFF000000), // 127.0.0.0/8 loopback
        (0xA9FE0000, 0xFFFF0000), // 169.254.0.0/16 link-local
        (0xAC100000, 0xFFF00000), // 172.16.0.0/12 private
        (0xC0000000, 0xFFFFFF00), // 192.0.0.0/24 IETF protocol assignments
        (0xC0000200, 0xFFFFFF00), // 192.0.2.0/24 documentation
        (0xC0586300, 0xFFFFFF00), // 192.88.99.0/24 6to4 relay anycast
        (0xC0A80000, 0xFFFF0000), // 192.168.0.0/16 private
        (0xC6120000, 0xFFFE0000), // 198.18.0.0/15 benchmarking
        (0xC6336400, 0xFFFFFF00), // 198.51.100.0/24 documentation
        (0xCB007100, 0xFFFFFF00), // 203.0.113.0/24 documentation
        (0xE0000000, 0xF0000000), // 224.0.0.0/4 multicast
        (0xF0000000, 0xF0000000)  // 240.0.0.0/4 reserved and 255.255.255.255
    ]

    // MARK: Content validation

    static let allowedImageMIMETypes: Set<String> = [
        "image/png", "image/jpeg", "image/webp", "image/gif",
        "image/heic", "image/heif", "image/bmp", "image/tiff"
    ]

    /// Lowercases the media type, drops any parameters and folds the legacy
    /// `image/jpg` alias to the registered `image/jpeg`. An absent or empty header
    /// is refused because every caller needs a media type to judge the bytes.
    static func normalizedMIMEType(_ raw: String?) throws -> String {
        guard let raw else { throw ResidentWebImageError.missingContentType }
        let media = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !media.isEmpty else { throw ResidentWebImageError.missingContentType }
        return media == "image/jpg" ? "image/jpeg" : media
    }

    /// Only raster formats ImageIO can decode are accepted. SVG is XML, not an
    /// image, and is refused here before any decoding is attempted.
    static func allowedImageMIMEType(_ raw: String?) throws -> String {
        let normalized = try normalizedMIMEType(raw)
        guard allowedImageMIMETypes.contains(normalized) else {
            throw ResidentWebImageError.unsupportedContentType(normalized)
        }
        return normalized
    }

    /// The bytes must really decode as the declared media type. A text/HTML or
    /// JPEG payload behind `image/png` is refused instead of being trusted.
    static func verifyImageBody(_ data: Data, declaredMIMEType: String) throws {
        guard !data.isEmpty else { throw ResidentWebImageError.emptyResponse }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              let uniformType = UTType(type),
              uniformType.conforms(to: .image),
              let actualMIMEType = uniformType.preferredMIMEType?.lowercased(),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= Double(maximumPixelCount) else {
            throw ResidentWebImageError.notAnImage
        }
        let actual = actualMIMEType == "image/jpg" ? "image/jpeg" : actualMIMEType
        let expected = declaredMIMEType == "image/jpg" ? "image/jpeg" : declaredMIMEType
        let heifFamily: Set<String> = ["image/heic", "image/heif"]
        let matches = actual == expected || (heifFamily.contains(actual) && heifFamily.contains(expected))
        guard matches else { throw ResidentWebImageError.notAnImage }
    }

    // MARK: Private staging

    static func makePrivateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmgn-public-image-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw ResidentWebImageError.transportFailure("temporary-directory")
        }
        return directory
    }

    static func writePrivate(_ data: Data, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent("image-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else {
            throw ResidentWebImageError.transportFailure("temporary-file")
        }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw ResidentWebImageError.transportFailure("temporary-file")
        }
        return file
    }
}

/// Bounded incremental parser for a single curl response stream.
///
/// curl writes the header block and the body to stdout in order. The parser
/// never grows past `maximumBytes + 64 KiB` and refuses a declaration or a
/// streamed body that exceeds the caller budget, stopping the read immediately.
struct ResidentWebImageResponseStream {
    private let maximumBytes: Int
    private var buffer = Data()
    private var bodyStart: Int?
    private var statusCode: Int?
    private var headers: [String: String] = [:]

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    mutating func consume(_ chunk: Data) throws {
        guard !chunk.isEmpty else { return }
        let previousCount = buffer.count
        buffer.append(chunk)
        if bodyStart == nil {
            let searchStart = max(0, previousCount - 3)
            let terminator = Self.headerTerminator(in: buffer, from: searchStart)
            // The header budget is checked before anything else, whether or not a
            // terminator was found. A present terminator must not launder a header
            // block that is itself over budget.
            let headerEnd = terminator?.lowerBound ?? buffer.count
            if headerEnd > ResidentWebImageDownloader.maximumHeaderBytes {
                throw ResidentWebImageError.responseTooLarge
            }
            if let terminator {
                try parseHeaders(buffer[..<terminator.lowerBound])
                bodyStart = terminator.upperBound
                if let declared = headers["content-length"]?.trimmingCharacters(in: .whitespaces),
                   let length = Int(declared), length > maximumBytes {
                    throw ResidentWebImageError.responseTooLarge
                }
            }
        }
        if let bodyStart, buffer.count - bodyStart > maximumBytes {
            throw ResidentWebImageError.responseTooLarge
        }
    }

    func finish() throws -> ResidentWebImageRawResponse {
        guard let bodyStart, let statusCode else { throw ResidentWebImageError.transportFailure("malformed-response") }
        return ResidentWebImageRawResponse(statusCode: statusCode, headers: headers,
            body: Data(buffer[bodyStart...]))
    }

    private static func headerTerminator(in data: Data, from start: Int) -> Range<Int>? {
        let lowerBound = min(max(0, start), data.count)
        let range = lowerBound..<data.count
        let crlf = data.range(of: Data([13, 10, 13, 10]), in: range)
        let lf = data.range(of: Data([10, 10]), in: range)
        switch (crlf, lf) {
        case let (first?, second?): return first.lowerBound <= second.lowerBound ? first : second
        case let (first?, nil): return first
        case let (nil, second?): return second
        default: return nil
        }
    }

    private mutating func parseHeaders(_ block: Data) throws {
        guard let text = String(data: block, encoding: .utf8) ?? String(data: block, encoding: .isoLatin1) else {
            throw ResidentWebImageError.transportFailure("malformed-response")
        }
        // Swift folds CRLF into one Character, so split on newline Characters
        // instead of searching for a bare "\n".
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).map(String.init)
        guard let statusLine = lines.first else { throw ResidentWebImageError.transportFailure("malformed-response") }
        let codeToken = statusLine.components(separatedBy: " ").first { $0.count == 3 && Int($0) != nil }
        guard let codeToken, let code = Int(codeToken) else {
            throw ResidentWebImageError.transportFailure("malformed-response")
        }
        statusCode = code
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }
}

/// Production hostname resolver. It asks the system for IPv4 only, so a name
/// whose only answers are IPv6 fails closed instead of being dialed over IPv6.
struct ResidentWebImageSystemResolver: ResidentWebImageAddressResolving {
    func ipv4Addresses(forHost host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, "443", &hints, &result)
                guard status == 0, let head = result else {
                    continuation.resume(throwing: ResidentWebImageError.dnsFailure)
                    return
                }
                defer { freeaddrinfo(head) }
                var addresses: [String] = []
                var node: UnsafeMutablePointer<addrinfo>? = head
                while let current = node {
                    if current.pointee.ai_family == AF_INET, let raw = current.pointee.ai_addr {
                        var storage = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if inet_ntop(AF_INET, &storage.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil {
                            addresses.append(String(cString: text))
                        }
                    }
                    node = current.pointee.ai_next
                }
                guard !addresses.isEmpty else {
                    continuation.resume(throwing: ResidentWebImageError.dnsFailure)
                    return
                }
                continuation.resume(returning: Array(Set(addresses)).sorted())
            }
        }
    }
}

/// Sole owner of one spawned curl child.
///
/// The child is created with `posix_spawn`, never `Foundation.Process`. A single
/// dedicated reaper thread is the only code that ever calls `waitpid` for this
/// pid, and it is also the only code that ever sends this child a signal. The
/// "has it been reaped?" decision and the kill therefore happen on one thread, so
/// a pid can never be recycled in between: a child that has exited but has not
/// been reaped is a zombie whose pid is still ours. There is no
/// `Process.isRunning` followed by a separate `kill`, and no `waitUntilExit()`.
///
/// stdout is read with a bounded, non-blocking `poll` loop that also watches an
/// abort flag. Killing the direct child therefore never waits for a descendant
/// that inherited stdout to close it.
private final class ResidentWebImageCurlProcess: @unchecked Sendable {
    /// How long a terminating child gets before it is force-killed, and how long
    /// a force-killed child gets for its exit before the caller gives up.
    static let terminationGrace: TimeInterval = 2
    static let forcedGrace: TimeInterval = 2
    /// Bounded slice for every `poll`, so abort and exit are observed promptly.
    private static let pollSliceMilliseconds: Int32 = 50

    private static let terminateCommand: UInt8 = 0x54 // 'T'
    private static let killCommand: UInt8 = 0x4B      // 'K'

    private let pid: pid_t
    private let stdoutReadFD: Int32
    private let controlReadFD: Int32
    private let controlWriteFD: Int32

    /// Exit state, read by every thread and written only by the reaper.
    private let state = NSCondition()
    private var reapFinished = false
    private var reapedStatus: Int32?
    private var pendingError: Error?
    private var completed = false
    private var readingAborted = false

    private let stdoutLock = NSLock()
    private var stdoutClosed = false
    private let controlLock = NSLock()
    private var controlClosed = false

    /// Spawns the child with stdin from `/dev/null`, stdout to a pipe and stderr
    /// to `/dev/null`, then starts the sole reaper. The child receives exactly
    /// `arguments` as argv and `environment` as its whole environment; no shell
    /// and no inherited parent environment are involved. `POSIX_SPAWN_CLOEXEC_DEFAULT`
    /// makes the child inherit no descriptor except the explicit stdio above, so
    /// unrelated app sockets and concurrent downloads' pipes never leak in.
    init(executableURL: URL, arguments: [String], environment: [String: String]) throws {
        var stdoutPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else {
            throw ResidentWebImageError.transportFailure("curl-pipe")
        }
        // Every parent end is close-on-exec from the moment it exists, so a
        // concurrent spawn elsewhere in the process cannot inherit this pipe.
        guard Self.markCloseOnExec(stdoutPipe) else {
            Self.closeAll(stdoutPipe)
            throw ResidentWebImageError.transportFailure("curl-pipe")
        }
        var controlPipe: [Int32] = [-1, -1]
        guard pipe(&controlPipe) == 0 else {
            Self.closeAll(stdoutPipe)
            throw ResidentWebImageError.transportFailure("curl-pipe")
        }
        guard Self.markCloseOnExec(controlPipe) else {
            Self.closeAll(stdoutPipe); Self.closeAll(controlPipe)
            throw ResidentWebImageError.transportFailure("curl-pipe")
        }
        // Both read ends are non-blocking and the control write end must not
        // raise SIGPIPE. This is configured before the spawn, so a failure is
        // reported with the descriptors closed and no child left behind; the
        // stdout write end stays blocking because it becomes the child's fd 1.
        guard Self.setNonBlocking(stdoutPipe[0]),
              Self.setNonBlocking(controlPipe[0]),
              Self.setNoSIGPIPE(controlPipe[1]) else {
            Self.closeAll(stdoutPipe); Self.closeAll(controlPipe)
            throw ResidentWebImageError.transportFailure("curl-launch")
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            Self.closeAll(stdoutPipe); Self.closeAll(controlPipe)
            throw ResidentWebImageError.transportFailure("curl-launch")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Exactly stdio: fd 0 and fd 2 from `/dev/null`, fd 1 the stdout pipe, and
        // the three other parent pipe ends explicitly closed. Every return value
        // is checked; a half-built action list must never reach `posix_spawn`.
        guard posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1) == 0,
              posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, controlPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, controlPipe[1]) == 0 else {
            Self.closeAll(stdoutPipe); Self.closeAll(controlPipe)
            throw ResidentWebImageError.transportFailure("curl-launch")
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            Self.closeAll(stdoutPipe); Self.closeAll(controlPipe)
            throw ResidentWebImageError.transportFailure("curl-launch")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            Self.closeAll(stdoutPipe); Self.closeAll(controlPipe)
            throw ResidentWebImageError.transportFailure("curl-launch")
        }

        let path = executableURL.path
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        var childPID: pid_t = 0
        let spawnResult: Int32 = argv.withUnsafeMutableBufferPointer { argumentBuffer in
            envp.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(&childPID, path, &actions, &attributes,
                    argumentBuffer.baseAddress, environmentBuffer.baseAddress)
            }
        }
        for pointer in argv where pointer != nil { free(pointer) }
        for pointer in envp where pointer != nil { free(pointer) }
        // The parent must drop the write end or the reader would never see EOF.
        close(stdoutPipe[1])
        guard spawnResult == 0, childPID > 0 else {
            close(stdoutPipe[0]); close(controlPipe[0]); close(controlPipe[1])
            throw ResidentWebImageError.transportFailure("curl-launch")
        }
        self.pid = childPID
        self.stdoutReadFD = stdoutPipe[0]
        self.controlReadFD = controlPipe[0]
        self.controlWriteFD = controlPipe[1]
        Thread.detachNewThread { [self] in runReaper() }
    }

    /// Sets `FD_CLOEXEC` on every descriptor. A failure means the descriptor set
    /// cannot be made safe to inherit, so the caller must close and report.
    private static func markCloseOnExec(_ descriptors: [Int32]) -> Bool {
        for descriptor in descriptors {
            if !setCloseOnExec(descriptor) { return false }
        }
        return true
    }

    private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags != -1 else { return false }
        return fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != -1
    }

    private static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1 else { return false }
        return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1
    }

    private static func setNoSIGPIPE(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1
    }

    private static func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
    }

    deinit {
        // The reaper closes the control pipe itself; close the read end even if a
        // caller never reached `closeStdoutReadEnd`.
        closeStdoutReadEnd()
    }

    // MARK: Sole reaper

    /// The only loop that reaps this child and the only loop that signals it.
    /// `waitpid(WNOHANG)` returning 0 means the child still exists and has not
    /// been reaped, so a `kill` issued from here can only reach this child.
    private func runReaper() {
        while true {
            var raw: Int32 = 0
            let result = waitpid(pid, &raw, WNOHANG)
            if result == pid {
                finishReap(Self.decodeStatus(raw))
                closeControlPipe()
                return
            }
            if result == -1 {
                if errno == EINTR { continue }
                // The child is gone with no status we can decode (ECHILD).
                finishReap(nil)
                closeControlPipe()
                return
            }
            drainControlCommands()
        }
    }

    private func drainControlCommands() {
        var descriptor = pollfd(fd: controlReadFD, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Self.pollSliceMilliseconds)
        guard ready > 0, (descriptor.revents & Int16(POLLIN)) != 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let count = read(controlReadFD, &buffer, buffer.count)
            if count > 0 {
                for index in 0..<count {
                    switch buffer[index] {
                    case Self.terminateCommand: _ = kill(pid, SIGTERM)
                    case Self.killCommand: _ = kill(pid, SIGKILL)
                    default: break
                    }
                }
                continue
            }
            if count == -1 && errno == EINTR { continue }
            break
        }
    }

    private func finishReap(_ status: Int32?) {
        state.lock()
        reapFinished = true
        reapedStatus = status
        state.broadcast()
        state.unlock()
    }

    // MARK: Signals

    /// Asks the owner to send SIGTERM. `error` is remembered once so cancellation
    /// and timeout keep their own failure identity, while a reader failure stays
    /// the error that is reported. The owner only signals a child it has not
    /// reaped, so this can never target a recycled pid.
    func terminate(storing error: Error? = nil) {
        state.lock()
        if let error, pendingError == nil { pendingError = error }
        readingAborted = true
        let finished = reapFinished
        state.unlock()
        guard !finished else { return }
        writeCommand(Self.terminateCommand)
    }

    /// Asks the owner to send SIGKILL after a SIGTERM that was not honored.
    private func forceKill() {
        state.lock()
        let finished = reapFinished
        state.unlock()
        guard !finished else { return }
        writeCommand(Self.killCommand)
    }

    private func writeCommand(_ command: UInt8) {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard !controlClosed else { return }
        var byte = command
        while true {
            let written = write(controlWriteFD, &byte, 1)
            if written == 1 { return }
            if written == -1 && errno == EINTR { continue }
            return
        }
    }

    func markCompleted() {
        state.lock(); completed = true; state.unlock()
    }

    func isCompleted() -> Bool {
        state.lock(); defer { state.unlock() }; return completed
    }

    func pendingErrorValue() -> Error? {
        state.lock(); defer { state.unlock() }; return pendingError
    }

    // MARK: Bounded waits

    private func waitForReap(seconds: TimeInterval) -> Int32? {
        state.lock()
        if !reapFinished {
            let deadline = Date().addingTimeInterval(max(0, seconds))
            while !reapFinished {
                if !state.wait(until: deadline) { break }
            }
        }
        let status = reapFinished ? reapedStatus : nil
        state.unlock()
        return status
    }

    /// Non-blocking snapshot of the reap outcome for the async `finish`.
    /// `NSCondition.lock()`/`unlock()` are unavailable from asynchronous contexts
    /// in Swift 6, so the scoped read stays in a synchronous helper.
    private func currentReapStatus() -> Int32? {
        state.lock()
        defer { state.unlock() }
        return reapFinished ? reapedStatus : nil
    }

    func awaitExit(timeout: TimeInterval) async -> Int32? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.waitForReap(seconds: timeout))
            }
        }
    }

    /// Waits for the child with a bounded escalation. `terminate` sends SIGTERM
    /// first; otherwise a naturally exiting child is given the same grace, and a
    /// child that lingers after its stdout closed is still force-killed.
    func finish(terminate shouldTerminate: Bool) async -> Int32? {
        if shouldTerminate { self.terminate() }
        if let status = await awaitExit(timeout: Self.terminationGrace) { return status }
        forceKill()
        if let status = await awaitExit(timeout: Self.forcedGrace) { return status }
        // Either a reap with no decodable status, or a child the reaper has not
        // observed yet; never fabricate a status.
        return currentReapStatus()
    }

    /// Decodes the raw `waitpid` status without the `WIFEXITED` C macros, which
    /// Swift does not import.
    private static func decodeStatus(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7F
        if signal == 0 { return (raw >> 8) & 0xFF }
        if signal != 0x7F { return 128 + signal }
        return raw
    }

    // MARK: Bounded, abortable stdout read

    func readResponse(maximumBytes: Int) async throws -> ResidentWebImageRawResponse {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResidentWebImageRawResponse, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.readBounded(maximumBytes: maximumBytes))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Reads stdout in bounded `poll` slices. It stops at EOF, on a read error or
    /// as soon as the owner aborts the read, so a descendant that still holds the
    /// write end can never pin this call.
    private func readBounded(maximumBytes: Int) throws -> ResidentWebImageRawResponse {
        var stream = ResidentWebImageResponseStream(maximumBytes: maximumBytes)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if isReadingAborted() { break }
            var descriptor = pollfd(fd: stdoutReadFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Self.pollSliceMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw ResidentWebImageError.transportFailure("read")
            }
            if ready == 0 { continue }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                throw ResidentWebImageError.transportFailure("read")
            }
            let count = read(stdoutReadFD, &buffer, buffer.count)
            if count > 0 {
                try stream.consume(Data(buffer[0..<count]))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                // A hung-up or errored pipe that yields no bytes is EOF-equivalent
                // here; anything else waits for the next bounded poll slice.
                if descriptor.revents & Int16(POLLHUP | POLLERR) != 0 { break }
                continue
            }
            throw ResidentWebImageError.transportFailure("read")
        }
        return try stream.finish()
    }

    private func isReadingAborted() -> Bool {
        state.lock(); defer { state.unlock() }
        return readingAborted
    }

    // MARK: Descriptor ownership

    func closeStdoutReadEnd() {
        stdoutLock.lock()
        let alreadyClosed = stdoutClosed
        stdoutClosed = true
        let descriptor = stdoutReadFD
        stdoutLock.unlock()
        guard !alreadyClosed else { return }
        close(descriptor)
    }

    /// Called only by the reaper as it exits, so its own `poll` can never race a
    /// close; writers are serialized by `controlLock`.
    private func closeControlPipe() {
        controlLock.lock()
        let alreadyClosed = controlClosed
        controlClosed = true
        let readDescriptor = controlReadFD
        let writeDescriptor = controlWriteFD
        controlLock.unlock()
        guard !alreadyClosed else { return }
        close(readDescriptor)
        close(writeDescriptor)
    }
}

/// Production transport: an argument-array curl subprocess with a clean
/// environment, an exact `--resolve` pin, no automatic redirect, and a bounded
/// streaming read of stdout.
struct ResidentWebImageCurlTransport: ResidentWebImageTransporting {
    private let executableURL: URL
    private let configuredTimeout: TimeInterval
    private let environment: [String: String]

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/curl"),
         timeout: TimeInterval = ResidentWebImageDownloader.defaultTimeout,
         environment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.configuredTimeout = timeout
        self.environment = environment
    }

    /// The exact argv used for one request. It is a plain array: no shell is
    /// involved, so no argument can be re-split or expanded.
    static func arguments(for request: ResidentWebImageTransportRequest) -> [String] {
        let timeout = max(1, Int(ceil(request.timeout)))
        var arguments = [
            "--disable",
            "--silent",
            "--show-error",
            "--no-progress-meter",
            "--globoff",
            "--path-as-is",
            "--http1.1",
            "--proxy", "",
            "--noproxy", "*",
            "--proto", "=https",
            "--request", "GET",
            "--max-time", String(timeout),
            "--connect-timeout", String(min(10, timeout)),
            "--user-agent", "gmgn-radio-reference-image/1"
        ]
        if request.address != request.host {
            arguments += ["--resolve", "\(request.host):443:\(request.address)"]
        }
        arguments += ["--dump-header", "-", "--", request.url.absoluteString]
        return arguments
    }

    func perform(_ request: ResidentWebImageTransportRequest) async throws -> ResidentWebImageRawResponse {
        try Task.checkCancellation()
        guard request.maximumBytes > 0 else { throw ResidentWebImageError.invalidArgument }
        let timeout = request.timeout > 0 ? min(request.timeout, configuredTimeout) : configuredTimeout
        let child: ResidentWebImageCurlProcess
        do {
            child = try ResidentWebImageCurlProcess(executableURL: executableURL,
                arguments: Self.arguments(for: request), environment: environment)
        } catch {
            throw ResidentWebImageError.transportFailure("curl-launch")
        }
        let deadline = Self.nanoseconds(timeout)
        do {
            let response = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: ResidentWebImageRawResponse.self) { group in
                    group.addTask { try await child.readResponse(maximumBytes: request.maximumBytes) }
                    group.addTask {
                        do {
                            try await Task.sleep(nanoseconds: deadline)
                        } catch {
                            throw CancellationError()
                        }
                        if child.isCompleted() { throw CancellationError() }
                        child.terminate(storing: ResidentWebImageError.timeout)
                        throw ResidentWebImageError.timeout
                    }
                    do {
                        guard let response = try await group.next() else {
                            throw ResidentWebImageError.transportFailure("no-response")
                        }
                        // The body is fully read. Do not kill the child: let it
                        // exit naturally and verify its status. A child that
                        // lingers after closing stdout is still bounded by
                        // `finish(terminate:)`.
                        child.markCompleted()
                        group.cancelAll()
                        _ = try? await group.waitForAll()
                        if Task.isCancelled {
                            _ = await child.finish(terminate: true)
                            throw CancellationError()
                        }
                        let status = await child.finish(terminate: false)
                        // A cancellation that landed while the natural exit was
                        // being awaited is only observable here; never report a
                        // cancelled request as a successful download.
                        try Task.checkCancellation()
                        if let pending = child.pendingErrorValue() { throw pending }
                        guard status == 0 else {
                            throw ResidentWebImageError.transportFailure("curl-exit-\(status.map { String($0) } ?? "unknown")")
                        }
                        return response
                    } catch {
                        child.markCompleted()
                        group.cancelAll()
                        _ = await child.finish(terminate: true)
                        _ = try? await group.waitForAll()
                        if Task.isCancelled { throw CancellationError() }
                        if let pending = child.pendingErrorValue() { throw pending }
                        throw error
                    }
                }
            } onCancel: {
                child.terminate()
            }
            child.closeStdoutReadEnd()
            return response
        } catch {
            child.closeStdoutReadEnd()
            throw error
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        let bounded = seconds.isFinite ? max(0.05, min(seconds, 3_600)) : ResidentWebImageDownloader.defaultTimeout
        return UInt64(bounded * 1_000_000_000)
    }
}
