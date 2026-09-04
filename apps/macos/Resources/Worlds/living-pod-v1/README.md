# Living Pod V1（生活舱 01）

`living-pod-v1@1.0.0` is the app's default bundled living world package for the
built-in local space `gmgn-living-pod-v1`. The pod room itself is authored in
code (`LivingPodScene.makeRoomNode()` in the app target) and renders from
SceneKit primitives — no Marble SPZ download is involved. This package holds
the offline gameplay truth in the same 1:1 metre coordinates as that visual
room:

- identity visual-to-gameplay calibration with the shared floor plane at
  `y = 0.12` (the deck slab top);
- spawn point on the open front deck at `(0, 0.12, 1.1)`;
- nine blocking collision volumes: deck floor, left/right/back hull walls, the
  sleep-pod bunk, the workbench console unit, the jukebox, the coffee counter,
  and the port viewport wall;
- eight waypoints (spawn, center, bunk, console, jukebox, coffee, viewport,
  airlock) and seven enabled bidirectional hub routes from `wp.center`, so
  every activity entry is reachable from `wp.spawn`;
- eight activities with authored six-phase `activityDefinitions` and Chinese
  display names: `home.idle`, `home.walk`, `bunk.rest` (sit), `console.inspect`
  (gaze), `music.listen` (listenMusic), `coffee.brew` (interact),
  `viewport.gaze` (gaze), `airlock.inspect` (gaze);
- two camera anchors: `living.establishing` (front deck establishing shot) and
  `hatch.closeup` (rear hatch close-up).

The pod declares no motion `resources`; every `motionID` referenced by an
activity anchor or phase contract is limited to the app's existing approved
motion allow-list (`LivingWorldBootstrap.installedLivingMotionIDs`) plus the
`listen.music` alias resolved from installed motions, so nothing downloads at
runtime.

The warm-kitchen canary package is kept in the same `Worlds` folder as a
shipping reference; it is no longer the application default.

Validate from the repository root:

```bash
python3 tools/blender/validate_gmgn_world.py \
  apps/macos/Resources/Worlds/living-pod-v1
```
