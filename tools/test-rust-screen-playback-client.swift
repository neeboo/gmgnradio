import Foundation

/// Private taskd only. Synthetic trusted output receipts; never creates AVPlayer or fetches media.
@main struct ScreenPlaybackAcceptance {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Provide private taskd endpoint JSON") }
        let client = RustScreenPlaybackClient(endpointFile: URL(fileURLWithPath: CommandLine.arguments[1]))
        let first = try await client.begin(worldID: "fixture-world", screenID: "fixture-screen",
            pageURL: "https://youtu.be/aaaaaaaaaaa", isPlaylist: false, requestID: "stable-begin")
        guard let ticket = first.ticket else { fatalError("Begin must return Rust output ticket") }
        let repeated = try await client.begin(worldID: "fixture-world", screenID: "fixture-screen",
            pageURL: "https://youtu.be/aaaaaaaaaaa", isPlaylist: false, requestID: "stable-begin")
        precondition(repeated.duplicate && repeated.ticket?.sessionID == ticket.sessionID)
        _ = try await client.receipt(ticket, status: "playing", isLive: false, requestID: "actual-playing")
        let ended = try await client.receipt(ticket, status: "ended", isLive: false, requestID: "actual-eof")
        precondition(ended.state.status == "stopped" && ended.ticket == nil)
        let duplicate = try await client.receipt(ticket, status: "ended", isLive: false, requestID: "actual-eof")
        precondition(duplicate.duplicate && duplicate.state.generation == ended.state.generation)
        do {
            _ = try await client.receipt(ticket, status: "ended", isLive: false, requestID: "late-eof")
            fatalError("Late EOF must not advance")
        } catch ScreenMediaCacheError.server(let code) { precondition(code == "screen_playback_stale_session") }
        do {
            _ = try await client.receipt(ticket, status: "failed", isLive: false, requestID: "actual-eof")
            fatalError("Changed duplicate must not be accepted")
        } catch ScreenMediaCacheError.server(let code) { precondition(code == "screen_playback_receipt_conflict") }
        print("PASS: private Rust screen authority → Swift ticket, stable begin, EOF once, stale/conflicting receipt")
    }
}
