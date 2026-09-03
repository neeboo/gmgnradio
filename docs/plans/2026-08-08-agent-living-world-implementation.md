# Agent Living World Vertical Slice Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship a deterministic example world in which one persistent AI character can choose an activity, move through an authored space, perform visible motion, react to the user, and remain observable through a desktop portal-style Live Cam.

**Architecture:** Marble/SPZ remains the visual world. A versioned world package authored in Blender supplies the authoritative gameplay proxy: coordinate calibration, collision volumes, waypoint routes, activity anchors, camera anchors, capabilities, and resource hashes. A hostless Swift package owns world contracts and deterministic simulation; the macOS app adapts that state into avatar motion, Agent tools, the existing stage renderer, and one shared render surface that moves between Live Cam and the full-space window.

**Tech Stack:** Swift 6, Swift Package Manager, AppKit, SwiftUI, MetalKit, MetalSplatter/SPZ, VRMMetalKit, MMDSceneKit, nanoem, Blender Python export scripts, JSON world packages, Swift Testing.

---

## Product and engineering boundaries

This plan delivers one official example world and the runtime contracts needed to add more official worlds later.

Included:

- one person and one persistent AI identity;
- one versioned example world;
- a virtual Live Cam into that world;
- world time, location, activity, interruption and completion events;
- authored collision volumes and waypoint navigation;
- walk, turn, sit, gaze, listen-to-music and idle activities;
- Agent tools that inspect and act on the same world state visible in the UI;
- a fallback path when assets, paths, anchors or motions are missing.

Deferred:

- user-generated worlds and world marketplace;
- runtime world generation;
- continuous open-world streaming;
- dynamic rigid-body simulation and destructible props;
- physical computer-camera capture, recording or video upload;
- multiplayer and additional NPCs;
- ARDY as an Apple Silicon runtime dependency;
- reading and drinking until licensed motion and prop assets are available.

Live Cam means a virtual camera rendering the AI's world. It never opens the Mac camera and needs no camera entitlement.

## Release slices

1. **Engineering canary:** use the current public warm-kitchen SPZ with a hand-authored proxy package. Prove package loading, movement, activities, Agent tools and shared rendering.
2. **Official example:** replace the canary with a versioned lakeside-cabin SPZ plus a Blender-authored gameplay proxy. Keep the same manifest and runtime APIs.
3. **Expansion readiness:** install a second internal test world without changing Agent tool names, core enums or runtime dispatch code.

## Implementation status — 2026-08-08

Completed and verified in this working tree:

- Tasks 1-8: hostless world contracts, package validation, Blender export tooling, persistent simulation, waypoint navigation, collision queries, life-activity contracts and execution, automatic Live Cam direction, and render-quality policy;
- Task 10 foundation: the virtual-world-only transparent `LiveCamPanel` and its configuration tests;
- review follow-ups: shared Swift/Python validation rules, self-contained activity definitions in `world.json`, continuous collision checks during movement, streaming resource hashing, and exact 60/30/15 FPS quality tiers with 1.0/0.75/0.5 render scales;
- engineering canary: `apps/macos/Resources/Worlds/warm-kitchen-canary/world.json`.

Fresh verification:

- `WorldRuntime`: 69 tests passed;
- Blender tooling: 15 tests passed;
- canary package validation: passed;
- `LiveCamPanel.swift`: standalone Swift type-check passed;
- no app or Xcode test host was launched.

Still pending: Tasks 9 and 10 controller/render-surface integration, then the serialized macOS application integration in Tasks 11-13. The canary package is a gameplay proxy; its visual SPZ is still resolved through the existing Marble catalog.

## Multi-Agent execution map

Only one integration owner may modify these high-conflict files:

- `apps/macos/project.yml`
- `apps/macos/GMGNRadio.xcodeproj/project.pbxproj`
- `apps/macos/GMGNRadio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`
- `apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift`
- `apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift`
- `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift`

