import Foundation

@main @MainActor struct MusicPlaybackAcceptance {
    struct Track: Codable, Equatable { let id: String; let title: String }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Provide private application-support base") }
        let client = RustMusicPlaybackClient(root: URL(fileURLWithPath: CommandLine.arguments[1]))
        let tracks = [Track(id: "same", title: "First slot"), Track(id: "same", title: "Second slot")]
        let first = try client.begin(queue: tracks, ids: tracks.map(\.id), index: 0, mode: "library")
        precondition(client.state?.queue.isEmpty == true, "Preparation must preserve committed queue")
        try client.commit(first, accepted: true)
        precondition(client.items(mode: "library", as: Track.self) == tracks)
        try client.replaceUpcoming(queue: tracks + [Track(id: "third", title: "Upcoming")], ids: ["same","same","third"])
        precondition(client.state?.sessionID == first.requestID, "Changing upcoming slots must preserve actual device session")
        do {
            _ = try client.navigate(trackID: "same")
            fatalError("An ambiguous repeated track needs an explicit slot")
        } catch WorldAuthorityError.daemon(let code) { precondition(code == "music_playback_ambiguous_track") }
        let second = try client.navigate(slotIndex: 1, trackID: "same")
        precondition(second.index == 1)
        try client.commit(second, accepted: false)
        precondition(client.state?.index == 0)
        let next = try client.navigate(delta: 1)
        try client.commit(next, accepted: true)
        do {
            try client.receipt(status: "completed", sessionID: first.requestID, trackID: first.trackID)
            fatalError("Stale completion must not affect a new selection")
        } catch WorldAuthorityError.daemon(let code) { precondition(code == "music_playback_stale_session") }
        try client.receipt(status: "completed", sessionID: next.requestID, trackID: next.trackID)
        precondition(client.state?.index == 1, "Completion alone must not navigate")
        let local = try client.begin(queue: [Track(id: "local", title: "Local")], ids: ["local"], index: 0, mode: "local")
        try client.commit(local, accepted: true)
        precondition(client.items(mode: "library", as: Track.self).isEmpty)
        precondition(client.items(mode: "local", as: Track.self).first?.id == "local")
        print("PASS: real Rust queue -> Swift projection, duplicate slots, failed preparation, stale receipt, local/library authority")
    }
}
