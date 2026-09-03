# Marble Spatial Stage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add explorable DJ House and Cosy Wood House Marble stages with WASD/mouse camera control and DJ-controlled scene switching.

**Architecture:** A Marble client lists, generates and downloads complete room worlds into a local cache. A dedicated MetalSplatter-backed view renders the selected SPZ under gmgn's existing music-reactive Metal and lyric layers. A shared spatial-stage store owns camera, scene and weather state and is also the action target for DJ tools.

**Tech Stack:** Swift 6, AppKit, MetalKit, MetalSplatter, SplatIO, URLSession, Swift Testing.

---

### Task 1: Marble world contracts and client

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/SpatialStage/MarbleWorld.swift`
- Create: `apps/macos/Sources/GMGNRadio/SpatialStage/MarbleWorldClient.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/SpatialStage/MarbleWorldClientTests.swift`

1. Write decoding tests for `world_id`, display name, SPZ quality URLs, collider URL and semantics.
2. Run `xcodebuild build-for-testing` and confirm missing-type failures.
3. Implement the response models, quality policy and injected HTTP transport.
4. Re-run build-for-testing and confirm compilation succeeds.

### Task 2: Camera and environment state

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/SpatialStage/SpatialStageStore.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/SpatialStage/SpatialStageStoreTests.swift`

1. Write tests for WASD movement relative to yaw, pitch clamping, reset, room preset and weather state.
2. Verify the tests fail because the state types do not exist.
3. Implement the smallest state model that passes the tests.
4. Re-run build-for-testing.

### Task 3: SPZ download and renderer

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/SpatialStage/MarbleSpatialView.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MetalStageView.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/StageRenderer.swift`
- Modify: `apps/macos/GMGNRadio.xcodeproj/project.pbxproj`

1. Add the MetalSplatter Swift package and target products.
2. Load SPZ through `AutodetectSceneReader`, build `SplatChunk`, and render into a dedicated transparent MTKView.
3. Insert the spatial view below gmgn's existing point-cloud view.
4. Route WASD, Shift, mouse drag and double-click to `SpatialStageStore` while spatial mode is active.
5. Make the original Metal background translucent in spatial mode.
6. Run build-for-testing.

### Task 4: Marble room bootstrap and generation

**Files:**
- Modify: `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`
- Modify: `apps/macos/Sources/GMGNRadio/Settings/GMGNSettingsView.swift`

1. Add a local API-key provider and cache directory.
2. Add DJ House and Cosy Wood House to the stage visual picker with generation state.
3. Reuse an existing preset world by display name; generate a missing room asynchronously.
4. Download 500k, falling back to 100k.
5. Hot-switch the renderer after generation and download finish.

### Task 5: Environment visuals and DJ tools

**Files:**
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/StageUniforms.swift`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/Shaders/Stage.metal`
- Modify: `apps/macos/Sources/GMGNRadio/Agent/DJAgentToolDispatcher.swift`
- Modify: `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/Agent/DJAgentToolDispatcherTests.swift`

1. Add failing capability and dispatch tests for room/weather and camera tools.
2. Keep weather local and remove the two-dimensional fireplace/record-player overlay.
3. Add action methods to the application delegate.
4. Re-run build-for-testing and inspect all errors and warnings.

### Task 6: Safe packaging verification

1. Run `git diff --check` and validate the Xcode project.
2. Build for testing without launching the test host.
3. Archive only with `Developer ID Application: Wei Su (79J6W8QEMD)`.
4. Preserve and hash program/music-library files before and after installation.
5. Verify universal architecture, signature and zip integrity.
6. Leave gmgn radio closed for user validation.