Every worker must preserve existing dirty-worktree changes, avoid generated project files, avoid `xcodegen`, and never run the app or an Xcode test host.

### Wave 1: independent foundations

| Agent | Ownership | Tasks |
|---|---|---|
| World contracts | `Packages/WorldRuntime/**` contracts and tests | 1-2 |
| Blender pipeline | `tools/blender/**`, world fixtures and validation | 3 |
| Camera models | new camera/director policy files and hostless tests | 8 |
| Agent contract | new world tool contract files and tests | 9 |
| Motion contract | new life-activity contracts and tests | 6 |

### Wave 2: depends on world contracts

| Agent | Ownership | Tasks |
|---|---|---|
| Simulation | world state, event stream and persistence | 4 |
| Navigation | authored graph, collision-volume queries | 5 |
| Activity execution | scheduler and activity state machine | 7 |
| Live Cam window | new AppKit panel/controller files | 10 |

### Wave 3: serialized integration

One integration Agent completes Tasks 11-13, runs safe build gates and resolves all shared-file changes.

---

### Task 0: Freeze the dirty-worktree baseline

**Files:**
- Read only: repository-wide
- Create: `docs/plans/evidence/agent-living-world-baseline.md`

**Step 1: Record the exact baseline**

Run:

```bash
git status --short --branch
git diff --stat
git diff --check
```

Expected: `main...origin/main`, existing Marble/MMD changes remain visible, and no unrelated file is removed or reset.

**Step 2: Record safe validation constraints**

Write down that `GMGNRadioTests` uses `TEST_HOST=gmgn radio.app`. Prohibit:

```text
make test
xcodebuild test
xcodebuild test-without-building
```

**Step 3: Validate manifests without launching a host**

Run:

```bash
swift package dump-package --package-path apps/macos/Packages/NanoemCore
swift package dump-package --package-path apps/macos/Packages/MMDSceneKit
plutil -lint apps/macos/GMGNRadio.xcodeproj/project.pbxproj
```

Expected: all commands exit 0.

**Step 4: Commit only the evidence file if the user authorizes commits**

```bash
git add docs/plans/evidence/agent-living-world-baseline.md
git commit -m "docs: record living world implementation baseline"
```

---

### Task 1: Create the hostless WorldRuntime package

**Files:**
- Create: `apps/macos/Packages/WorldRuntime/Package.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldManifest.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldGeometry.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldCapability.swift`
- Test: `apps/macos/Packages/WorldRuntime/Tests/WorldRuntimeTests/WorldManifestTests.swift`

**Step 1: Write the failing manifest decode test**

Cover:

```swift
let manifest = try JSONDecoder().decode(WorldManifest.self, from: fixture)
#expect(manifest.schemaVersion == 1)
#expect(manifest.worldID == "world-labs-example-warm-kitchen")
#expect(manifest.activities.map(\.id).contains("window.gaze"))
#expect(manifest.cameras.map(\.id).contains("living.establishing"))
```

**Step 2: Run the test and verify RED**

```bash
swift test --package-path apps/macos/Packages/WorldRuntime \
  --scratch-path "$(mktemp -d)"
```

Expected: compile failure because `WorldManifest` does not exist.

**Step 3: Implement the minimal public contracts**

The manifest must contain:

```swift
public struct WorldManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let packageID: String
    public let packageVersion: String
    public let worldID: String
    public let displayName: String
    public let calibration: WorldCalibration
    public let spawn: WorldTransform
    public let collisionVolumes: [WorldCollisionVolume]
    public let waypoints: [WorldWaypoint]
    public let routes: [WorldRoute]
    public let activities: [WorldActivityAnchor]
    public let cameras: [WorldCameraAnchor]
    public let capabilities: Set<WorldCapability>
    public let resources: [WorldResource]
}
```

Use stable string IDs. Never encode Swift type names or enum ordinals in a package.

**Step 4: Verify GREEN**

Run the same `swift test` command. Expected: all package tests pass without launching the macOS app.

