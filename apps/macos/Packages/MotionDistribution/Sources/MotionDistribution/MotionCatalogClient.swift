import CryptoKit
import Foundation
import OSLog
import Security

public struct MotionHTTPResponse: Sendable {
    public let statusCode: Int
    public let finalURL: URL
    public let data: Data

    public init(statusCode: Int, finalURL: URL, data: Data) {
        self.statusCode = statusCode
        self.finalURL = finalURL
        self.data = data
    }
}

public protocol MotionHTTPTransport: Sendable {
    func get(_ url: URL) async throws -> MotionHTTPResponse
}

public struct URLSessionMotionHTTPTransport: MotionHTTPTransport {
    private let session: URLSession
    private let directPrivateSession: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        self.directPrivateSession = URLSession(
            configuration: configuration,
            delegate: PinnedMotionServiceDelegate(),
            delegateQueue: nil
        )
    }

    public func get(_ url: URL) async throws -> MotionHTTPResponse {
        let selectedSession = MotionRemoteURLPolicy.requiresDirectTransport(url)
            ? directPrivateSession
            : session
        let (data, response) = try await selectedSession.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return MotionHTTPResponse(
            statusCode: response.statusCode,
            finalURL: response.url ?? url,
            data: data
        )
    }
}

public struct MotionCatalogClient: Sendable {
    private let transport: any MotionHTTPTransport

    public init(transport: any MotionHTTPTransport = URLSessionMotionHTTPTransport()) {
        self.transport = transport
    }

    public func fetch(from url: URL) async throws -> MotionCatalog {
        try MotionRemoteURLPolicy.validate(url)
        let response = try await transport.get(url)
        guard response.statusCode == 200 else {
            throw MotionDistributionError.badHTTPStatus(response.statusCode)
        }
        try MotionRemoteURLPolicy.validateRedirect(from: url, to: response.finalURL)
        guard response.data.count <= 2 * 1_024 * 1_024 else {
            throw MotionDistributionError.responseTooLarge
        }
        let catalog = try JSONDecoder().decode(MotionCatalog.self, from: response.data)
        try MotionCatalogValidator.validate(catalog)
        return catalog
    }
}

public struct MotionArtifactCache: Sendable {
    public let rootURL: URL
    private let transport: any MotionHTTPTransport

    public init(
        rootURL: URL,
        transport: any MotionHTTPTransport = URLSessionMotionHTTPTransport()
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.transport = transport
    }

    public func download(
        _ motion: PublishedMotion,
        catalogURL: URL,
        fileManager: FileManager = .default
    ) async throws -> URL {
        try MotionCatalogValidator.validate(
            MotionCatalog(schemaVersion: 1, motions: [motion])
        )
        try MotionRemoteURLPolicy.validate(catalogURL)
        let artifactURL = try artifactURL(for: motion, catalogURL: catalogURL)
        let destination = rootURL
            .appending(path: motion.id, directoryHint: .isDirectory)
            .appending(path: motion.version, directoryHint: .isDirectory)
            .appending(path: "\(motion.id).\(motion.format)")
            .standardizedFileURL
        let rootPrefix = rootURL.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw MotionDistributionError.unsafeArtifactPath(motion.path)
        }

        if fileManager.fileExists(atPath: destination.path),
           let data = try? Data(contentsOf: destination, options: .mappedIfSafe),
           (try? validate(data: data, motion: motion)) != nil {
            return destination
        }

