#!/usr/bin/env python3
"""Run production bridge binding slices and original AVQueuePlayer store in isolation.

No App launch, network, user defaults writes, or authority access. Generated local
MP4 files exercise AVQueuePlayer item/time state, not Unity texture rendering.
"""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = (repo / "apps/macos/UnityHost/UnityScreenVideoBridge.swift").read_text()
host = (repo / "apps/macos/UnityHost/UnityMediaHost.swift").read_text()
ui = (repo / "apps/gpui-ui/src/settings.rs").read_text()
supported = source.split("    static let supportedCommands = ", 1)[1].split("\n", 1)[0]
track = source.split("    struct CurrentTrack {", 1)[1].split("    let videos:", 1)[0]
follow = source.split("    private func followCurrentTrack() {", 1)[1].split("    private func definition", 1)[0]
cases = source.split('        case "video.bind":', 1)[1].split("        default: return false", 1)[0]
playback_cases = source.split('        case "video.play":', 1)[1].split('        case "video.mode":', 1)[0]
snapshot = source.split("    func settingsSnapshot() -> [String: Any] {", 1)[1].split("    static func textureDTO", 1)[0]
assert 'currentTrack: { [weak self]' in host
assert 'let actualTrack = self.player.track' in host
assert 'id = libraryTrack.id' in host and 'id = self.queue[self.queueIndex].url.path' in host
assert 'slot.flatMap { $0.track.id == id ? ProgramVisualDirector().cue(for: $0) : nil }' in host
assert '"video.bind", "video.unbind", "video.bound.play", "video.bound.dismiss": return screenVideo.command(value)' in host
assert 'video["currentTrackID"].as_str()' in ui and '"trackID": track_id' in ui
assert '"video.bound.play","id":prompt_id' in ui