**Step 5: Commit scoped files**

```bash
git add apps/macos/Packages/WorldRuntime
git commit -m "feat: define living world package contracts"
```

---

### Task 2: Add strict world-package validation

**Files:**
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPackageValidator.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPackageError.swift`
- Test: `apps/macos/Packages/WorldRuntime/Tests/WorldRuntimeTests/WorldPackageValidatorTests.swift`

**Step 1: Write failing validation tests**

Test all of these independently:

- duplicate IDs;
- route references a missing waypoint;
- activity references a missing entry waypoint;
- camera has an invalid near/far plane;
- resource path escapes the package root;
- SHA-256 mismatch;
- unsupported schema version;
- capability declared without a matching activity or camera.

**Step 2: Verify RED**

Run isolated `swift test`. Expected: missing validator types.

**Step 3: Implement deterministic validation**

The validator returns all findings in stable order. It must not silently repair packages.

**Step 4: Verify GREEN and malformed input behavior**

Expected: the valid fixture passes and every malformed fixture fails with a specific error.

**Step 5: Commit**

```bash
git add apps/macos/Packages/WorldRuntime
git commit -m "feat: validate living world packages"
```

---

### Task 3: Build the Blender-to-world-package exporter

**Files:**
- Create: `tools/blender/export_gmgn_world.py`
- Create: `tools/blender/validate_gmgn_world.py`
- Create: `tools/blender/README.md`
- Create: `apps/macos/Resources/Worlds/warm-kitchen-canary/world.json`
- Create: `apps/macos/Resources/Worlds/warm-kitchen-canary/README.md`
- Test: `tools/blender/tests/test_export_gmgn_world.py`

**Step 1: Define Blender collection conventions**

Use these collection names:

```text
GMGN_COLLISION
GMGN_WAYPOINTS
GMGN_ROUTES
GMGN_ACTIVITIES
GMGN_CAMERAS
GMGN_PROPS
```

Custom properties carry stable IDs and semantic data. Example activity marker:

```text
gmgn.id=window.gaze
gmgn.action=gaze
gmgn.entry=wp.window
gmgn.motion=gaze.window
gmgn.interruptible=true
```

**Step 2: Write exporter tests against a mocked Blender scene graph**

Verify stable ordering, coordinate conversion, duplicate detection and content hashes.

**Step 3: Implement export**

Export JSON gameplay data separately from SPZ. Keep one explicit `visualToGameplay` matrix in the manifest.

**Step 4: Create the canary package**

The canary may reference `world-labs-example-warm-kitchen`, but all routes, activities and cameras must be version-controlled locally.

**Step 5: Validate the package**

```bash
python3 tools/blender/validate_gmgn_world.py \
  apps/macos/Resources/Worlds/warm-kitchen-canary
```

Expected: `PASS warm-kitchen-canary@1.0.0`.

**Step 6: Commit**

```bash
git add tools/blender apps/macos/Resources/Worlds/warm-kitchen-canary
git commit -m "feat: export authored living world metadata"
```

---

### Task 4: Implement authoritative world state and events

**Files:**
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldState.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldEvent.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldSimulation.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldStatePersistence.swift`
- Test: `apps/macos/Packages/WorldRuntime/Tests/WorldRuntimeTests/WorldSimulationTests.swift`

**Step 1: Write failing deterministic simulation tests**

Cover:

- load at spawn;
- advance simulated time;
- start, interrupt, resume and complete an activity;
- reject stale revisions;
- emit stable events;
- save and restore state;
- catch up logical time after sleep without replaying every frame.

**Step 2: Implement the state model**

At minimum:

```swift
public struct WorldState: Codable, Equatable, Sendable {
    public var revision: UInt64
    public var worldID: String
    public var worldTime: Date
    public var weather: WorldWeather
    public var agentTransform: WorldTransform
    public var activeActivity: WorldActivityState?
    public var objectStates: [String: WorldObjectState]
}
```

