import Foundation

/// Resolves public hostnames to IPv4 addresses with Google's DNS-over-HTTPS
/// JSON API over an address-pinned HTTPS connection instead of the local system
/// resolver.
///
/// The proxy in front of this machine answers many names with a fake address in
/// the benchmarking range (for example `commons.wikimedia.org` -> `198.18.0.161`),
/// which the downloader must keep refusing; a trusted public resolver reached
/// over a pinned HTTPS request recovers the real A records without ever trusting
/// local DNS.
///
/// Every security-relevant value is a compile-time constant, not an argument:
/// - the endpoint is exactly `https://dns.google/resolve`, dialed at `8.8.8.8`;
/// - the query carries only `name=<host>` and `type=A`;
/// - redirects are never followed, the body is capped at 64 KiB and the request
///   times out after 10 seconds;
/// - each answer is screened by `ResidentWebImageDownloader.screenedPublicAddress`
///   before it is returned, so private/mixed/IPv6/reserved answers fail closed;
/// - neither the query content nor any credential is logged.
struct ResidentWebImagePublicDNSResolver: ResidentWebImageAddressResolving, Sendable {
    static let endpointURL = URL(string: "https://dns.google/resolve")!
    static let endpointHost = "dns.google"
    static let endpointAddress = "8.8.8.8"
    static let maximumBytes = 64 * 1024
    static let timeout: TimeInterval = 10
    /// Upper bound on `Answer` entries inspected; a larger array is refused
    /// rather than walked.
    static let maximumAnswerCount = 64

    private let transport: any ResidentWebImageTransporting

    /// The production default talks to the real resolver through the pinned curl
    /// transport. Offline tests inject a scripted transport.
    init(transport: any ResidentWebImageTransporting = ResidentWebImageCurlTransport()) {
        self.transport = transport
    }

    /// Resolves `host` through the fixed DoH endpoint. The returned addresses are
    /// unique, sorted, and already verified public.
    func ipv4Addresses(forHost host: String) async throws -> [String] {
        try Task.checkCancellation()
        let name = try Self.validatedHost(host)
        let request = ResidentWebImageTransportRequest(url: try Self.queryURL(forHost: name),
            host: Self.endpointHost, address: Self.endpointAddress,
            maximumBytes: Self.maximumBytes, timeout: Self.timeout)
        let response = try await transport.perform(request)
        try Task.checkCancellation()
        let addresses = try Self.addresses(in: response, forHost: name)
        try Task.checkCancellation()
        // Reuse the downloader's only trust boundary: private/loopback/reserved
        // answers, mixed public+private lists and IPv6 answers are refused here
        // too, so this type can never hand out an unscreened address.
        _ = try ResidentWebImageDownloader.screenedPublicAddress(name, addresses)
        return addresses
    }

    // MARK: Query construction

    /// The fixed endpoint with exactly the two parameters the DoH JSON API needs.
    /// `URLComponents` percent-encodes the name, so a caller cannot append
    /// another parameter through the host string.
    static func queryURL(forHost host: String) throws -> URL {
        let name = try validatedHost(host)
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpointHost
        components.path = "/resolve"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "type", value: "A")
        ]
        guard let url = components.url, url.scheme == "https", url.host == endpointHost, url.path == "/resolve" else {
            throw ResidentWebImageError.invalidURL
        }
        return url
    }

    /// `host` must already look like a public DNS name: no scheme, path,
    /// credentials, port, whitespace, literal, local suffix or empty label.
    static func validatedHost(_ host: String) throws -> String {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !normalized.isEmpty, normalized.unicodeScalars.count <= 253,
              normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !normalized.hasPrefix("."), !normalized.hasSuffix("."), !normalized.contains(".."),
              !ResidentWebImageDownloader.isLocalHostName(normalized),
              !ResidentWebImageDownloader.isIPv4Literal(normalized) else {
            throw ResidentWebImageError.invalidArgument
        }
        return normalized
    }

    // MARK: Response parsing

    /// Validates the HTTP envelope and the DoH JSON body, then extracts only the
    /// A records. CNAME and any other record type is allowed but is never read as
    /// an IP, so the answer list really is IPv4 dotted quads.
    static func addresses(in response: ResidentWebImageRawResponse, forHost host: String) throws -> [String] {
        guard response.statusCode == 200 else { throw ResidentWebImageError.httpStatus(response.statusCode) }
        guard response.body.count <= maximumBytes else { throw ResidentWebImageError.responseTooLarge }
        try validateContentType(response.headers["content-type"])
        guard let object = try? JSONSerialization.jsonObject(with: response.body),
              let json = object as? [String: Any] else {
            throw ResidentWebImageError.dnsFailure
        }
        // Strict envelope: Status must be the integer 0 and TC the boolean false.
        guard number(json["Status"]) == 0, boolean(json["TC"]) == false else {
            throw ResidentWebImageError.dnsFailure
        }
        guard let questions = json["Question"] as? [[String: Any]], questions.count == 1,
              let question = questions.first,
              number(question["type"]) == 1,
              let questionName = question["name"] as? String,
              normalizedDNSName(questionName) == host else {
            throw ResidentWebImageError.dnsFailure
        }
        let answers = json["Answer"] as? [[String: Any]] ?? []
        guard answers.count <= maximumAnswerCount else { throw ResidentWebImageError.responseTooLarge }
        var addresses: [String] = []
        for answer in answers {
            guard number(answer["type"]) == 1 else { continue }
            guard let data = answer["data"] as? String else { throw ResidentWebImageError.dnsFailure }
            let address = data.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ResidentWebImageDownloader.isIPv4Literal(address) else { throw ResidentWebImageError.dnsFailure }
            addresses.append(address)
        }
        guard !addresses.isEmpty else { throw ResidentWebImageError.dnsFailure }
        return Array(Set(addresses)).sorted()
    }

    static func validateContentType(_ raw: String?) throws {
        guard let raw else { throw ResidentWebImageError.missingContentType }
        let media = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard media == "application/json" || media == "application/dns-json" else {
            throw ResidentWebImageError.unsupportedContentType(media)
        }
    }

    /// JSON booleans and numbers both bridge to `NSNumber`; only a real
    /// `CFBoolean` counts as a boolean here.
    static func boolean(_ value: Any?) -> Bool? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }

    /// An integer JSON number, rejecting booleans so `true` cannot pass as `1` and
    /// rejecting fractional values so `0.5` cannot truncate to `0` (or `1.5` to
    /// `1`) through `NSNumber.intValue`. An integer-valued double such as `0.0` is
    /// still exact and is accepted.
    static func number(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        switch String(cString: number.objCType) {
        case "d", "f":
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(.towardZero) else { return nil }
            return Int(exactly: double)
        default:
            return number.intValue
        }
    }

    /// DNS names in answers carry a trailing root dot; compare canonically.
    static func normalizedDNSName(_ name: String) -> String {
        var normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix(".") { normalized.removeLast() }
        return normalized
    }
}
