// Real production listener and HTTP client. No app, model, user data or daemon.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-host-http-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let harness = ##"""
import Foundation
import Darwin
@MainActor final class Counter { var count = 0 }
@main struct HostHTTPChecks {
    @MainActor static func main() async throws {
        let schemas = Data("[{\"name\":\"read_state\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}}]".utf8)
        let calls = Counter()
        let channel = try ResidentDSHHostToolsChannel.start(configuration: .init(scope: "test", worldID: "fixture",
            registrations: ResidentDSHHostToolSet.parse(schemasJSON: schemas), handler: { _ in
                calls.count += 1
                return ResidentDSHHostToolReply(resultJSON: Data("{\"ready\":true}".utf8), isError: false)
            }))
        defer { channel.stop() }
        let grant = try JSONSerialization.jsonObject(with: Data(contentsOf: channel.grantFileURL)) as! [String: Any]
        let endpoint = grant["endpoint"] as! [String: Any]
        guard endpoint["version"] as? Int == 2, endpoint["url"] as? String == channel.rpcURL,
              endpoint["address"] == nil else { print("FAIL: HTTP-only v2 grant"); exit(1) }
        var request = URLRequest(url: URL(string: channel.rpcURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(grant["secret"] as! String)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{\"v\":1,\"callId\":\"http-real-client\",\"name\":\"gmgn_read_state\",\"arguments\":{}}".utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any], reply["ok"] as? Bool == true
            else { print("FAIL: genuine HTTP /rpc did not return an authorized tool reply"); exit(1) }
        } catch { print("FAIL: genuine HTTP /rpc connection failed"); exit(1) }
        let baseline = calls.count
        for (status, method, path, contentType, auth) in [
            (403, "POST", "/rpc", "application/json", ""),
            (403, "POST", "/rpc", "application/json", "Bearer wrong"),
            (405, "GET", "/rpc", "application/json", ""),
            (404, "POST", "/other", "application/json", ""),
            (415, "POST", "/rpc", "text/plain", ""),
        ] {
            var invalid = request
            var components = URLComponents(url: invalid.url!, resolvingAgainstBaseURL: false)!
            components.path = path; invalid.url = components.url
            invalid.httpMethod = method; invalid.setValue(contentType, forHTTPHeaderField: "Content-Type")
            invalid.setValue(auth, forHTTPHeaderField: "Authorization")
            if method == "GET" { invalid.httpBody = nil }
            let (_, response) = try await URLSession.shared.data(for: invalid)
            guard (response as? HTTPURLResponse)?.statusCode == status else { print("FAIL: HTTP refusal status \(status)"); exit(1) }
        }
        guard calls.count == baseline else { print("FAIL: refused HTTP requests executed tools"); exit(1) }
        func raw(_ header: String) async -> String {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let fd = socket(AF_INET, SOCK_STREAM, 0)
                    defer { close(fd) }
                    var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
                    address.sin_port = UInt16(URL(string: channel.rpcURL)!.port!).bigEndian
                    let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    } }
                    guard result == 0 else { continuation.resume(returning: ""); return }
                    var timeout = timeval(tv_sec: 2, tv_usec: 0), noSignal: Int32 = 1
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    _ = ResidentDSHHostWire.writeAll(fd, Data(header.utf8))
                    var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
                    while true { let n = read(fd, &bytes, bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                }
            }
        }
        let host = "127.0.0.1:\(URL(string: channel.rpcURL)!.port!)"
        for (status, headers) in [
            (400, "Host: wrong\r\nContent-Type: application/json\r\nContent-Length: 0"),
            (400, "Host: \(host)\r\nContent-Type: application/json\r\nContent-Length: 0\r\nContent-Length: 0"),
            (400, "Host: \(host)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nContent-Length: 0"),
            (413, "Host: \(host)\r\nContent-Type: application/json\r\nContent-Length: 2097153"),
            (400, "Host: \(host)\r\nContent-Type: application/json\r\nOrigin: https://example.invalid\r\nContent-Length: 0"),
        ] {
            let reply = await raw("POST /rpc HTTP/1.1\r\n\(headers)\r\n\r\n")
            guard reply.hasPrefix("HTTP/1.1 \(status) ") else { print("FAIL: malformed HTTP boundary status \(status)"); exit(1) }
        }
        let legacy = await raw("{\"v\":1,\"secret\":\"old\",\"callId\":\"legacy\",\"name\":\"gmgn_read_state\",\"arguments\":{}}\n")
        guard legacy.hasPrefix("HTTP/1.1 400 "), calls.count == baseline else { print("FAIL: legacy NDJSON must never execute"); exit(1) }
        let nodeSource = #"""
        import fs from 'node:fs'; import { pathToFileURL } from 'node:url'
        const plugin = await import(pathToFileURL(process.argv[2]).href)
        let registered
        plugin.apply({get(name) { if(name === 'tools') return {register(definition) {registered=definition}} }})
        const grantPath=process.argv[3], original=fs.readFileSync(grantPath,'utf8'), grant=JSON.parse(original)
        const old={...grant,endpoint:{...grant.endpoint,version:1}}
        fs.writeFileSync(grantPath,JSON.stringify(old))
        let denied=false; try { await registered.execute({}, {callId:'old-grant'}) } catch (_) {denied=true}
        fs.writeFileSync(grantPath,original)
        if(!denied) throw new Error('old transport grant accepted')
        const aborted=new AbortController(); aborted.abort()
        let cancelled=false; try { await registered.execute({}, {callId:'aborted',signal:aborted.signal}) } catch (_) {cancelled=true}
        if(!cancelled) throw new Error('cancelled call executed')
        const value=await registered.execute({}, {callId:'actual-node-plugin'})
        if(value.ok!==true || value.data.ready!==true) throw new Error('actual plugin HTTP result mismatch')
        console.log('PASS: actual DSH plugin process HTTP; old grant and abort rejected')
        """#
        let nodeURL = channel.directoryURL.appendingPathComponent("http-plugin-check.mjs")
        try nodeSource.write(to: nodeURL, atomically: true, encoding: .utf8)
        let exitCode: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["node", nodeURL.path, channel.pluginFileURL.path, channel.grantFileURL.path]
                do { try process.run(); process.waitUntilExit(); continuation.resume(returning: process.terminationStatus) }
                catch { continuation.resume(returning: -1) }
            }
        }
        guard exitCode == 0, calls.count == baseline + 1 else { print("FAIL: actual plugin process or authorization counts"); exit(1) }
        print("PASS: genuine HTTP /rpc production listener and URLSession client")
    }
}
"""##
let main = work.appendingPathComponent("Main.swift"), binary = work.appendingPathComponent("checks")
try harness.write(to: main, atomically: true, encoding: .utf8)
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-swift-version", "6", "-parse-as-library", "-j1",
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift").path,
    main.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)
