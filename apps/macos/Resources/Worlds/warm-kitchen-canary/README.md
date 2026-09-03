# Warm Kitchen Canary

`warm-kitchen-canary@1.3.0` is the engineering world package for the public
Marble world `world-labs-example-warm-kitchen`.

The visual SPZ continues to be resolved by the existing Marble world catalog.
This package deliberately contains only version-controlled gameplay truth:

- explicit visual-to-gameplay calibration;
- ten blocking collision volumes, including calibrated room walls, both
  cabinet runs, the back counter, dining chair and dining table;
- 17 waypoints: 8 generated `wp.auto.*` navigation nodes plus the authored
  spawn, center, chair, dining-table, kitchen-aisle, kitchen-counter, speaker,
  turn and window markers;
- 19 routes: 16 enabled `route.auto.*` auto routes (generated floor-proxy
  edges plus the `route.auto.spawn` link and one `route.auto.anchor.*` link per manual
  waypoint) and the three original manual routes (`route.home-loop`,
  `route.kitchen-dining`, `route.window`), preserved but disabled so runtime
  navigation uses the generated auto graph;
- explicit walk activities for the kitchen counter and dining table;
- idle, walk, turn, sit, window-gaze and listen-to-music activities;
- establishing and close-up camera anchors.

The auto graph alone reaches `wp.spawn` to every activity entry with zero
collision penetration for the 0.2 m / 1.8 m / 0.3 m capsule, and the package
passes the hostless acceptance tour. The tour walks the auto graph through
idle, center walk, turn, chair, speaker and window anchors while checking the
20 cm character capsule against every blocking volume; every meaningful
movement path runs through `wp.auto.*` waypoints, and every segment is
collision-clean. The direct kitchen-to-dining segment crosses the dining-chair
blocker, while the authored route is required to detour around it. Entry
transforms must remain within 8 cm of their waypoints
and feet within 3 cm of proxy ground.

The package is published from the verified authoring round trip by the
repeatable promotion command (see `tools/blender/README.md` for the full
pipeline):

```bash
python3 tools/blender/publish_gmgn_world.py \
  --source authoring/worlds/warm-kitchen-canary/roundtrip/world.json \
  --output apps/macos/Resources/Worlds/warm-kitchen-canary/world.json \
  --package-version 1.3.0 \
  --force
```

Validate from the repository root:

```bash
python3 tools/blender/validate_gmgn_world.py \
  apps/macos/Resources/Worlds/warm-kitchen-canary

swift test --package-path apps/macos/Packages/WorldRuntime \
  --filter warmKitchen
```