**Step 3: Implement events and persistence**

Use atomic JSON persistence for the vertical slice. Keep persistence behind a protocol so SQLite can replace it later.

**Step 4: Verify GREEN**

Run hostless package tests with a temporary scratch path.

**Step 5: Commit**

```bash
git add apps/macos/Packages/WorldRuntime
git commit -m "feat: add persistent living world simulation"
```

---

### Task 5: Add authored navigation and collision queries

**Files:**
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldNavigation.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WaypointNavigationGraph.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/CollisionVolumeWorld.swift`
- Test: `apps/macos/Packages/WorldRuntime/Tests/WorldRuntimeTests/WorldNavigationTests.swift`

**Step 1: Write failing navigation tests**

Cover shortest valid route, unreachable destination, disabled edge, collision-volume rejection, step height and arrival tolerance.

**Step 2: Define replaceable protocols**

```swift
public protocol WorldNavigationRouting: Sendable {
    func route(from: SIMD3<Float>, to anchorID: String) throws -> WorldPath
}

public protocol WorldCollisionQuerying: Sendable {
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool
    func groundHeight(at position: SIMD3<Float>) -> Float?
}
```

**Step 3: Implement the vertical-slice adapters**

Use Blender-authored waypoint edges and oriented collision boxes. Do not add Recast or Jolt yet.

**Step 4: Leave explicit extension seams**

Future adapters:

- `RecastNavigationRouter` for generated/tiled navmeshes;
- `JoltCollisionWorld` for arbitrary mesh collision and dynamic props.

**Step 5: Verify GREEN and commit**

```bash
git add apps/macos/Packages/WorldRuntime
git commit -m "feat: add authored navigation and collision"
```

---

### Task 6: Define life activities separately from voice overlays

**Files:**
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/LifeActivity.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/ActivityCatalog.swift`
- Test: `apps/macos/Packages/WorldRuntime/Tests/WorldRuntimeTests/ActivityCatalogTests.swift`

**Step 1: Write failing activity-contract tests**

The following activities must decode and validate:

```swift
idle
walk(destinationID:)
turn(targetYaw:)
sit(anchorID:)
gaze(targetID:)
listenMusic(anchorID:)
```

**Step 2: Preserve the existing voice overlay**

`StageAvatarActivity.idle/listening/speaking` remains a facial/voice overlay. Do not reuse it for full-body life activity.

**Step 3: Add phase and fallback contracts**

Every activity has `approach`, `enter`, `loop`, `exit`, `interrupt` and `failed` phases, plus required anchors, motion IDs and props.

**Step 4: Verify GREEN and commit**

```bash
git add apps/macos/Packages/WorldRuntime
git commit -m "feat: define autonomous life activities"
```

---

### Task 7: Implement the deterministic activity scheduler and executor

**Files:**
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/ActivityScheduler.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/ActivityExecutor.swift`
- Test: `apps/macos/Packages/WorldRuntime/Tests/WorldRuntimeTests/ActivityExecutorTests.swift`

**Step 1: Write failing priority tests**

Priority order:

```text
explicit user request
active conversation requirement
scheduled shared activity
music context
autonomous idle activity
safe idle fallback
```

**Step 2: Test the full state machine**

Verify path acquisition, movement ticks, anchor alignment, enter/loop/exit phases, interruption, resumption, cooldown and failure fallback.

**Step 3: Implement without model calls**

The executor is deterministic. Agent judgment selects an outcome; code validates and executes it.

**Step 4: Verify GREEN and commit**

```bash
git add apps/macos/Packages/WorldRuntime
git commit -m "feat: execute living world activities"
```

---

### Task 8: Add camera coordination and the automatic director

**Files:**
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldCameraState.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/LiveCamDirector.swift`
- Create: `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/RenderQualityPolicy.swift`
- Test: `apps/macos/Packages/WorldRuntime/Tests/WorldRuntimeTests/LiveCamDirectorTests.swift`
- Test: `apps/macos/Packages/WorldRuntime/Tests/WorldRuntimeTests/RenderQualityPolicyTests.swift`

