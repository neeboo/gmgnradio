# Quiet Corner Fixture

`quiet-corner-fixture@1.0.0` is a deliberately small second world package.
It has different activity, waypoint, route, and camera identifiers from the
warm-kitchen canary. Its purpose is to prove that the runtime and Agent tool
schemas consume package-authored capabilities without adding another Swift
enum case or hard-coded tool definition.

This fixture has no visual resource. It is validation input, not a selectable
shipping scene.

Validate from the repository root:

```bash
python3 tools/blender/validate_gmgn_world.py \
  apps/macos/Resources/Worlds/quiet-corner-fixture
```