driver = r'''
import Foundation
import AVFoundation
enum ProgramSlotRole { case opener, build, peak, cooldown, closer }
enum StageVisualMood { case pulse, liquid, afterglow }
struct ProgramVisualCue { let role: ProgramSlotRole; let mood: StageVisualMood }
enum StageCompositingProfile { enum video { static let videoOpacity: Float = 0.7 } }
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
}
@MainActor final class Bridge {
    static let supportedCommands = SUPPORTED
    struct CurrentTrack {TRACK
    let videos: StageVideoPlaybackStore
    var actualTrack: CurrentTrack?
    var followedTrackID: String?
    var closed = false, notice = ""
    init(_ defaults: UserDefaults) { videos = StageVideoPlaybackStore(defaults: defaults) }
    func currentTrack() -> CurrentTrack? { actualTrack }
    private func followCurrentTrack() {FOLLOW
    func command(_ value: [String: Any]) -> Bool {
        guard !closed, let op = value["op"] as? String, Self.supportedCommands.contains(op) else { return false }
        followCurrentTrack()
        switch op {
        case "video.play":PLAYBACK_OPS
        case "video.bind":CASES
        default: return false
        }
        return true
    }
    func settingsSnapshot() -> [String: Any] {SNAPSHOT
}
@main enum Test {
    @MainActor static func readyItem(_ bridge: Bridge) async throws -> AVPlayerItem {
        for _ in 0..<300 {
            if let item = bridge.videos.player.currentItem, item.status == .readyToPlay { return item }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("local MP4 did not become ready")
    }
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let first = directory.appendingPathComponent("first.mp4"), second = directory.appendingPathComponent("second.mp4")
        let defaults = MemoryDefaults()
        defaults.values["stage.video.asset-paths"] = [first.path, second.path]
        defaults.values["stage.video.user-enabled"] = true
        let bridge = Bridge(defaults)
        precondition(bridge.videos.player.currentItem == nil, "construction autoplayed")
        switch CommandLine.arguments[2] {
        case "stop-play":
            bridge.videos.select(first.path)
            let original = try await readyItem(bridge)
            let bindings = defaults.dictionary(forKey: "stage.video.track-bindings")
            precondition(bridge.command(["op":"video.stop"]))
            precondition(!bridge.videos.isUserEnabled && bridge.videos.player.currentItem == nil)
            precondition(bridge.videos.selectedAssetID == first.path)
            _ = bridge.settingsSnapshot()
            precondition(bridge.videos.player.currentItem == nil, "snapshot restored a stopped video")
            precondition(bridge.command(["op":"video.play"]))
            precondition(bridge.videos.isUserEnabled && bridge.videos.isActive && bridge.videos.activeAssetID == first.path,
                         "explicit Play did not restart the stopped selected video")
            _ = try await readyItem(bridge)
            precondition(bridge.videos.player.currentItem != nil && bridge.videos.player.currentItem !== original)
            precondition(bridge.videos.player.currentTime().seconds < 0.1, "Stop/Play retained old playback time")
            precondition(NSDictionary(dictionary: defaults.dictionary(forKey: "stage.video.track-bindings") ?? [:])
                == NSDictionary(dictionary: bindings ?? [:]), "Play changed bindings")
            bridge.videos.stop()
            return
        case "pause-resume":
            bridge.videos.select(first.path)
            let original = try await readyItem(bridge)
            precondition(bridge.command(["op":"video.pause"]))
            let sought = await bridge.videos.player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                        toleranceBefore: .zero, toleranceAfter: .zero)
            precondition(sought)
            let pausedTime = bridge.videos.player.currentTime().seconds
            precondition(pausedTime >= 0.4 && bridge.videos.player.rate == 0)
            precondition(bridge.command(["op":"video.play"]))
            precondition(bridge.videos.player.currentItem === original, "Pause/Play rebuilt the item")
            precondition(bridge.videos.player.currentTime().seconds >= pausedTime - 0.02, "Pause/Play rewound video")
            bridge.videos.stop()
            return
        case "invalid-selection":
            bridge.videos.select(first.path)
            bridge.videos.stop()
            try FileManager.default.removeItem(at: first)
            precondition(!bridge.command(["op":"video.play"]), "deleted selected file falsely reported success")
            precondition(!bridge.videos.isUserEnabled && bridge.videos.player.currentItem == nil)
            bridge.videos.remove(first.path); bridge.videos.remove(second.path)
            precondition(!bridge.command(["op":"video.play"]), "absent selection falsely reported success")
            return
        default: break
        }
        precondition(!bridge.command(["op":"video.bind", "id":first.path, "trackID":"song-a"]))
        let cue = ProgramVisualCue(role: .build, mood: .liquid)
        bridge.actualTrack = .init(id: "song-a", title: "Song A", cue: cue)
        precondition(!bridge.command(["op":"video.bind", "id":"missing", "trackID":"song-a"]))
        precondition(!bridge.command(["op":"video.bind", "id":first.path, "trackID":"stale"]))
        precondition(bridge.command(["op":"video.bind", "id":first.path, "trackID":"song-a"]))
        let saved = defaults.dictionary(forKey: "stage.video.track-bindings")!
        precondition(saved["song-a"] as? String == first.path)
        precondition(bridge.settingsSnapshot()["boundAssetID"] as? String == first.path)
        bridge.actualTrack = .init(id: "song-b", title: "Song B", cue: cue)
        _ = bridge.settingsSnapshot()
        precondition(!bridge.command(["op":"video.unbind", "trackID":"song-a"]), "stale click mutated old track")
        precondition(bridge.command(["op":"video.bind", "id":second.path, "trackID":"song-b"]))
        bridge.actualTrack = .init(id: "song-a", title: "Song A", cue: cue)
        _ = bridge.settingsSnapshot()
        precondition(bridge.videos.activeAssetID == first.path && bridge.videos.isActive)
        let originalItem = bridge.videos.player.currentItem
        _ = bridge.settingsSnapshot(); _ = bridge.settingsSnapshot()
        precondition(bridge.videos.player.currentItem === originalItem, "polling restarted player")
        bridge.actualTrack = .init(id: "song-b", title: "Song B", cue: cue)
        _ = bridge.settingsSnapshot()
        precondition(bridge.videos.activeAssetID == second.path)
        bridge.videos.disableByUser()
        bridge.actualTrack = .init(id: "song-a", title: "Song A", cue: cue)
        let pending = bridge.settingsSnapshot()["pendingBoundVideo"] as! [String: String]
        precondition(!bridge.videos.isActive && bridge.videos.player.currentItem == nil)
        precondition(pending["trackID"] == "song-a" && pending["assetID"] == first.path)
        precondition(!bridge.command(["op":"video.bound.play", "id":"stale"]))
        precondition(bridge.command(["op":"video.bound.play", "id":pending["id"]!]))
        precondition(bridge.videos.activeAssetID == first.path && !bridge.videos.isUserEnabled)
        bridge.actualTrack = .init(id: "song-b", title: "Song B", cue: cue)
        let nextPending = bridge.settingsSnapshot()["pendingBoundVideo"] as! [String: String]
        precondition(!bridge.videos.isActive, "temporary opt-in escaped track boundary")
        precondition(!bridge.command(["op":"video.bound.play", "id":pending["id"]!]))
        precondition(bridge.command(["op":"video.bound.dismiss", "id":nextPending["id"]!]))
        precondition(bridge.videos.pendingBoundVideo == nil)
        precondition(bridge.command(["op":"video.unbind", "trackID":"song-b"]))
        precondition(bridge.videos.boundAsset(for: "song-b") == nil)
        let restored = StageVideoPlaybackStore(defaults: defaults)
        precondition(restored.boundAsset(for: "song-a")?.id == first.path)
        precondition(restored.boundAsset(for: "song-b") == nil && restored.player.currentItem == nil)
        bridge.actualTrack = .init(id: "song-a", title: "Song A", cue: cue)
        let unbindPending = bridge.settingsSnapshot()["pendingBoundVideo"] as! [String: String]
        precondition(bridge.command(["op":"video.unbind", "trackID":"song-a"]))
        precondition(bridge.videos.pendingBoundVideo == nil)
        precondition(!bridge.command(["op":"video.bound.play", "id":unbindPending["id"]!]))
        precondition(bridge.command(["op":"video.bind", "id":first.path, "trackID":"song-a"]))
        bridge.videos.apply(cue, trackID: "song-a", trackTitle: "Song A")
        let removedPrompt = bridge.videos.pendingBoundVideo!.id
        bridge.videos.remove(first.path)
        precondition(bridge.videos.boundAsset(for: "song-a") == nil)
        precondition(bridge.settingsSnapshot()["pendingBoundVideo"] is NSNull)
        precondition(!bridge.command(["op":"video.bound.play", "id":removedPrompt]))
        bridge.actualTrack = nil
        precondition(bridge.settingsSnapshot()["currentTrackID"] is NSNull)
        bridge.closed = true
        precondition(!bridge.command(["op":"video.bind", "id":second.path, "trackID":"song-b"]))
        precondition(bridge.settingsSnapshot().isEmpty)
        print("Unity video binding: original store persistence, follow, opt-out and stale commands passed")
    }
}
'''
for key, value in {"SUPPORTED": supported, "TRACK": track, "FOLLOW": follow, "CASES": cases,
                   "PLAYBACK_OPS": playback_cases, "SNAPSHOT": snapshot}.items():
    driver = driver.replace(key, value)
with tempfile.TemporaryDirectory(prefix="gmgn-unity-video-binding-") as temporary:
    root = Path(temporary)
    swift = root / "driver.swift"
    swift.write_text(driver)
    binary = root / "fixture"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(swift),
                    str(repo / "apps/macos/Sources/GMGNRadio/VisualEngine/StageVideoPlayback.swift"),
                    "-o", str(binary)], check=True)
    failed = False
    for scenario in ["stop-play", "pause-resume", "invalid-selection", "bindings"]:
        for name in ["first.mp4", "second.mp4"]:
            subprocess.run(["/opt/homebrew/bin/ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                            "-f", "lavfi", "-i", "color=c=blue:s=64x64:r=24:d=2",
                            "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(root / name)], check=True)
        result = subprocess.run([str(binary), str(root), scenario], capture_output=True, text=True)
        print(f"{scenario}: {'PASS' if result.returncode == 0 else 'FAIL'}", flush=True)
        if result.returncode:
            failed = True
            print(result.stderr.splitlines()[0] if result.stderr else f"exit {result.returncode}", flush=True)
        elif result.stdout:
            print(result.stdout.strip(), flush=True)
    if failed:
        raise SystemExit(1)
