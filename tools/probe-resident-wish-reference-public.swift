// Explicit, read-only public-network probe. Never starts the app, a model or a wish job.
import Foundation

let offlineJSON = CommandLine.arguments.contains("--offline-json-contract")
guard offlineJSON || CommandLine.arguments.contains("--allow-public-network") else {
    print("Pass --allow-public-network to query Commons and download one public reference image. No generation is submitted.")
    exit(2)
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-reference-public-probe-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("Probe.swift")
let program = #"""
import Foundation
import CryptoKit
import ImageIO
enum PropGenerationError: Error { case invalidInput }
struct FixtureResolver: ResidentWebImageAddressResolving {
    func ipv4Addresses(forHost host: String) async throws -> [String] { ["8.8.8.8"] }
}
struct FixtureTransport: ResidentWebImageTransporting {
    func perform(_ request: ResidentWebImageTransportRequest) async throws -> ResidentWebImageRawResponse {
        .init(statusCode: 200, headers: ["content-type": "application/json; charset=utf-8"], body: Data("{\"query\":{}}".utf8))
    }
}
@main struct Probe {
    static func main() async {
        var stage = "public-search"
        do {
            if ProcessInfo.processInfo.environment["GMGN_PROBE_OFFLINE_JSON"] == "1" {
                let downloader = ResidentWebImageDownloader(resolver: FixtureResolver(), transport: FixtureTransport())
                let response = try await downloader.fetchPublicData(URL(string: "https://example.com/api")!, maximumBytes: 1024)
                guard response.mimeType == "application/json", response.data == Data("{\"query\":{}}".utf8) else {
                    throw NSError(domain: "generic-json-contract", code: 1)
                }
                print("PASS: generic public fetch delivers bounded JSON without image decoding")
                return
            }
            var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
            components.queryItems = [
                .init(name: "action", value: "query"),
                .init(name: "generator", value: "search"),
                .init(name: "gsrnamespace", value: "6"),
                .init(name: "gsrsearch", value: "coffee machine filetype:bitmap"),
                .init(name: "gsrlimit", value: "3"),
                .init(name: "prop", value: "imageinfo"),
                .init(name: "iiprop", value: "url|mime"),
                .init(name: "iiurlwidth", value: "1024"),
                .init(name: "format", value: "json")
            ]
            let downloader = ResidentWebImageDownloader()
            let response = try await downloader.fetchPublicData(components.url!, maximumBytes: 1_048_576)
            guard response.mimeType == "application/json",
                  let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  object["error"] == nil,
                  let query = object["query"] as? [String: Any],
                  let pages = query["pages"] as? [String: [String: Any]] else {
                throw NSError(domain: "public-reference-probe", code: 1)
            }
            let candidates = pages.values.sorted { ($0["title"] as? String ?? "") < ($1["title"] as? String ?? "") }
            guard let page = candidates.first,
                  let info = (page["imageinfo"] as? [[String: Any]])?.first,
                  let link = (info["thumburl"] ?? info["url"]) as? String,
                  let imageURL = URL(string: link) else {
                throw NSError(domain: "public-reference-probe", code: 2)
            }
            stage = "image-download"
            let data = try await downloader.download(imageURL)
            guard !data.isEmpty, data.count <= 8 * 1024 * 1024,
                  let image = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(image) as String? == "public.png" else {
                throw NSError(domain: "public-reference-probe", code: 3)
            }
            print("PASS: public search candidates=\(candidates.count), normalized PNG bytes=\(data.count)")
            print("source: \(imageURL.host ?? "") / \(page["title"] as? String ?? "")")
            print("sha256: \(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())")
            print("No model, user daemon, app, or generation submission was used.")
        } catch {
            print("FAIL: public reference probe [\(stage)]: \(error)")
            exit(1)
        }
    }
}
"""#
try program.write(to: source, atomically: true, encoding: .utf8)
let binary = directory.appendingPathComponent("probe")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", "-swift-version", "6", "-parse-as-library",
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentWebImageDownloader.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentWebImagePublicDNSResolver.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropImagePreparation.swift").path,
    source.path, "-o", binary.path]
try compiler.run()
compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let process = Process()
process.executableURL = binary
var environment = ProcessInfo.processInfo.environment
environment["GMGN_PROBE_OFFLINE_JSON"] = offlineJSON ? "1" : "0"
process.environment = environment
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
