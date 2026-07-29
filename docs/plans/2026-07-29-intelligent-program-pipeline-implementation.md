# Intelligent Program Pipeline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a complete first-version radio pipeline that knows the user’s playlists, enriches track knowledge, creates a structured DJ show, preflights playback, and drives Metal VFX from each program slot.

**Architecture:** Provider adapters ingest normalized library snapshots into a local index. A retrieval layer creates a bounded candidate pool, Codex returns structured show intent, the deterministic planner validates it, and a rolling playback coordinator preloads the next slot. Each slot carries a semantic visual cue that the existing Metal renderer maps to safe presets while live audio features provide frame-level motion.

**Tech Stack:** Swift 6, SwiftUI, Observation, Foundation networking, MusicKit, AVFoundation, Metal, Swift Testing, XcodeGen.

---

### Task 1: Complete provider library ingestion

**Ownership:** music provider agent only.

**Files:**
- Modify: `apps/macos/Sources/GMGNRadio/MusicSources/NeteaseMusicProviderClient.swift`
- Modify: `apps/macos/Sources/GMGNRadio/MusicSources/QQMusicProviderClient.swift`
- Modify: `apps/macos/Sources/GMGNRadio/MusicSources/AccountMusicSource.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/MusicSources/NeteaseMusicProviderClientTests.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/MusicSources/QQMusicProviderClientTests.swift`

**Steps:**
1. Write failing tests showing NetEase aggregates tracks across playlists and QQ resolves playlist IDs into tracks.
2. Run the provider tests and verify the missing-library behavior fails.
3. Implement bounded playlist detail fetching, provider namespacing, track deduplication, and partial-failure tolerance.
4. Run provider tests and the full macOS test suite.
5. Commit provider-owned files.

### Task 2: Add a local track-knowledge index

**Ownership:** track knowledge agent only.

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/MusicKnowledge/TrackKnowledge.swift`
- Create: `apps/macos/Sources/GMGNRadio/MusicKnowledge/MusicLibraryIndex.swift`
- Create: `apps/macos/Sources/GMGNRadio/MusicKnowledge/CandidatePoolBuilder.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/MusicKnowledge/MusicLibraryIndexTests.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/MusicKnowledge/CandidatePoolBuilderTests.swift`

**Steps:**
1. Write failing tests for normalized ingestion, provider deduplication, skip history, affinity, familiar/rediscovery/discovery buckets, and deterministic candidate limits.
2. Verify the tests fail because the knowledge/index types do not exist.
3. Implement an in-memory first version with a persistence protocol boundary; do not add a database dependency yet.
4. Run knowledge tests and the full suite.
5. Commit knowledge-owned files.

### Task 3: Upgrade Codex output to a structured show proposal

**Ownership:** program planning agent only.

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/DJCore/AgentShowProposal.swift`
- Modify: `apps/macos/Sources/GMGNRadio/DJCore/CodexTrackRankingAgent.swift`
- Modify: `apps/macos/Sources/GMGNRadio/DJCore/AgentProgramPlanner.swift`
- Modify: `apps/macos/Sources/GMGNRadio/DJCore/ProgramPlanner.swift`
- Modify: `apps/macos/Sources/GMGNRadio/Agent/CodexPlanningExecutor.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/DJCore/CodexTrackRankingAgentTests.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/DJCore/AgentProgramPlannerTests.swift`

**Steps:**
1. Write failing tests for program title, direction, ordered slots, selection reasons, host timing, transition intent, and visual mood.
2. Verify the current `track_ids`-only response fails.
3. Add the structured JSON schema and decode it into an agent proposal.
4. Validate all IDs locally and merge safe proposal fields into `ProgramPlan`; retain deterministic fallback behavior.
5. Run planner tests and the full suite.
6. Commit planning-owned files.

### Task 4: Add playback preflight and rolling queue state

**Ownership:** playback agent only.

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/AudioEngine/ProgramPlaybackQueue.swift`
- Create: `apps/macos/Sources/GMGNRadio/AudioEngine/PlaybackPreflight.swift`
- Modify: `apps/macos/Sources/GMGNRadio/AudioEngine/LocalMusicPlayer.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/AudioEngine/ProgramPlaybackQueueTests.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/AudioEngine/PlaybackPreflightTests.swift`

**Steps:**
1. Write failing tests for current/locked/reserve slots, preloading two upcoming tracks, failure replacement, and advancing on completion.
2. Verify failures before adding production types.
3. Implement provider-neutral queue state and preflight protocols without changing `AppDelegate`.
4. Run audio tests and the full suite.
5. Commit playback-owned files.

### Task 5: Map semantic show cues to VFX presets

**Ownership:** visual agent only.

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/ProgramVisualCue.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/ProgramVisualDirector.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/VisualEngine/ProgramVisualDirectorTests.swift`

**Steps:**
1. Write failing tests mapping opener/build/peak/cooldown/closer and semantic moods to stable Metal preset directions.
2. Verify the director type is missing.
3. Implement semantic mapping with clamped intensity and transition duration.
4. Run visual tests and the full suite.
5. Commit visual-owned files.

### Task 6: Integrate the pipeline in the native app

**Ownership:** primary agent only after Tasks 1–5.

**Files:**
- Modify: `apps/macos/Sources/GMGNRadio/MusicSources/MusicRuntime.swift`
- Modify: `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`
- Modify: `apps/macos/Sources/GMGNRadio/DJCore/DJProgramStore.swift`
- Modify: `apps/macos/Sources/GMGNRadio/Settings/AgentSettingsView.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/StageVisualPresetTimeline.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/MusicSources/StreamingMusicCacheTests.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/DJCore/DJProgramStoreTests.swift`

**Steps:**
1. Write failing integration tests for library-to-candidates-to-show, visible show metadata, preflight, queue advance, and VFX cue changes.
2. Verify failures.
3. Wire the new interfaces, keep the settings UI compact, and preserve music-account credential isolation.
4. Run all tests, build the macOS app, restart it, and inspect only the app windows.
5. Commit integration-owned files.

### Task 7: Final verification

**Steps:**
1. Run `xcodegen generate --spec project.yml`.
2. Run `xcodebuild test -project GMGNRadio.xcodeproj -scheme GMGNRadio -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
3. Run `xcodebuild build -project GMGNRadio.xcodeproj -scheme GMGNRadio -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
4. Run `git diff --check` and inspect repository status.
5. Restart the native app, verify Codex state, inspect the program UI, and leave the app running.
