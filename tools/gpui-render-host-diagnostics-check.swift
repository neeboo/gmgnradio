import Foundation
@testable import GPUIRenderHost

// Offline classifier checks. These are synthetic errors, never raw provider
// diagnostics or credentials. No model request or render-host create occurs.
let examples: [(String, RenderHostConversationFailure)] = [
    ("HTTP 401 unauthorized", .auth),
    ("invalid_api_key", .auth),
    ("model_not_found", .model),
    ("unsupported model", .model),
    ("error sending request: network unreachable", .network),
    ("stream disconnected", .network),
    ("HTTP 429 insufficient_quota", .rate),
    ("error parsing config.toml", .config),
    ("unexpected argument", .config),
    ("opaque failure", .unknown),
    ("", .unknown),
]
for (input, expected) in examples {
    precondition(RenderHostConversationFailure.classify(input) == expected)
}
for category in [RenderHostConversationFailure.auth, .model, .network, .rate, .config, .unknown] {
    let message = category.errorDescription ?? ""
    precondition(!message.isEmpty && !message.contains("登录"))
}
print("PASS: 11 safe failure classifications; 6 fixed user messages; no network/model request")