        let response = try await transport.get(artifactURL)
        guard response.statusCode == 200 else {
            throw MotionDistributionError.badHTTPStatus(response.statusCode)
        }
        try MotionRemoteURLPolicy.validateRedirect(from: artifactURL, to: response.finalURL)
        try validate(data: response.data, motion: motion)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try response.data.write(to: destination, options: .atomic)
        return destination
    }

    private func artifactURL(for motion: PublishedMotion, catalogURL: URL) throws -> URL {
        let root = catalogURL.deletingLastPathComponent()
        guard let result = URL(string: motion.path, relativeTo: root)?.absoluteURL else {
            throw MotionDistributionError.unsafeArtifactPath(motion.path)
        }
        try MotionRemoteURLPolicy.validateRedirect(from: catalogURL, to: result)
        return result
    }

    private func validate(data: Data, motion: PublishedMotion) throws {
        guard data.count <= 500 * 1_024 * 1_024 else {
            throw MotionDistributionError.responseTooLarge
        }
        guard data.count == motion.bytes else {
            throw MotionDistributionError.sizeMismatch
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == motion.sha256 else {
            throw MotionDistributionError.hashMismatch
        }
        switch motion.format {
        case "vrma": try validateVRMA(data)
        case "vmd": try validateVMD(data)
        default: throw MotionDistributionError.unsupportedFormat(motion.format)
        }
    }

    private func validateVRMA(_ data: Data) throws {
        guard
            data.count >= 20,
            data.prefix(4) == Data("glTF".utf8),
            littleEndianUInt32(data, 4) == 2,
            littleEndianUInt32(data, 8) == data.count,
            littleEndianUInt32(data, 16) == 0x4E4F534A
        else {
            throw MotionDistributionError.invalidVRMA
        }
        let jsonLength = Int(littleEndianUInt32(data, 12))
        guard
            jsonLength >= 2,
            20 + jsonLength <= data.count,
            let document = try? JSONSerialization.jsonObject(
                with: data.subdata(in: 20 ..< 20 + jsonLength)
            ) as? [String: Any],
            let extensions = document["extensions"] as? [String: Any],
            extensions["VRMC_vrm_animation"] != nil
        else {
            throw MotionDistributionError.invalidVRMA
        }
    }

    private func validateVMD(_ data: Data) throws {
        guard data.count >= 44 else {
            throw MotionDistributionError.invalidVMD
        }
        let header = data.prefix(30)
        guard
            header.starts(with: Data("Vocaloid Motion Data 0002".utf8))
                || header.starts(with: Data("Vocaloid Motion Data file".utf8))
        else {
            throw MotionDistributionError.invalidVMD
        }
    }

    private func littleEndianUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

enum MotionRemoteURLPolicy {
    private static let trustedPrivateHTTPHosts: Set<String> = [
        "192.168.1.85",
        "100.110.226.64",
        "pancat-linux-ci.tail4c7fb9.ts.net",
    ]

    static func requiresDirectTransport(_ url: URL) -> Bool {
        url.host == "192.168.1.85"
    }

    static func requiresPinnedCertificate(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host == "192.168.1.85"
            && effectivePort(url) == 8765
    }

    static func validate(_ url: URL) throws {
        let scheme = url.scheme?.lowercased()
        if scheme == "https" { return }
        let host = url.host?.lowercased()
        guard scheme == "http",
              isLoopback(host) || trustedPrivateHTTPHosts.contains(host ?? "")
        else {
            throw MotionDistributionError.insecureURL
        }
    }

    static func validateRedirect(from source: URL, to destination: URL) throws {
        try validate(destination)
        guard
            source.scheme?.lowercased() == destination.scheme?.lowercased(),
            source.host?.lowercased() == destination.host?.lowercased(),
            effectivePort(source) == effectivePort(destination)
        else {
            throw MotionDistributionError.crossOriginRedirect
        }
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }
}

private final class PinnedMotionServiceDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "ai.gmgn.radio", category: "MotionTLS")

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let certificate = certificates.first
        else {
            logger.error(
                "未取得动作服务证书：host=\(challenge.protectionSpace.host, privacy: .public)，method=\(challenge.protectionSpace.authenticationMethod, privacy: .public)"
            )
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let url = URL(
            string: "https://\(challenge.protectionSpace.host):\(challenge.protectionSpace.port)"
        )!
        guard MotionRemoteURLPolicy.requiresPinnedCertificate(url) else {
            logger.error("拒绝未固定的动作服务证书：url=\(url.absoluteString, privacy: .public)")
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let certificateData = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == MotionServiceConfiguration.pinnedCertificateSHA256 else {
            logger.error("动作服务证书指纹不符：actual=\(digest, privacy: .public)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        logger.info("动作服务证书验证通过：host=\(challenge.protectionSpace.host, privacy: .public)")
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