**Step 1: Write failing camera tests**

Verify:

- director and user camera states remain independent;
- shot dwell time is 8-15 seconds;
- transitions take 1.2-2 seconds;
- full-space mode pauses director updates;
- occlusion pauses rendering;
- thermal or power pressure lowers 60 -> 30 -> 15 FPS;
- recovery uses hysteresis.

**Step 2: Implement a deterministic shot director**

Inputs: activity phase, agent transform, voice overlay, audio energy, available camera anchors and elapsed time. No model or network call is allowed per frame.

**Step 3: Verify GREEN and commit**

```bash
git add apps/macos/Packages/WorldRuntime
git commit -m "feat: direct living world live camera"
```

---

### Task 9: Define Agent parity tools for the world

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/Agent/WorldAgentToolContract.swift`
- Create: `apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift`
- Create: `apps/macos/Sources/GMGNRadio/Agent/WorldAgentToolDispatcher.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/Agent/WorldAgentToolDispatcherTests.swift`

**Step 1: Write failing contract and dispatch tests**

Tools:

```text
inspect_world
list_places
list_available_activities
plan_route
move_to
start_activity
stop_activity
look_at
set_world_weather
move_live_camera
complete_world_goal
```

**Step 2: Keep tools atomic**

Do not add `live_a_whole_day` or `prepare_and_perform_a_show`. Those are outcomes produced by the Agent composing primitives.

**Step 3: Ensure UI/Agent parity**

Every user-visible world action must have an Agent path. Every Agent mutation must pass through the same `WorldSimulation` observed by the UI.

**Step 4: Make capabilities dynamic**

`list_available_activities` reads the current world manifest. Adding a second world must not require adding a Swift enum case.

**Step 5: Compile through build-for-testing and commit**

Do not run the test host.

---

### Task 10: Add the desktop portal Live Cam window

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamPanel.swift`
- Create: `apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamWindowController.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/StageRenderSurfaceController.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/StageCameraCoordinator.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/DesktopPresence/LiveCamPanelTests.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/VisualEngine/StageCameraCoordinatorTests.swift`

**Step 1: Test panel configuration**

Expected configuration:

```swift
styleMask = [.borderless, .nonactivatingPanel]
isOpaque = false
backgroundColor = .clear
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
```

Use a clipped Metal surface with no title bar. Only the portal aperture accepts pointer input.

**Step 2: Share one render surface**

Live Cam and the full-space window are mutually exclusive owners of one `StageRenderSurfaceController`. Never create two `MarbleSpatialView` instances for the same world.

**Step 3: Implement the transition**

Double-click:

```text
pause director
detach surface from Live Cam
attach surface to StageWindowController
activate user camera
show full space
```

Closing full space performs the reverse operation.

**Step 4: Implement quality policy**

Hidden or occluded Live Cam pauses. Balanced mode uses 30 FPS and 0.75 render scale. Low mode uses 15 FPS and 0.5 render scale.

**Step 5: Compile without launching and commit**

---

### Task 11: Adapt avatar rendering to world movement and temporary activities

**Files:**
- Modify: `apps/macos/Sources/GMGNRadio/Presence/StageAvatarRuntime.swift`
- Create: `apps/macos/Sources/GMGNRadio/Presence/StageAvatarActivityExecutor.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/StageAvatarMotionPlayback.swift`
- Modify: `apps/macos/Sources/GMGNRadio/MMD/StageAvatarAnimationLoader.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/Presence/StageAvatarActivityExecutorTests.swift`

**Step 1: Write failing two-layer state tests**

Full-body activity and voice overlay must coexist. Speaking while sitting changes mouth/face without replacing the sitting activity.

**Step 2: Add runtime activity state**

Long-term selected motion remains in `MotionPackageStore`. Temporary activity motion lives only in the executor and runtime snapshot.

