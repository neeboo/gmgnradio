import Foundation
@testable import GPUIRenderHost

// Exercise the compiled sandbox builder without starting an Agent, reading
// managed credentials, or making a network request.
let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-gpui-dsh-sandbox-check-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: scratch) }
let first = try ResidentDSHComposition.makeResidentSandbox(rootDirectory: scratch)
let second = try ResidentDSHComposition.makeResidentSandbox(rootDirectory: scratch)
precondition(first.root != second.root)
precondition(first.root.deletingLastPathComponent().standardizedFileURL == scratch.standardizedFileURL)
precondition(first.workspace.deletingLastPathComponent() == first.root)
precondition(ResidentDSHComposition.validateComposedConfig(first.compositionText))
precondition(first.compositionText.contains("@deepseek-ai/dsh-credentials-local"))
precondition(!first.compositionText.contains("API_KEY"))
let permissions = try FileManager.default.attributesOfItem(atPath: first.root.path)[.posixPermissions] as? NSNumber
precondition(permissions?.intValue == 0o700)
print("PASS: compiled DSH sandbox isolation, unique roots, managed-auth composition, private permissions; no Agent/network")
