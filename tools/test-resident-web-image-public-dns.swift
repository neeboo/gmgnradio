// Offline red/green checks for the resident public-DNS (DNS-over-HTTPS) resolver.
// No network, no app, no daemon, no GPU: a scripted transport drives the real
// production validation logic, so endpoint pinning, DoH response parsing,
// address screening and cancellation are all exercised without a socket.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentWebImagePublicDNSResolver.swift")
let downloader = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentWebImageDownloader.swift")
let preparation = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropImagePreparation.swift")
let generation = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift")
guard FileManager.default.fileExists(atPath: source.path),
      FileManager.default.fileExists(atPath: downloader.path),
      FileManager.default.fileExists(atPath: preparation.path),
      FileManager.default.fileExists(atPath: generation.path) else {
    print("FAIL: resident public DNS resolver is missing")
    exit(1)
}

let harness = #"""
import Foundation

// MARK: - Scripted transport

final class ScriptedTransport: ResidentWebImageTransporting, @unchecked Sendable {
    struct Call: Sendable {
        let url: URL
        let host: String
        let address: String
        let maximumBytes: Int
        let timeout: TimeInterval
    }
    private let lock = NSLock()
    private var calls: [Call] = []
    private var handler: (@Sendable (ResidentWebImageTransportRequest) async throws -> ResidentWebImageRawResponse)?

    init(_ handler: (@Sendable (ResidentWebImageTransportRequest) async throws -> ResidentWebImageRawResponse)? = nil) {
        self.handler = handler
    }
    func setHandler(_ handler: @escaping @Sendable (ResidentWebImageTransportRequest) async throws -> ResidentWebImageRawResponse) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    var recordedCalls: [Call] {
        lock.lock(); defer { lock.unlock() }; return calls
    }
    func resetCalls() {
        lock.lock(); calls.removeAll(); lock.unlock()
    }
    func perform(_ request: ResidentWebImageTransportRequest) async throws -> ResidentWebImageRawResponse {
        lock.lock()
        calls.append(Call(url: request.url, host: request.host, address: request.address,
            maximumBytes: request.maximumBytes, timeout: request.timeout))
        let handler = self.handler
        lock.unlock()
        guard let handler else { throw ResidentWebImageError.transportFailure("no-script") }
        return try await handler(request)
    }
}

func raw(_ status: Int, _ headers: [String: String], _ body: Data) -> ResidentWebImageRawResponse {
    ResidentWebImageRawResponse(statusCode: status, headers: headers, body: body)
}

// MARK: - DoH JSON fixtures (shape of dns.google /resolve)

let queryHost = "commons.wikimedia.org"
let realAddress = "198.35.26.224"

func aRecord(_ address: String, name: String = "commons.wikimedia.org.") -> [String: Any] {
    ["name": name, "type": 1, "TTL": 300, "data": address]
}
func cnameRecord(_ target: String, name: String = "commons.wikimedia.org.") -> [String: Any] {
    ["name": name, "type": 5, "TTL": 300, "data": target]
}
func aaaaRecord(_ address: String, name: String = "commons.wikimedia.org.") -> [String: Any] {
    ["name": name, "type": 28, "TTL": 300, "data": address]
}
func dohBody(status: Int = 0, tc: Bool = false, includeTC: Bool = true,
             questionName: String = "commons.wikimedia.org.", questionType: Int = 1,
             includeQuestion: Bool = true, questionCount: Int = 1,
             answers: [[String: Any]]? = nil) -> Data {
    var json: [String: Any] = ["Status": status, "RD": true, "RA": true]
    if includeTC { json["TC"] = tc }
    if includeQuestion {
        json["Question"] = (0..<questionCount).map { _ in ["name": questionName, "type": questionType] }
    }
    if let answers { json["Answer"] = answers }
    return try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
}

