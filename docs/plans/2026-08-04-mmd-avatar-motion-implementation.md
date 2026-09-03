# MMD Avatar and Motion Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development and superpowers:test-driven-development task-by-task.

**Goal:** Add VMD motion playback for VRM avatars and PMX + VMD character playback inside the existing Metal SPZ stage, with model/motion library settings.

**Architecture:** Vendor nanoem core as a small C parser for VMD, adapt its output to VRMMetalKit clips, and vendor MMDSceneKit as the PMX Metal-backed renderer. Both avatar backends conform to one runtime contract and encode after the SPZ pass using the same drawable and depth texture.

**Tech Stack:** Swift 6, SwiftUI, AppKit, MetalKit, SceneKit Metal renderer, VRMMetalKit, nanoem core C API, MMDSceneKit.

---

### Task 1: Vendor auditable MMD dependencies

**Files:**
- Create: `apps/macos/Packages/NanoemCore/Package.swift`
- Create: `apps/macos/Packages/NanoemCore/Sources/CNanoem/**`
- Create: `apps/macos/Packages/MMDSceneKit/Package.swift`
- Create: `apps/macos/Packages/MMDSceneKit/Sources/MMDSceneKit/**`
- Create: `apps/macos/Packages/MMDSceneKit/Resources/**`
- Modify: `THIRD_PARTY_NOTICES.md`

1. Add package smoke tests/build probes that import both products.
2. Verify the probes fail before the packages are wired.
3. Vendor nanoem core at a pinned commit and MMDSceneKit at `53f0c043e90f6537e2519f3e7d6061028687b8bd`.
4. Fix unsafe pointer readers in the vendored MMD reader before exposing it.
5. Build each package for arm64 macOS and record license/source revisions.

### Task 2: Define model and motion assets

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/Presence/StageAvatarRuntime.swift`
- Create: `apps/macos/Sources/GMGNRadio/Presence/MotionPackageStore.swift`
- Modify: `apps/macos/Sources/GMGNRadio/Presence/PresenceManifest.swift`
- Modify: `apps/macos/Sources/GMGNRadio/Presence/PresencePackageStore.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/Presence/MotionPackageStoreTests.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/Presence/PresencePackageStoreTests.swift`

1. Write failing tests for VRM/PMX model formats and procedural/VRMA/VMD motion formats.
2. Verify RED with `xcodebuild build-for-testing` and the missing production types.
3. Implement independent model/motion selection and atomic persistence.
4. Add VMD header and VRMA extension validation.
5. Add PMX package validation, resource-root preservation and path traversal rejection.
6. Verify GREEN by compiling all tests without launching the test host.

### Task 3: Parse VMD into a neutral document

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/MMD/VMDMotionDocument.swift`
- Create: `apps/macos/Sources/GMGNRadio/MMD/NanoemVMDLoader.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/MMD/NanoemVMDLoaderTests.swift`
- Test resource: `apps/macos/Tests/GMGNRadioTests/Fixtures/minimal-motion.vmd`

1. Write failing tests for header, Shift-JIS names, bone frames, morph frames, frame-to-seconds conversion and malformed data.
2. Verify RED.
3. Wrap nanoem ownership with deterministic destroy calls.
4. Preserve VMD interpolation control points and ignore camera/light tracks in character mode.
5. Verify GREEN and malformed-input behavior.

### Task 4: Retarget VMD to VRM

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/MMD/VMDHumanoidMap.swift`
- Create: `apps/macos/Sources/GMGNRadio/MMD/VMDToVRMClipAdapter.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/MMD/VMDToVRMClipAdapterTests.swift`

1. Write failing tests for Japanese bone aliases, left/right mapping, quaternion coordinates, 30 FPS timing, morph aliases and disabled root motion.
2. Verify RED.
3. Build `VRMMetalKit.AnimationClip` tracks from the neutral document.
4. Retarget relative to model rest rotations; leave unmapped bones untouched.
5. Verify Arisu, Firefly and Ellen load the converted clip offline.

### Task 5: Share the VRM avatar backend

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/StageAvatarRendering.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/VRMStageAvatarRenderer.swift`
- Modify: `apps/macos/Sources/GMGNRadio/DesktopPresence/VRMAvatarMetalView.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/VisualEngine/SpatialStageStoreTests.swift`

1. Write failing contract tests for motion switching, root-lock, DJ speed and relaxed-arm fallback.
2. Verify RED.
3. Move duplicated VRM load/update/draw logic into the shared backend.
4. Load the selected VRMA/VMD instead of hard-coded `StudioGroove`.
5. Keep the same Metal drawable, command buffer and depth texture in Marble.
6. Verify GREEN and build both desktop and spatial call sites.

### Task 6: Add the PMX Metal-backed avatar backend

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift`
- Create: `apps/macos/Sources/GMGNRadio/DesktopPresence/PMXAvatarMetalView.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift`
- Modify: `apps/macos/Sources/GMGNRadio/DesktopPresence/OrbWindowController.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/MMD/PMXStageAvatarRendererTests.swift`

1. Write failing tests for PMX load errors, VMD attach, camera matrix transfer, pass load actions and root-lock.
2. Verify RED.
3. Load PMX through `MMDSceneSource`, attach VMD animation and configure `SCNRenderer` with the app Metal device.
4. Map Marble view/projection matrices to an `SCNCamera`.
5. Render into the existing pass descriptor after SPZ; retain depth `.load/.store`.
6. Add desktop PMX view using the same backend.
7. Verify GREEN and static resource loading.

### Task 7: Build the character and motion settings

**Files:**
- Modify: `apps/macos/Sources/GMGNRadio/Settings/GMGNSettingsView.swift`
- Modify: `apps/macos/Sources/GMGNRadio/Settings/PresenceSettingsModel.swift`
- Modify: `apps/macos/Sources/GMGNRadio/Settings/PresenceSettingsView.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/Settings/PresenceSettingsModelTests.swift`

1. Write failing tests for independent model/motion selection and compatibility messages.
2. Verify RED.
3. Rename the setting segment to “角色” and title to “角色与动作”.
4. Add model and action sections plus one compact import menu.
5. Keep failed imports visible, preserve the last active combination and expose retry/remove actions.
6. Verify GREEN through model tests and build-for-testing.

### Task 8: Integrate, review and verify

**Files:**
- Modify: `apps/macos/project.yml`
- Regenerate: `apps/macos/GMGNRadio.xcodeproj/project.pbxproj`
- Modify: `apps/macos/GMGNRadio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Modify: `THIRD_PARTY_NOTICES.md`

1. Add local package dependencies and regenerate the project once.
2. Run spec review, code-quality review and license review with separate agents.
3. Fix every blocking finding and re-review.
4. Run `plutil -lint`, `git diff --check`, package builds and `xcodebuild build-for-testing ... CODE_SIGNING_ALLOWED=NO`.
5. Confirm bundled resources by path and SHA-256.
6. Do not launch the app or test host; report runtime visual validation as pending user authorization.
