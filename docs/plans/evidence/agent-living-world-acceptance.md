# Agent Living World Acceptance Evidence

Updated: 2026-08-19

## Current product boundary

- The engineering world is `warm-kitchen-canary@1.3.0` until an official
  example-world SPZ and its resource hashes are pinned.
- `quiet-corner-fixture@1.0.0` is a non-visual validation package proving that
  activity and camera capabilities are discovered from manifest data.
- Walk, sit, cook, gaze, and listen motions require explicitly approved motion
  assets. Missing semantic clips fall back to the authored rest/natural-idle
  pose; a selected dance is retained only during genuine idle.
- Live Cam and the full stage share one render surface and one world state.
- The private motion catalog provides PMX and VRM BONES-SEED loops for walking,
  chair sitting, cross-legged sitting and kneeling. Raw BONES data is not
  bundled or redistributed.

## Automated evidence

| Check | Result | Evidence |
| --- | --- | --- |
| WorldRuntime hostless suite | PASS | 95 tests passed on 2026-08-19, including the generated Warm Kitchen navigation graph and version-isolated persisted state |
| MotionDistribution hostless suite | PASS | 9 tests passed on 2026-08-12, including the pinned LAN catalog and immutable downloads |
| BONES import and motion factory suite | PASS | 28 tests passed on 2026-08-12 |
| Blender authoring, navigation, publisher and validator suite | PASS | 98 tests passed on 2026-08-19 |
| Warm Kitchen package validation | PASS | `PASS warm-kitchen-canary@1.3.0`; 10 authored blockers, 8 generated waypoints, 16 enabled generated routes, and 3 disabled legacy routes |
| Visible cabinet and furniture collision | PASS (hostless), ready for user recheck | Both cabinet runs, back counter, dining chair/table and calibrated room walls reject the 20 cm capsule. Kitchen-to-dining direct traversal is blocked by the chair; the 2.08 m route uses five generated detour points and every segment is collision-clean. |
| Authoring round trip | PASS | The GLB proxy imports into an editable Blender scene, navigation bakes into a separate scene, and the publisher reproduces the bundled canonical `world.json` byte-for-byte |
| Quiet Corner package validation | PASS | `PASS quiet-corner-fixture@1.0.0` |
| App and test compilation | PASS | `xcodebuild build-for-testing`, code signing disabled, no app/test host launch |
| Signed local production build | PASS | Universal arm64/x86_64 Developer ID bundle installed at `/Applications/gmgn radio.app`; executable SHA-256 `28d43dfe7e324a919c85b92d7b00bac9898c53275e636b3a46868b5a7fcaa7d2`; bundled world SHA-256 `00b10d450f754c03e47175ac142da66f1a44607df66d594a07db231db0e780c3` |
| Property-list validation | PASS | `Info.plist` and `project.pbxproj` |
| Whitespace check | PASS | `git diff --check`; line-ending conversion warnings are informational |

Repeat the safe gate from the repository root:

```bash
GMGN_VERIFY_PACKAGE_CACHE=/tmp/gmgn-living-world-e2e-20260808/packages \
  tools/verify_agent_living_world.sh
```

The script never runs `xcodebuild test`, `test-without-building`, or the app.

## Runtime acceptance