func helperValue(_ flag: String, _ arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func requireSendable<T: Sendable>(_ type: T.Type) {}

func waitBriefly() async {
    try? await Task.sleep(nanoseconds: 5_000_000)
}

// MARK: - Checks

@main struct Checks {
    static func main() async throws {
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
        func rejectedCancellation(_ label: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                checks += 1; failures += 1; print("FAIL(accepted): \(label)")
            } catch is CancellationError {
                checks += 1
            } catch {
                checks += 1; failures += 1; print("FAIL(other error \(error)): \(label)")
            }
        }

        requireSendable(ResidentWebImagePublicDNSResolver.self)
        let asProtocol: any ResidentWebImageAddressResolving = ResidentWebImagePublicDNSResolver(transport: ScriptedTransport())
        _ = asProtocol

        // 1. Fixed endpoint, fixed 8.8.8.8 pin, bounded budget, only name/type=A in the query.
        check(ResidentWebImagePublicDNSResolver.endpointURL.absoluteString == "https://dns.google/resolve",
            "endpoint is the fixed https dns.google/resolve URL")
        check(ResidentWebImagePublicDNSResolver.endpointHost == "dns.google", "endpoint host is fixed to dns.google")
        check(ResidentWebImagePublicDNSResolver.endpointAddress == "8.8.8.8", "endpoint address is fixed to 8.8.8.8")
        check(ResidentWebImagePublicDNSResolver.maximumBytes == 64 * 1024, "response budget is 64 KiB")
        check(ResidentWebImagePublicDNSResolver.timeout == 10, "request timeout is 10 seconds")

        let transport = ScriptedTransport()
        let resolver = ResidentWebImagePublicDNSResolver(transport: transport)
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], dohBody(answers: [aRecord(realAddress)])) }
        let addresses = try await resolver.ipv4Addresses(forHost: queryHost)
        check(addresses == [realAddress], "a real public A answer is returned")
        guard let call = transport.recordedCalls.last else { print("FAIL: no transport call"); exit(1) }
        check(call.host == "dns.google", "transport host is the fixed DoH endpoint, never the queried host")
        check(call.address == "8.8.8.8", "transport dials the fixed 8.8.8.8 resolver address")
        check(call.host != queryHost && call.address != queryHost, "the queried host is never used as the dial target")
        check(call.maximumBytes == 64 * 1024, "transport receives the 64 KiB cap")
        check(call.timeout == 10, "transport receives the 10 second timeout")
        let components = URLComponents(url: call.url, resolvingAgainstBaseURL: false)
        check(components?.scheme == "https" && components?.host == "dns.google" && components?.path == "/resolve",
            "request URL is exactly the fixed https endpoint")
        let items = components?.queryItems ?? []
        check(items.count == 2 && Set(items.map(\.name)) == ["name", "type"],
            "query carries only name and type, no caller/model supplied parameters")
        check(items.first { $0.name == "name" }?.value == queryHost, "query name is the requested host")
        check(items.first { $0.name == "type" }?.value == "A", "query type is pinned to A")
        let direct = try ResidentWebImagePublicDNSResolver.queryURL(forHost: queryHost)
        let directItems = URLComponents(url: direct, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(direct.host == "dns.google" && direct.path == "/resolve" && directItems.count == 2
            && directItems.first { $0.name == "name" }?.value == queryHost
            && directItems.first { $0.name == "type" }?.value == "A",
            "the built URL keeps the fixed endpoint and the two fixed parameters")
        check(transport.recordedCalls.count == 1, "exactly one DNS request is made per resolution")

        // 1b. The real curl argv that would carry this request pins dns.google to
        // 8.8.8.8, stays https-only/proxy-free and never enables redirects. No
        // process is launched; this only reads the production argument builder.
        let curlRequest = ResidentWebImageTransportRequest(url: direct,
            host: ResidentWebImagePublicDNSResolver.endpointHost,
            address: ResidentWebImagePublicDNSResolver.endpointAddress,
            maximumBytes: ResidentWebImagePublicDNSResolver.maximumBytes,
            timeout: ResidentWebImagePublicDNSResolver.timeout)
        let curlArguments = ResidentWebImageCurlTransport.arguments(for: curlRequest)
        check(helperValue("--resolve", curlArguments) == "dns.google:443:8.8.8.8",
            "real curl pins dns.google to 8.8.8.8 instead of using system DNS")
        check(helperValue("--proto", curlArguments) == "=https", "real curl stays https-only")
        check(helperValue("--proxy", curlArguments) == "" && helperValue("--noproxy", curlArguments) == "*",
            "real curl ignores any environment proxy")
        check(!curlArguments.contains("--location") && !curlArguments.contains("-L")
            && !curlArguments.contains("--max-redirs"), "real curl never follows a redirect")
        check(helperValue("--max-time", curlArguments) == "10" && helperValue("--connect-timeout", curlArguments) == "10",
            "real curl enforces the 10 second budget")
        check(curlArguments.last == direct.absoluteString && curlArguments.contains("--")
            && direct.absoluteString.contains("name=commons.wikimedia.org") && direct.absoluteString.contains("type=A"),
            "real curl queries the fixed DoH URL with only name and type=A as the final operand")

        // 2. CNAME answers are allowed and never treated as addresses; multiple A answers are deduped.
        transport.setHandler { _ in
            raw(200, ["content-type": "application/dns-json"],
                dohBody(answers: [cnameRecord("upload.wikimedia.org."), aRecord(realAddress)]))
        }
        check(try await resolver.ipv4Addresses(forHost: queryHost) == [realAddress],
            "a CNAME hop followed by an A record resolves to the A address")
        transport.setHandler { _ in
            raw(200, ["content-type": "application/json"],
                dohBody(answers: [aRecord("8.8.8.8"), aRecord(realAddress), aRecord("8.8.8.8")]))
        }
        check(try await resolver.ipv4Addresses(forHost: queryHost) == ["198.35.26.224", "8.8.8.8"],
            "multiple public A answers are deduplicated and sorted")
        transport.setHandler { _ in
            raw(200, ["content-type": "application/json"], dohBody(answers: [cnameRecord("upload.wikimedia.org.")]))
        }
        await rejected("CNAME without an A record rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }

        // 3. Address screening: the resolver reuses the downloader's public-address rules.
        let refused: [(String, String)] = [
            ("proxy fake-IP 198.18.0.161", "198.18.0.161"),
            ("benchmark 198.19.255.255", "198.19.255.255"),
            ("private 10.0.0.1", "10.0.0.1"),
            ("CGNAT 100.64.0.1", "100.64.0.1"),
            ("loopback 127.0.0.1", "127.0.0.1"),
            ("link-local 169.254.1.1", "169.254.1.1"),
            ("metadata 169.254.169.254", "169.254.169.254"),
            ("private 172.16.5.5", "172.16.5.5"),
            ("private 192.168.1.1", "192.168.1.1"),
            ("IETF 192.0.0.1", "192.0.0.1"),
            ("documentation 192.0.2.10", "192.0.2.10"),
            ("documentation 198.51.100.7", "198.51.100.7"),
            ("documentation 203.0.113.9", "203.0.113.9"),
            ("multicast 224.0.0.1", "224.0.0.1"),
            ("reserved 240.0.0.1", "240.0.0.1"),
            ("broadcast 255.255.255.255", "255.255.255.255")
        ]
        for (label, address) in refused {
            transport.setHandler { _ in raw(200, ["content-type": "application/json"], dohBody(answers: [aRecord(address)])) }
            await rejected("\(label) rejected", { if case .nonPublicAddress = $0 { return true }; return false }) {
                _ = try await resolver.ipv4Addresses(forHost: queryHost)
            }
        }
        transport.setHandler { _ in
            raw(200, ["content-type": "application/json"], dohBody(answers: [aRecord(realAddress), aRecord("10.0.0.1")]))
        }
        await rejected("mixed public/private A answers rejected", { $0 == .mixedPublicPrivateDNS }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in
            raw(200, ["content-type": "application/json"], dohBody(answers: [aRecord("2606:4700:4700::1111")]))
        }
        await rejected("IPv6 data inside an A record rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in
            raw(200, ["content-type": "application/json"], dohBody(answers: [aRecord("not-an-ip")]))
        }
        await rejected("non-IP A data rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }

        // 4. DoH envelope: strict Status, TC, Question name/type and Answer typing.
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], dohBody(status: 3)) }
        await rejected("NXDOMAIN Status=3 rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], dohBody(status: 2)) }
        await rejected("SERVFAIL Status=2 rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], dohBody(tc: true, answers: [aRecord(realAddress)])) }
        await rejected("truncated TC=true rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], dohBody(includeTC: false, answers: [aRecord(realAddress)])) }
        await rejected("missing TC rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in
            raw(200, ["content-type": "application/json"], dohBody(questionName: "example.com.", answers: [aRecord(realAddress, name: "example.com.")]))
        }
        await rejected("question name mismatch rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in
            raw(200, ["content-type": "application/json"], dohBody(questionType: 28, answers: [aaaaRecord("2606:4700:4700::1111")]))
        }
        await rejected("question type AAAA mismatch rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], dohBody(includeQuestion: false, answers: [aRecord(realAddress)])) }
        await rejected("missing Question rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], dohBody(questionCount: 2, answers: [aRecord(realAddress)])) }
        await rejected("multiple Question entries rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], dohBody(answers: [])) }
        await rejected("empty Answer rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], dohBody()) }
        await rejected("absent Answer rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], Data("not json".utf8)) }
        await rejected("non-JSON body rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], Data("{".utf8)) }
        await rejected("truncated JSON rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], Data("[]".utf8)) }
        await rejected("non-object JSON rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], Data("{}".utf8)) }
        await rejected("object without Status rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        let booleanStatus = Data(#"{"Status": false, "TC": false, "Question": [{"name": "commons.wikimedia.org.", "type": 1}], "Answer": [{"name": "commons.wikimedia.org.", "type": 1, "data": "198.35.26.224"}]}"#.utf8)
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], booleanStatus) }
        await rejected("boolean Status rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        // Integer fields must be exact: a fractional `NSNumber.intValue` truncates,
        // so `Status: 0.5` would masquerade as 0 and `type: 1.5` as 1.
        check(ResidentWebImagePublicDNSResolver.number(NSNumber(value: 0.5)) == nil,
            "fractional Status number is not accepted as an integer")
        check(ResidentWebImagePublicDNSResolver.number(NSNumber(value: 1.5)) == nil,
            "fractional type number is not accepted as an integer")
        check(ResidentWebImagePublicDNSResolver.number(NSNumber(value: -0.25)) == nil,
            "negative fractional number is not accepted as an integer")
        check(ResidentWebImagePublicDNSResolver.number(NSNumber(value: 0.0)) == 0,
            "an integer-valued double Zero is accepted")
        check(ResidentWebImagePublicDNSResolver.number(NSNumber(value: 1.0)) == 1,
            "an integer-valued double One is accepted")
        check(ResidentWebImagePublicDNSResolver.number(NSNumber(value: 3)) == 3,
            "an integer NSNumber is accepted")
        check(ResidentWebImagePublicDNSResolver.number(NSNumber(value: true)) == nil,
            "a boolean is never accepted as an integer")
        check(ResidentWebImagePublicDNSResolver.number(NSNumber(value: Double.infinity)) == nil,
            "a non-finite number is never accepted as an integer")

        let fractionalStatus = Data(#"{"Status": 0.5, "TC": false, "Question": [{"name": "commons.wikimedia.org.", "type": 1}], "Answer": [{"name": "commons.wikimedia.org.", "type": 1, "data": "198.35.26.224"}]}"#.utf8)
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], fractionalStatus) }
        await rejected("fractional Status 0.5 rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        let integralDoubleStatus = Data(#"{"Status": 0.0, "TC": false, "Question": [{"name": "commons.wikimedia.org.", "type": 1}], "Answer": [{"name": "commons.wikimedia.org.", "type": 1, "data": "198.35.26.224"}]}"#.utf8)
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], integralDoubleStatus) }
        check(try await resolver.ipv4Addresses(forHost: queryHost) == [realAddress],
            "an integer-valued double Status 0.0 is accepted")
        let fractionalQuestionType = Data(#"{"Status": 0, "TC": false, "Question": [{"name": "commons.wikimedia.org.", "type": 1.5}], "Answer": [{"name": "commons.wikimedia.org.", "type": 1, "data": "198.35.26.224"}]}"#.utf8)
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], fractionalQuestionType) }
        await rejected("fractional Question type 1.5 rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        let fractionalAnswerType = Data(#"{"Status": 0, "TC": false, "Question": [{"name": "commons.wikimedia.org.", "type": 1}], "Answer": [{"name": "commons.wikimedia.org.", "type": 1.5, "data": "198.35.26.224"}]}"#.utf8)
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], fractionalAnswerType) }
        await rejected("fractional Answer type 1.5 rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }

        // 5. Transport envelope: status, content type and redirect refusal.
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], dohBody(answers: [aRecord(realAddress)])) }
        transport.setHandler { _ in raw(302, ["location": "https://elsewhere.example/resolve", "content-type": "application/json"], dohBody(answers: [aRecord(realAddress)])) }
        transport.resetCalls()
        await rejected("302 redirect rejected", { $0 == .httpStatus(302) }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        check(transport.recordedCalls.count == 1, "a redirect is never followed by a second request")
        transport.setHandler { _ in raw(301, ["location": "https://elsewhere.example/resolve"], Data()) }
        await rejected("301 redirect rejected", { $0 == .httpStatus(301) }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(404, ["content-type": "text/html"], Data()) }
        await rejected("404 status rejected", { $0 == .httpStatus(404) }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(500, [:], Data()) }
        await rejected("500 status rejected", { $0 == .httpStatus(500) }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, [:], dohBody(answers: [aRecord(realAddress)])) }
        await rejected("missing content type rejected", { $0 == .missingContentType }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "text/html; charset=utf-8"], Data("<html></html>".utf8)) }
        await rejected("html content type rejected", { if case .unsupportedContentType = $0 { return true }; return false }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/octet-stream"], dohBody(answers: [aRecord(realAddress)])) }
        await rejected("non-DoH content type rejected", { if case .unsupportedContentType = $0 { return true }; return false }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], Data()) }
        await rejected("empty body rejected", { $0 == .dnsFailure }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in raw(200, ["content-type": "application/json; charset=utf-8"], dohBody(answers: [aRecord(realAddress)])) }
        check(try await resolver.ipv4Addresses(forHost: queryHost) == [realAddress],
            "application/json with parameters is accepted")
        transport.setHandler { _ in raw(200, ["content-type": "Application/DNS-JSON"], dohBody(answers: [aRecord(realAddress)])) }
        check(try await resolver.ipv4Addresses(forHost: queryHost) == [realAddress],
            "application/dns-json is accepted case-insensitively")

        // 6. Bounded body and bounded Answer list.
        let base = dohBody(answers: [aRecord(realAddress)])
        var atCap = base
        atCap.append(Data(repeating: 0x20, count: 64 * 1024 - base.count))
        check(atCap.count == 64 * 1024, "fixture body sits exactly on the cap")
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], atCap) }
        check(try await resolver.ipv4Addresses(forHost: queryHost) == [realAddress],
            "a body exactly at the 64 KiB cap is accepted")
        transport.setHandler { _ in raw(200, ["content-type": "application/json"], atCap + Data([0x20])) }
        await rejected("oversized body rejected", { $0 == .responseTooLarge }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }
        transport.setHandler { _ in
            raw(200, ["content-type": "application/json"], dohBody(answers: Array(repeating: aRecord(realAddress), count: 64)))
        }
        check(try await resolver.ipv4Addresses(forHost: queryHost) == [realAddress],
            "64 Answer entries are accepted")
        transport.setHandler { _ in
            raw(200, ["content-type": "application/json"], dohBody(answers: Array(repeating: aRecord(realAddress), count: 65)))
        }
        await rejected("more than 64 Answer entries rejected", { $0 == .responseTooLarge }) {
            _ = try await resolver.ipv4Addresses(forHost: queryHost)
        }

        // 7. Host validation: only a plain public DNS name is ever queried.
        transport.resetCalls()
        for bad in ["", "   ", "8.8.8.8", "localhost", "router.local", "a..b", ".example.com",
                    "example.com.", "evil.example&type=AAAA", "evil.example?x=1", "user:pass@dns.google",
                    "example.com/path", "https://dns.google"] {
            await rejected("invalid query host \"\(bad)\" rejected", { $0 == .invalidArgument }) {
                _ = try await resolver.ipv4Addresses(forHost: bad)
            }
        }
        check(transport.recordedCalls.isEmpty, "no DNS request is sent for an invalid query host")

        // 8. Cancellation before, during and after the transport call.
        let cancelTransport = ScriptedTransport()
        cancelTransport.setHandler { _ in
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return raw(200, ["content-type": "application/json"], dohBody(answers: [aRecord(realAddress)]))
        }
        let cancelResolver = ResidentWebImagePublicDNSResolver(transport: cancelTransport)
        let cancelledTask = Task { try await cancelResolver.ipv4Addresses(forHost: queryHost) }
        await waitBriefly()
        cancelledTask.cancel()
        await rejectedCancellation("cancelled mid-flight request rejected") {
            _ = try await cancelledTask.value
        }

        let beforeTransport = ScriptedTransport()
        let beforeResolver = ResidentWebImagePublicDNSResolver(transport: beforeTransport)
        let beforeTask = Task { () -> [String] in
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return try await beforeResolver.ipv4Addresses(forHost: queryHost)
        }
        beforeTask.cancel()
        await rejectedCancellation("already cancelled resolution rejected") {
            _ = try await beforeTask.value
        }
        check(beforeTransport.recordedCalls.isEmpty, "an already cancelled resolution never reaches the transport")

        let afterTransport = ScriptedTransport()
        afterTransport.setHandler { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return raw(200, ["content-type": "application/json"], dohBody(answers: [aRecord(realAddress)]))
        }
        let afterResolver = ResidentWebImagePublicDNSResolver(transport: afterTransport)
        await rejectedCancellation("cancellation arriving during the request is observed") {
            _ = try await afterResolver.ipv4Addresses(forHost: queryHost)
        }

        print(failures == 0 ? "PASS: \(checks) resident public DNS checks" : "FAIL: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-public-dns-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Checks.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("checks")

/// Bounded child wait: never `waitUntilExit`, and a watchdog kills and samples a
/// stuck child so one hang cannot wedge the suite or start a second run.
final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    func store(_ status: Int32) { lock.lock(); value = status; lock.unlock() }
    var status: Int32? { lock.lock(); defer { lock.unlock() }; return value }
}

