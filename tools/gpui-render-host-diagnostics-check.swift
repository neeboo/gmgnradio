import Foundation
@testable import GPUIRenderHost

// Offline production-DSH policy checks. Every input below is synthetic;
// this never reads credentials, creates a render host or starts an Agent.
let blocked = ["DSH_HOME", "DSH_SNAPSHOT", "DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL",
               "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "NODE_OPTIONS", "UNTRUSTED_OVERRIDE"]
var synthetic = Dictionary(uniqueKeysWithValues: blocked.map { ($0, "synthetic-blocked") })
synthetic["HOME"] = "/synthetic-home"
synthetic["TMPDIR"] = "/synthetic-tmp"
synthetic["PATH"] = "/synthetic-untrusted-path"
let environment = ResidentDSHTransport.residentEnvironment(base: synthetic)
for key in blocked { precondition(environment[key] == nil) }
precondition(environment["HOME"] == synthetic["HOME"])
precondition(environment["TMPDIR"] == synthetic["TMPDIR"])
precondition(environment["PATH"]?.contains("synthetic") == false)
for error in [RenderHostDSHConnectionError.unavailable, .unsupportedBackend, .headlessForbidden] {
    precondition(error.errorDescription?.isEmpty == false)
}
print("PASS: 8 blocked environment overrides; 3 production environment invariants; 3 safe DSH messages; no Agent/request/credential access")