**Step 3: Drive world transform outside animation root motion**

Locomotion clips remain root-locked. The executor advances the character transform along `WorldPath`, preserving deterministic collision and arrival.

**Step 4: Use two-phase motion switching**

Prepare compatible motion and props first, then commit. Failure preserves the current renderer and activity. Reject stale load revisions.

**Step 5: Add licensed motion assets**

Required initial assets:

- walk loop;
- turn left/right;
- sit enter/loop/exit;
- relaxed standing/listening;
- gaze/observe;
- music sway or dance.

Record author, source, version and commercial-use terms in `THIRD_PARTY_NOTICES.md`. Do not ship the current dance file until its restrictions are reviewed.

**Step 6: Compile and commit**

---

### Task 12: Integrate one authoritative world across App, Stage and Agent

**Files:**
- Modify: `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MetalStageView.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/StageRenderer.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/MarbleWorldLibrary.swift`
- Modify: `apps/macos/Sources/GMGNRadio/Agent/DJAgentToolDispatcher.swift`
- Modify: `apps/macos/project.yml`
- Regenerate: `apps/macos/GMGNRadio.xcodeproj/project.pbxproj`

**Step 1: Create shared services**

The application owns exactly one instance of:

```text
WorldPackageLibrary
WorldSimulation
ActivityScheduler
StageAvatarActivityExecutor
StageCameraCoordinator
StageRenderSurfaceController
LiveCamWindowController
```

**Step 2: Replace hard-coded world capability enums**

Keep legacy scene presets only as compatibility aliases. Agent tools and UI read manifest capabilities and IDs.

**Step 3: Connect event flow**

```text
World event -> Agent context refresh
Agent tool -> WorldSimulation mutation
World state -> avatar/camera/UI observers
activity completion -> explicit Agent completion event
```

**Step 4: Regenerate the project once**

Only the integration owner runs:

```bash
cd apps/macos && xcodegen generate
```

Review `project.pbxproj` and `Package.resolved`; reject unrelated churn.

**Step 5: Compile and commit**

---

### Task 13: Build the official lakeside-cabin example world

**Files:**
- Create: `apps/macos/Resources/Worlds/lakeside-cabin-v1/world.json`
- Create: `apps/macos/Resources/Worlds/lakeside-cabin-v1/README.md`
- Create: `apps/macos/Resources/Worlds/lakeside-cabin-v1/resources.sha256`
- Create or download after approval: pinned SPZ and Blender-authored gameplay assets

**Step 1: Author five connected zones**

```text
cabin interior
yard
forest path
lakeside pier
music deck
```

**Step 2: Author the first activity set**

Each activity needs route, entry transform, camera tags, motion requirements, interruption behavior and effects:

```text
sit by fireplace
gaze through rain window
walk forest path
sit on pier
listen to record
perform on music deck
```

**Step 3: Export and validate**

The package must pass hostless validation and resource-hash verification.

**Step 4: Calibrate visual and gameplay spaces**

Acceptance: avatar feet remain within 3 cm of proxy ground, reach activity anchors within 8 cm, and do not intersect authored collision volumes in the scripted tour.

**Step 5: Prove expansion readiness**

Add a second tiny internal fixture world. It must load and expose its capabilities without changing Agent tool names, core runtime enums or dispatch switches.

---

### Task 14: Evaluate ARDY as an offline motion baker

**Implementation update — 2026-08-11:** The text-to-vrma motion-spec path is
now implemented as an optional offline service. The Linux worker produces
versioned VRMA or an in-place, finger-free VMD plus `catalog.json`; the app
downloads only reviewed artifacts through the hostless `MotionDistribution`
package. Raw ARDY `.npz` to neutral motion remains pending CUDA benchmark work.

**Files:**
- Create: `docs/spikes/ardy-motion-baker.md`
- Create only if viable: `tools/motion/ardy_to_gmgn.py`

