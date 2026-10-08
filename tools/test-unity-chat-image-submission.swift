import Foundation

private func declaration(_ prefix: String, in source: String) -> String {
    guard let start = source.range(of: prefix)?.lowerBound,
          let brace = source[start...].firstIndex(of: "{") else {
        print("FAIL: missing production declaration \(prefix)")
        exit(1)
    }
    var depth = 0
    var cursor = brace
    while cursor < source.endIndex {
        switch source[cursor] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 { return String(source[start...cursor]) }
        default: break
        }
        cursor = source.index(after: cursor)
    }
    print("FAIL: unterminated production declaration \(prefix)")
    exit(1)
}

private func index(_ needle: String, in source: String) -> String.Index {
    guard let result = source.range(of: needle)?.lowerBound else {
        print("FAIL: production image-submit path is missing \(needle)")
        exit(1)
    }
    return result
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let bridgeURL = root.appendingPathComponent("apps/macos/RenderHost/ResidentConversationBridge.swift")
let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)
let legacy = declaration("func send(requestID: UInt64, text: String)", in: bridge)
let submit = declaration("func send(\n        requestID: UInt64,\n        submission: ResidentChatSubmission", in: bridge)

guard legacy.contains("send(requestID: requestID"),
      legacy.contains("ResidentChatSubmission(text:"),
      submit.contains("authorizeImages: (@MainActor (UUID, @escaping @MainActor () -> Bool) async throws -> Void)? = nil"),
      submit.contains("submission.attachments.map(\\.url)"),
      submit.contains("let scope = executionRunID ?? submission.id"),
      submit.contains("if !submission.attachments.isEmpty, let authorizeImages"),
      submit.contains("try await authorizeImages(scope, isCurrent)"),
      submit.contains("imageURLs: imageURLs") else {
    print("FAIL: production image-submit contract changed")
    exit(1)
}

guard submit.contains("actualCompletion?(.success(response))"),
      submit.contains("actualCompletion?(.failure(error))"),
      submit.contains("actualCompletion?(.success(response))\n                guard lease == generation, !Task.isCancelled"),
      index("actualCompletion?(.failure(error))", in: submit) < index("guard lease == generation else", in: submit) else {
    print("FAIL: durable claim must receive actual late provider result before UI-generation filtering")
    exit(1)
}

let validateAt = index("try service.validateImageSupport(imageURLs: imageURLs)", in: submit)
let generationAt = index("generation &+= 1", in: submit)
let authorizeAt = index("try await authorizeImages(scope, isCurrent)", in: submit)
let toolsAt = index("let tools = ResidentWorldToolSession", in: submit)
let taskAt = index("task = Task", in: submit)
guard validateAt < generationAt, generationAt < authorizeAt, authorizeAt < toolsAt, toolsAt < taskAt else {
    print("FAIL: validation, authorization, tool installation and model turn are out of order")
    exit(1)
}
guard index("try await imageAuthorization?()", in: submit) < index("try await turnService.send", in: submit),
      submit.contains("guard isCurrent() else { throw CancellationError() }") else {
    print("FAIL: async durable image authorization must settle and recheck scope before provider send")
    exit(1)
}

struct Attachment: Equatable {
    let id: UUID
    let url: URL
}
struct Submission {
    let id: UUID
    let text: String
    let attachments: [Attachment]
}
enum ProbeError: Error { case invalidImage, unauthorized }

/// Hostless lifecycle probe matching the production gates. Production source
/// markers above make this fail when the real send path stops using the same
/// submission identity, ordering or image URL list.
final class SubmissionProbe {
    var current = true
    var calls: [String] = []
    var recovered = false
    var turnStarted = false
    var installedScope: UUID?
    var forwardedURLs: [URL] = []

    func send(
        _ submission: Submission,
        validate: ([URL]) throws -> Void,
        authorize: ((UUID, () -> Bool) throws -> Void)?
    ) -> Bool {
        let urls = submission.attachments.map(\.url)
        do {
            calls.append("validate")
            try validate(urls)
        } catch {
            calls.append("recover")
            recovered = true
            return false
        }
        let scope = submission.id
        let isCurrent = { [weak self] in self?.current == true }
        if !submission.attachments.isEmpty, let authorize {
            do {
                calls.append("authorize")
                try authorize(scope, isCurrent)
            } catch {
                calls.append("recover")
                recovered = true
                return false
            }
        }
        calls.append("install-tools")
        installedScope = scope
        calls.append("send")
        forwardedURLs = urls
        turnStarted = true
        return true
    }
}

var checks = 0
func check(_ condition: Bool, _ label: String) {
    checks += 1
    guard condition else { print("FAIL: \(label)"); exit(1) }
}

let submissionID = UUID()
let attachment = Attachment(id: UUID(),
    url: FileManager.default.temporaryDirectory.appendingPathComponent("fixture-image.png"))
let submission = Submission(id: submissionID, text: "看看这张图", attachments: [attachment])

let accepted = SubmissionProbe()
var authorizedScope: UUID?
var observedCurrent = false
check(accepted.send(submission, validate: { urls in
    check(urls == [attachment.url], "validation receives only prepared local attachment URLs")
}, authorize: { scope, isCurrent in
    authorizedScope = scope
    observedCurrent = isCurrent()
}), "valid image submission starts a turn")
check(accepted.calls == ["validate", "authorize", "install-tools", "send"],
      "image authorization happens before world tools and model send")
check(authorizedScope == submissionID && accepted.installedScope == submissionID,
      "authorization and tool lease share the immutable submission identity")
check(observedCurrent && accepted.forwardedURLs == [attachment.url],
      "current-world gate and exact image URLs reach the turn")

let textOnly = SubmissionProbe()
var textOnlyAuthorization = 0
check(textOnly.send(.init(id: UUID(), text: "纯文字", attachments: []), validate: { urls in
    check(urls.isEmpty, "text-only validation receives an empty image list")
}, authorize: { _, _ in textOnlyAuthorization += 1 }), "text-only submission still starts")
check(textOnlyAuthorization == 0 && textOnly.calls == ["validate", "install-tools", "send"],
      "text-only turns create no human-image authorization")

let invalid = SubmissionProbe()
check(!invalid.send(submission, validate: { _ in throw ProbeError.invalidImage }, authorize: { _, _ in
    print("FAIL: authorization ran after validation failure"); exit(1)
}), "invalid images fail synchronously")
check(invalid.recovered && !invalid.turnStarted && invalid.calls == ["validate", "recover"],
      "validation failure restores the submission and starts no turn")

let denied = SubmissionProbe()
check(!denied.send(submission, validate: { _ in }, authorize: { _, _ in throw ProbeError.unauthorized }),
      "authorization failure rejects the current submission")
check(denied.recovered && !denied.turnStarted
      && denied.calls == ["validate", "authorize", "recover"],
      "authorization failure installs no tools and starts no model turn")

let stale = SubmissionProbe()
stale.current = false
check(!stale.send(submission, validate: { _ in }, authorize: { _, isCurrent in
    guard isCurrent() else { throw ProbeError.unauthorized }
}), "stale world cannot grant submitted images")
check(stale.recovered && !stale.turnStarted, "stale authorization restores the submission")

print("PASS: \(checks) Unity chat image submission lifecycle checks")
