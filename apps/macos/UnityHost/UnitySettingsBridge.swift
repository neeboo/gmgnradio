import Foundation
import Network
import AppKit

/// Authenticated, loopback-only HTTP contract; no Unix sockets or product host.
final class UnitySettingsBridge: @unchecked Sendable {
    private let listener: NWListener
    private let io = DispatchQueue(label: "ai.gmgn.unity.settings-http")
    private let token = UUID().uuidString + UUID().uuidString
    private let marker: URL
    private let command: @MainActor ([String: Any]) -> Bool
    private let snapshot: @MainActor () -> [String: Any]
    @MainActor private var runningApp: NSRunningApplication?
    @MainActor private var launching = false
    @MainActor private var closed = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(root: URL, command: @escaping @MainActor ([String: Any]) -> Bool,
         snapshot: @escaping @MainActor () -> [String: Any]) throws {
        self.command = command; self.snapshot = snapshot
        marker = root.appendingPathComponent("unity-settings-endpoint.json")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = self.listener.port else { return }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let value: [String: Any] = ["version": 1, "host": "127.0.0.1", "port": Int(port.rawValue), "token": self.token]
                let data = try JSONSerialization.data(withJSONObject: value)
                let temporary = root.appendingPathComponent(".unity-settings-" + UUID().uuidString)
                guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
                if FileManager.default.fileExists(atPath: self.marker.path) {
                    _ = try FileManager.default.replaceItemAt(self.marker, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: self.marker) }
            } catch { NSLog("[UnitySettings] endpoint publication failed") }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections[ObjectIdentifier(connection)] = connection
            connection.start(queue: self.io)
            self.receive(connection, accumulated: Data())
            self.io.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
                guard let connection else { return }; self?.finish(connection)
            }
        }
        listener.start(queue: io)
    }

    @MainActor func open() -> Bool {
        guard !closed else { return false }
        if let runningApp, !runningApp.isTerminated {
            return runningApp.activate()
        }
        guard !launching else { return true }
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        let supplied = ProcessInfo.processInfo.environment["GMGN_UNITY_SETTINGS_APP"]
        let bundle = supplied.map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GMGN Unity Settings.app")
        guard let settingsBundle = Bundle(url: bundle), settingsBundle.bundleIdentifier == "ai.gmgn.unity-sample.settings",
              let executable = settingsBundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        var environment = ProcessInfo.processInfo.environment
        environment["GMGN_UNITY_SETTINGS_ENDPOINT"] = marker.path
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = environment
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        launching = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { [weak self] application, error in
            let pid = application?.processIdentifier
            let failed = error != nil
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.launching = false
                    if let pid {
                        let app = NSRunningApplication(processIdentifier: pid)
                        if self.closed { app?.terminate() } else { self.runningApp = app }
                    }
                    if failed { NSLog("[UnitySettings] external app launch failed") }
                }
            }
        }
        return true
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, error in
            guard let self else { connection.cancel(); return }
            var data = accumulated; if let bytes { data.append(bytes) }
            guard data.count <= 256 * 1024 else { self.respond(connection, status: 413, value: ["accepted": false]); return }
            guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { self.finish(connection) } else { self.receive(connection, accumulated: data) }; return
            }
            let header = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
            let rows = header.components(separatedBy: "\r\n")
            let fields = rows.dropFirst().reduce(into: [String: String]()) { result, row in
                guard let colon = row.firstIndex(of: ":") else { return }
                result[String(row[..<colon]).lowercased()] = row[row.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard fields["authorization"] == "Bearer " + self.token else { self.respond(connection, status: 401, value: ["accepted": false]); return }
            let line = rows.first?.components(separatedBy: " ") ?? []
            guard line.count == 3, fields["transfer-encoding"] == nil else { self.respond(connection, status: 400, value: ["accepted": false]); return }
            let body = data[boundary.upperBound...]
            let length = Int(fields["content-length"] ?? "0") ?? -1
            guard length >= 0, length <= 128 * 1024 else { self.respond(connection, status: 400, value: ["accepted": false]); return }
            if body.count < length {
                if complete || error != nil { self.finish(connection) } else { self.receive(connection, accumulated: data) }; return
            }
            if line[0] == "GET", line[1] == "/snapshot" {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let body = MainActor.assumeIsolated { try? JSONSerialization.data(withJSONObject: self.snapshot()) }
                    self.io.async {
                        guard let body else { self.respond(connection, status: 500, value: ["accepted": false]); return }
                        self.respond(connection, status: 200, body: body)
                    }
                }
            } else if line[0] == "POST", line[1] == "/command",
                      let value = try? JSONSerialization.jsonObject(with: Data(body.prefix(length))) as? [String: Any],
                      let op = value["op"] as? String,
                      op == "stage.player.lyrics" {
                let commandData = Data(body.prefix(length))
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let accepted = MainActor.assumeIsolated {
                        guard let command = try? JSONSerialization.jsonObject(with: commandData) as? [String: Any] else { return false }
                        return self.command(command)
                    }
                    self.io.async { self.respond(connection, status: accepted ? 200 : 422, value: ["accepted": accepted]) }
                }
            } else { self.respond(connection, status: 422, value: ["accepted": false]) }
        }
    }
    private func respond(_ connection: NWConnection, status: Int, value: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: value) else { finish(connection); return }
        respond(connection, status: status, body: body)
    }
    private func respond(_ connection: NWConnection, status: Int, body: Data) {
        var packet = Data("HTTP/1.1 \(status) Result\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8); packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in self?.finish(connection) })
    }
    private func finish(_ connection: NWConnection) { connection.cancel(); connections.removeValue(forKey: ObjectIdentifier(connection)) }
    @MainActor func close() {
        closed = true
        listener.cancel()
        io.async { [self] in for connection in connections.values { connection.cancel() }; connections.removeAll() }
        if let data = try? Data(contentsOf: marker),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["token"] as? String == token {
            try? FileManager.default.removeItem(at: marker)
        }
        // Own only the dedicated settings app instance, never the installed app.
        if let runningApp, !runningApp.isTerminated { runningApp.terminate() }
        runningApp = nil
    }
}
