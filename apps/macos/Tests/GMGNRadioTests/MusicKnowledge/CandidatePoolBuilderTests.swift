import Foundation
import Testing
@testable import GMGNRadio

// The original selector assertions were moved verbatim to the pure Rust rules.
// These cases invoke that actual compiled test binary; no Swift reducer remains.
@Test
func candidatePoolExcludesRecentlySkippedTracks() async throws {
    try await runCandidatePoolParity("music_program_rules::tests::original_candidate_pool_excludes_recently_skipped_tracks")
}

@Test
func candidatePoolUsesFamiliarRediscoveryAndExplorationBuckets() async throws {
    try await runCandidatePoolParity("music_program_rules::tests::original_candidate_pool_uses_familiar_rediscovery_exploration_buckets")
}

@Test
func candidatePoolIsDeterministicAndBackfillsMissingBuckets() async throws {
    try await runCandidatePoolParity("music_program_rules::tests::original_candidate_pool_is_deterministic_and_backfills_missing_buckets")
}

private func runCandidatePoolParity(_ name: String) async throws {
    guard let binary = ProcessInfo.processInfo.environment["GMGN_TASKD_TEST_UNIT_BINARY"],
          FileManager.default.isExecutableFile(atPath: binary) else { throw PropTaskDaemonError.helperMissing }
    let result = try await Task.detached {
        let process = Process(); process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--exact", name, "--nocapture"]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }.value
    #expect(result.0 == 0, Comment(rawValue: result.1))
    #expect(result.1.contains("1 passed"), "The named Rust test must actually execute.")
}