**Step 1: Keep ARDY off the critical path**

The shipping Apple Silicon app must work without ARDY, CUDA or a remote motion service.

**Step 2: Evaluate on supported infrastructure**

Measure generation latency, foot sliding, path adherence, skeleton mapping and commercial model/data terms for the required activity set.

**Step 3: Export to the neutral motion representation**

Convert joint rotations, root trajectory and foot contacts into a versioned intermediate document, then retarget to VRMA/VMD offline.

**Step 4: Gate adoption**

Adopt only if generated motions meet anchor accuracy and visual quality targets after retargeting. Otherwise continue with licensed authored clips.

---

### Task 15: Safe verification and acceptance

**Files:**
- Create: `docs/plans/evidence/agent-living-world-acceptance.md`

**Step 1: Run package tests**

```bash
swift test --package-path apps/macos/Packages/WorldRuntime \
  --scratch-path "$(mktemp -d)"
```

Expected: all hostless tests pass.

**Step 2: Run static checks**

```bash
git diff --check
plutil -lint apps/macos/Resources/Info.plist
plutil -lint apps/macos/GMGNRadio.xcodeproj/project.pbxproj
python3 tools/blender/validate_gmgn_world.py \
  apps/macos/Resources/Worlds/lakeside-cabin-v1
shasum -a 256 -c \
  apps/macos/Resources/Worlds/lakeside-cabin-v1/resources.sha256
```

**Step 3: Build without launching**

Use unique temporary directories:

```bash
xcodebuild build-for-testing \
  -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$(mktemp -d)" \
  -clonedSourcePackagesDirPath "$(mktemp -d)" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

Expected: `** TEST BUILD SUCCEEDED **`. This compiles tests but does not launch the app or test host.

**Step 4: User-authorized runtime acceptance**

Do not automate this step without explicit authorization. Manual checks:

- Live Cam opens as a desktop portal and remains interactive only inside its aperture;
- only one render surface is active;
- double-click enters the same world and closing returns to the same shot;
- Agent walks to six scripted anchors without crossing collision volumes;
- speaking overlays the current life activity;
- interruption and resumption are visible;
- restart restores world, location and current safe activity;
- occlusion pauses rendering;
- 30-minute run stays above 55 FPS at the 95th percentile in full-space mode;
- twenty scripted end-to-end runs succeed at least eighteen times.

## Stop conditions

- If the canary cannot complete walk -> align -> activity -> interrupt -> resume reliably, pause Live Cam work and fix the simulation contract.
- If adding a second fixture world requires a new Agent tool or core enum case, pause asset work and repair dynamic capability discovery.
- If one render surface cannot safely move between windows, ship Live Cam and full-space as mutually exclusive rebuilds before attempting simultaneous rendering.
- If licensed walk/sit motions cannot be secured, narrow the first visible activity set to gaze, listen, dance and spatial movement, and label the motion limitation explicitly.
- If the official cabin SPZ cannot be pinned with a version and hash, keep the warm-kitchen canary for engineering and do not call it the official example world.

## Agent-native architecture checklist

- **Parity:** UI world actions and Agent tools mutate the same `WorldSimulation`.
- **Granularity:** Agent tools remain atomic; activity outcomes are composed in the Agent loop.
- **Composability:** new activities are manifest data plus motion assets, without new tools.
- **Emergent capability:** Agent can inspect capabilities and combine travel, activity, speech, music and camera actions.
- **Dynamic discovery:** world IDs and activities come from manifests, not hard-coded enums.
- **CRUD completeness:** world state and schedules support inspect, create, update, cancel and reset within product safety boundaries.
- **Shared state:** renderer, UI and Agent observe one authoritative store.
- **Completion signals:** activity completion/failure is explicit and correlated to the initiating tool call.
- **Checkpoint/resume:** world state is persisted after meaningful transitions and restored safely after sleep or restart.
- **No silent actions:** every mutation emits an event immediately visible to UI observers and Agent context.