func runBounded(_ process: Process, timeout: TimeInterval) -> (launched: Bool, status: Int32?, timedOut: Bool, pid: Int32) {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ExitBox()
    process.terminationHandler = { finished in box.store(finished.terminationStatus); semaphore.signal() }
    do { try process.run() } catch { return (false, nil, false, -1) }
    let pid = process.processIdentifier
    if semaphore.wait(timeout: .now() + timeout) == .timedOut { return (true, nil, true, pid) }
    return (true, box.status, false, pid)
}

func requireBounded(_ result: (launched: Bool, status: Int32?, timedOut: Bool, pid: Int32),
                    label: String, timeout: TimeInterval) -> Int32 {
    if result.timedOut {
        let samplePath = "/tmp/gmgn-public-dns-test-\(result.pid).sample.txt"
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = ["\(result.pid)", "1", "1", "-file", samplePath]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        _ = runBounded(sample, timeout: 30)
        print("FAIL: \(label) watchdog killed a hung child after \(Int(timeout))s (pid \(result.pid), sample \(samplePath))")
        kill(result.pid, SIGKILL)
        exit(75)
    }
    guard result.launched else { print("FAIL: \(label) failed to launch"); exit(70) }
    guard let status = result.status else { print("FAIL: \(label) exited without an observable status"); exit(76) }
    return status
}

let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
compile.arguments = ["-n", "15", "/usr/bin/swiftc", "-j1", "-parse-as-library",
    generation.path, preparation.path, downloader.path, source.path, program.path, "-o", executable.path]
let compileStatus = requireBounded(runBounded(compile, timeout: 300), label: "compile", timeout: 300)
guard compileStatus == 0 else { exit(compileStatus) }
let test = Process()
test.executableURL = executable
let testStatus = requireBounded(runBounded(test, timeout: 120), label: "resident public DNS checks", timeout: 120)
exit(testStatus)
