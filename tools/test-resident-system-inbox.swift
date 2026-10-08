import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-inbox-store-" + UUID().uuidString)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
var source = #"""
import Foundation
enum WorldAuthorityEndpoint { __ACTUAL_ROOT_RESOLVER__ }
@MainActor enum E2ERuntime { static var applicationSupportBase: URL? }
@main struct Checks {
 @MainActor static func main() async throws {
  let f = try InboxHTTPFixture(); defer { f.cleanup() }; try await f.start()
  E2ERuntime.applicationSupportBase = f.root
  __ACTUAL_APP_CLIENT_FACTORY__
  __ACTUAL_APP_LEGACY_FACTORY__
  try require(WorldAuthorityEndpoint.taskServiceRoot(applicationSupportBase: E2ERuntime.applicationSupportBase).path.hasPrefix(f.root.path + "/"), "actual App factory resolves injected private authority root")
  try require(legacyArchiveURL?.path == f.root.appendingPathComponent("GMGNRadio/ResidentSystemInbox.json").path, "actual App legacy import stays inside private injected base")
  _ = client
  let w = "private-world", s = "private-scope"
  let scope = ResidentSystemInboxScope(worldID: w, residentScope: s)
  let store = ResidentSystemInboxStore(client: f.client())
  await store.restore(worldID: w, residentScope: s)
  func d(_ event: String, _ status: String = "done", _ terminal: Bool = true) -> ResidentSystemDelivery {
   ResidentSystemDelivery(eventID: event, taskID: "task", kind: "wish.test", title: "test", status: status, detail: "", terminal: terminal)
  }
  try require(await store.apply(d("one"), worldID: w, residentScope: s), "fresh durable delivery")
  let original = store.entries(worldID: w, residentScope: s)[0]
  let expiry = store.promptExpiry(taskKey: "task", worldID: w, residentScope: s)!
  try require(store.visibleEntries(worldID: w, residentScope: s, now: expiry.addingTimeInterval(-1)).count == 1, "visible at 29s")
  try require(store.visibleEntries(worldID: w, residentScope: s, now: expiry.addingTimeInterval(1)).isEmpty, "expires after 30s")
  try require(store.unreadCount(worldID: w, residentScope: s) == 1, "expired unread history retained")
  for event in ["one", "copy"] {
   try require(!(await store.apply(d(event), worldID: w, residentScope: s)), "duplicate content unchanged")
   try require(store.entry(taskKey: "task", worldID: w, residentScope: s)!.updatedAt == original.updatedAt, "anchor unchanged")
  }
  try require(await store.markRead(taskKey: "task", worldID: w, residentScope: s), "durable read")
  let readAt = store.entry(taskKey: "task", worldID: w, residentScope: s)!.readAt
  try require(!(await store.markRead(taskKey: "task", worldID: w, residentScope: s)), "already read no-op")
  try require(!(await store.markRead(taskKey: "absent", worldID: w, residentScope: s)), "missing no-op")
  try require(!(await store.apply(d("copy2"), worldID: w, residentScope: s)), "same content keeps read")
  try require(await store.apply(d("one", "projection", false), worldID: w, residentScope: s), "same event presentation change is durably projected")
  let drift = store.entry(taskKey: "task", worldID: w, residentScope: s)!
  try require(drift.isRead && drift.readAt == readAt && drift.updatedAt == original.updatedAt, "projection preserves read and clocks")
  try require(store.visibleEntries(worldID: w, residentScope: s, now: Date.distantFuture).count == 1, "nonterminal does not expire")
  let reopened = ResidentSystemInboxStore(client: f.client())
  await reopened.restore(worldID: w, residentScope: s)
  try require(reopened.entry(taskKey: "task", worldID: w, residentScope: s)!.isRead, "reopen keeps read")
  try require(await store.apply(d("two", "new content"), worldID: w, residentScope: s), "new content unread")
  try require(!(await reopened.markRead(taskKey: "task", worldID: w, residentScope: s, expectedEventID: "one")), "stale event blocked")
  await reopened.restore(worldID: w, residentScope: s)
  try require(reopened.unreadCount(worldID: w, residentScope: s) == 1, "stale read cannot clear unread")
  for other in [ResidentSystemInboxScope(worldID: "other", residentScope: s), ResidentSystemInboxScope(worldID: w, residentScope: "other")] {
   await store.restore(worldID: other.worldID, residentScope: other.residentScope)
   try require(store.entries(worldID: other.worldID, residentScope: other.residentScope).isEmpty, "world/scope isolation")
  }
  let lost = ResidentSystemDelivery(eventID: "lost", taskID: "lost-task", kind: "wish.test", title: "test", status: "saved", detail: "", terminal: true)
  f.loseNextMutationReceipt = true
  try require(!(await store.apply(lost, worldID: w, residentScope: s)), "lost receipt not success")
  try require(store.entry(taskKey: "lost-task", worldID: w, residentScope: s) == nil && store.persistenceError != nil, "no unconfirmed candidate")
  let authority = try await f.client().read(scope: scope)
  let anchor = authority.entries.first { $0.taskKey == "lost-task" }!.updatedAt
  try require(await store.apply(lost, worldID: w, residentScope: s), "explicit identical retry")
  try require(store.entry(taskKey: "lost-task", worldID: w, residentScope: s)!.updatedAt == anchor && store.persistenceError == nil, "retry keeps server anchor")
  let broken = ResidentSystemInboxStore(client: RustInboxClient(call: { _, _ in throw InboxFixtureError.lostReceipt }))
  await broken.restore(worldID: w, residentScope: s)
  try require(broken.persistenceError != nil && broken.entries(worldID: w, residentScope: s).isEmpty, "broken restore injects no state")
  let legacy = ResidentSystemInboxStore(client: f.client(), legacy: { _ in [original] })
  await legacy.restore(worldID: "legacy", residentScope: s)
  try require(legacy.entry(taskKey: "task", worldID: "legacy", residentScope: s)!.updatedAt == original.updatedAt, "legacy preserves anchor")
  let again = ResidentSystemInboxStore(client: f.client(), legacy: { _ in [] })
  await again.restore(worldID: "legacy", residentScope: s)
  try require(again.entries(worldID: "legacy", residentScope: s).count == 1, "one-time import cannot clobber")
  f.stop(); try await f.start()
  let restart = ResidentSystemInboxStore(client: f.client())
  await restart.restore(worldID: w, residentScope: s)
  try require(restart.entries(worldID: w, residentScope: s).count == 2 && restart.unreadCount(worldID: w, residentScope: s) == 2, "actual daemon restart preserves history/unread")
  try require(try f.sqlite("SELECT count(*) FROM resident_states WHERE domain='inbox' AND key='entries';") == "2", "SQLite contains real current and legacy inbox records without empty projections")
  try require(try f.sqlite("SELECT count(*) FROM resident_message_acks;") == "0", "UI read never acknowledges background delivery")
  try require(try f.sqlite("SELECT count(*) FROM inbox_control_requests;") != "0", "SQLite stores actual raw event idempotency")
  print("PASS actual Rust inbox HTTP/SQLite lifecycle, clock, read, isolation, receipt loss and legacy import")
 }
}
"""#
let app = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"), encoding: .utf8)
let factoryStart = app.range(of: "private lazy var residentSystemInboxStore:")!.upperBound
let factoryText = app[factoryStart...]
let clientStart = factoryText.range(of: "let client = RustInboxClient(")!.lowerBound
let clientEnd = factoryText.range(of: "let legacyArchiveURL")!.lowerBound
let actualClientFactory = String(factoryText[clientStart..<clientEnd])
let legacyStart = clientEnd
let legacyEnd = factoryText.range(of: "return ResidentSystemInboxStore(")!.lowerBound
let actualLegacyFactory = String(factoryText[legacyStart..<legacyEnd])
let authority = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/AuthorityWorldStatePersistence.swift"), encoding: .utf8)
let resolverStart = authority.range(of: "static func taskServiceRoot(")!.lowerBound
let resolverTail = authority[resolverStart...]
let resolverEnd = resolverTail.range(of: "\n    }\n")!.upperBound
source = source.replacingOccurrences(of: "__ACTUAL_ROOT_RESOLVER__", with: String(resolverTail[..<resolverEnd]))
    .replacingOccurrences(of: "__ACTUAL_APP_CLIENT_FACTORY__", with: actualClientFactory)
    .replacingOccurrences(of: "__ACTUAL_APP_LEGACY_FACTORY__", with: actualLegacyFactory)
let main = scratch.appendingPathComponent("Main.swift")
try source.write(to: main, atomically: true, encoding: .utf8)
let files = ["apps/macos/Sources/GMGNRadio/Presence/ResidentSystemInbox.swift", "apps/macos/Sources/GMGNRadio/Presence/RustInboxClient.swift", "apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift", "apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift", "tools/privatefixtures/inbox-http-fixture.swift"]
// Negative controls mutate only private source copies. The same real HTTP
// lifecycle must reject a broken confirmed projection or missing read command.
var sourcePaths = files.map { root.appendingPathComponent($0).path }
// Construct the actual App factory without enabling a launch implementation.
// This private transport has no launch code; only its constructor assertion is
// relaxed for the App's production allowsLaunching flag. All calls still hit
// the fixture's explicitly launched daemon and private endpoint.
let helper = try String(contentsOfFile: sourcePaths[4], encoding: .utf8)
let factoryHelper = scratch.appendingPathComponent("FactoryHTTPFixture.swift")
try helper.replacingOccurrences(of: "precondition(!allowsLaunching);", with: "_ = allowsLaunching;")
 .write(to: factoryHelper, atomically: true, encoding: .utf8)
sourcePaths[4] = factoryHelper.path
if let index = CommandLine.arguments.firstIndex(of: "--negative"), index + 1 < CommandLine.arguments.count {
 let kind = CommandLine.arguments[index + 1]
 let original = try String(contentsOfFile: sourcePaths[0], encoding: .utf8)
 let mutated: String
 switch kind {
 case "unread": mutated = original.replacingOccurrences(of: "snapshots[ResidentSystemInboxScope(worldID: worldID, residentScope: residentScope)]?.unreadCount ?? 0", with: "0")
 case "read": mutated = original.replacingOccurrences(of: "let value = try await client.markRead(taskKey: taskKey, expectedEventID: event, scope: scope)", with: "let value = try await client.read(scope: scope)")
 default: fatalError("unknown negative control")
 }
 guard mutated != original else { fatalError("negative control did not alter actual source") }
 let copy = scratch.appendingPathComponent("MutatedStore.swift")
 try mutated.write(to: copy, atomically: true, encoding: .utf8)
 sourcePaths[0] = copy.path
}
let binary = scratch.appendingPathComponent("checks")
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-swift-version", "6", "-parse-as-library"] + sourcePaths + [main.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
if CommandLine.arguments.contains("--compile-only") { print("PASS Swift 6 actual inbox store fixture compile"); exit(0) }
let run = Process(); run.executableURL = binary; try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