| Scenario | Status | Acceptance |
| --- | --- | --- |
| Live Cam portrait aperture | PASS | 224 x 336, character-local render, no SPZ world draw; visually checked in the debug app |
| Live Cam window movement | PASS | Continuous movement now derives deltas from fixed screen coordinates rather than the moving portal's local coordinate system; an installed-Release drag of `100 x 50` device pixels produced the exact Retina-scaled `+50/-25` AppKit-point origin change. Cross-display movement remains unclamped until release, when edge snapping runs once |
| Live Cam camera orbit | Ready for user drag check | The nonactivating aperture now owns hit testing, accepts the first mouse event, and installs separate right-button (`0x2`) and middle-button (`0x4`) pan recognizers; automated right/middle clicks reach the installed Release without opening a context menu, while sustained non-left dragging still needs a physical-mouse check. Left drag remains reserved for moving the panel |
| Live Cam to full stage | Ready for user recheck | Left double-click transfers the single render surface into Warm Kitchen. Live Cam and full stage now use one explicit 24/60 FPS render loop, avoiding an `MTKView` display link that could remain attached to the previous window and freeze on the first enlarged frame |
| Live Cam model-position handoff | Ready for user recheck | The panel remains transparent until the first character-local GPU frame completes, and the shared explicit render loop is stopped and restarted for each owner handoff. Repeated live -> stage -> live cycles still need visual confirmation on the installed build |
| Cold world loading | PASS | SPZ decode runs asynchronously behind an explicit loading view; no stretched Live Cam frame is exposed before the world is ready |
| PMX camera handoff | PASS | Full-stage camera and PMX model transforms are separate; Live Cam -> stage -> Live Cam -> stage preserves character size |
| Full-stage camera reentry safety | PASS | A saved player camera inside the avatar close-up zone is rejected only on reentry; the installed Release restored Warm Kitchen to `(0, 0.82, 2.05)` with yaw/pitch `0/0`, while safe saved viewpoints remain preserved |
| Full-stage render wake-up | PASS | A visible stage is not paused by a stale AppKit occlusion report; minimization still pauses it |
| Full-stage camera input | PASS | The point-cloud renderer can hide without hiding the transparent world interaction view. The installed Release resolved an injected drag from window locations (`300/120`) even though AppKit reported zero event deltas, changing yaw from `0` to `1.05` and pitch from `0` to `-0.42`; left, right, and middle drags route to world-camera look while WASD remains active |
| Activity motion fallback | PASS | The active gaze activity visibly holds the authored PMX rest pose instead of replaying the selected dance |
| Root-locked dance grounding | PASS | Raw 2B center/groove translations are locked on X/Y/Z, foot-IK tracks remain available, and full-stage placement no longer feeds the previous animated sole offset into the next world transform |
| Temporary PMX and VRM motion | Compiled | Approved activity motion overrides temporarily, then restores selected idle motion |
| Kitchen-to-dining walking | Ready for user visual check | Both routes use the authored waypoint graph; an installed BONES walk loop is selected during the approach phase while world simulation owns collision-safe X/Z movement |
| Restart persistence | PASS | State storage is isolated by package ID and package version, so `1.3.0` cannot reload stale coordinates from the previous collision-free package |
| Collision tour | PASS | All Warm Kitchen activity entries are reachable through the generated graph, and generated nodes and edges have no capsule penetration into blocking volumes |
| Performance soak | Ready for measured run | Full-stage successful frames are sampled for 30 visible minutes; gaps over 250 ms are excluded and the log reports average FPS, p95 frame time, and p95 FPS. Acceptance remains p95 at least 55 FPS |
| Repeated end-to-end run | Pending measured run | At least 18 of 20 scripted runs succeed |

## Known blockers

- The official lakeside-cabin package is not represented here because no
  pinned, versioned SPZ and hash set is present in the repository.
- Approved BONES walk and seated loops are available from the private catalog.
  The sit-down and stand-up clips still need shared-root phase alignment before
  they can be enabled without a visible transition jump. Cooking, gaze and
  listening still use safe fallback motion until approved clips are supplied.
- Hosted XCTest execution launches the application because the current test
  target uses `TEST_HOST`. The safe gate compiles that target but does not run
  it. Pure world simulation assertions run in the hostless WorldRuntime package.
- Cold loading the current high-density SPZ takes about 13 seconds on the
  measured development machine. The wait is asynchronous and subsequent
  entries reuse the in-memory scene; a lower-density preview tier remains a
  future startup optimization.
- The installed local build has a valid Developer ID signature and hardened
  runtime, but it is not notarized. Notarization is still required before
  distributing the same bundle to other Macs without a Gatekeeper warning.
