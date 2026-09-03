# Warm Kitchen Canary — authoring artifacts

Version-controlled gameplay proxy for the public Marble warm-kitchen example.
The Marble catalog exposes no `collider_mesh_url` for this world and on-demand
collider export requires credits, so this directory holds a proxy rebuilt
from the authoritative manifest itself. The bundled canary package
(`apps/macos/Resources/Worlds/warm-kitchen-canary/`) is published from the
verified round trip in this directory (see the workflow below).

## Files

| File | Purpose |
|---|---|
| `warm-kitchen-canary.blend` | Editable reverse-import of `world.json` with the frozen GMGN collection contract |
| `warm-kitchen-canary-proxy.glb` | Standard glTF Binary of the `GMGN_NAV_SOURCE` walkable floor proxy surface only |
| `warm-kitchen-canary.nav.blend` | Navigation bake of the editable blend (spacing 0.5, agent radius 0.2, arrival radius 0.2) |
| `roundtrip/world.json` | Package re-exported from the nav blend, validated by `validate_gmgn_world.py` |
| `README.md` | This file |

Every command below deliberately overwrites a version-controlled artifact,
so each passes `--force`; the importer/baker/exporter refuse to replace an
existing file without it.

## Regenerate from the manifest

```bash
blender --background --factory-startup \
  --python tools/blender/import_gmgn_world.py -- \
  --manifest apps/macos/Resources/Worlds/warm-kitchen-canary/world.json \
  --output authoring/worlds/warm-kitchen-canary/warm-kitchen-canary.blend \
  --glb-output authoring/worlds/warm-kitchen-canary/warm-kitchen-canary-proxy.glb \
  --force
```

## Edit -> bake -> export workflow

1. Open `warm-kitchen-canary.blend`. Move or re-author markers in
   `GMGN_COLLISION`, `GMGN_WAYPOINTS`, `GMGN_ROUTES`, `GMGN_ACTIVITIES`,
   `GMGN_CAMERAS`, `GMGN_PROPS`. Edit the walkable floor quad in
   `GMGN_NAV_SOURCE`. Never edit hidden `GMGN_SOURCE` helpers.
2. Bake a fresh navigation graph into a new file (keeps the previous file as a
   checkpoint):

   ```bash
   blender --background --python tools/blender/bake_gmgn_navigation.py -- \
     --blend authoring/worlds/warm-kitchen-canary/warm-kitchen-canary.blend \
     --output authoring/worlds/warm-kitchen-canary/warm-kitchen-canary.nav.blend \
     --spacing 0.5 --agent-radius 0.2 --arrival-radius 0.2 \
     --force
   ```

3. Export the edited package and validate it:

   ```bash
   blender --background \
     authoring/worlds/warm-kitchen-canary/warm-kitchen-canary.nav.blend \
     --python tools/blender/export_gmgn_world.py -- \
     --force authoring/worlds/warm-kitchen-canary/roundtrip/world.json
   python3 tools/blender/validate_gmgn_world.py \
     authoring/worlds/warm-kitchen-canary/roundtrip
   ```

4. Publish the verified graph into the bundled app package with the new
   package version (re-validates the source and requires auto-only
   reachability from `wp.spawn` to every activity entry):

   ```bash
   python3 tools/blender/publish_gmgn_world.py \
     --source authoring/worlds/warm-kitchen-canary/roundtrip/world.json \
     --output apps/macos/Resources/Worlds/warm-kitchen-canary/world.json \
     --package-version 1.3.0 \
     --force
   ```

The baked round-trip package is deterministic: 8 generated waypoints and 16
auto routes plus the three original manual routes, and it passes hostless
validation unchanged. The floor proxy is pruned by ten authored blockers:
floor, calibrated room walls, both cabinet runs, the back counter, dining
chair and dining table. The auto graph alone — generated edges, spawn link and
anchor links, with the manual routes excluded — still routes from `wp.spawn`
to every activity entry, and every generated node/edge and anchor link is
collision-clean.

The bundled `apps/macos/Resources/Worlds/warm-kitchen-canary/world.json` is
published at `1.3.0` from this round trip: all 16 `route.auto.*` routes stay
enabled, the three original manual routes (`route.home-loop`,
`route.kitchen-dining`, `route.window`) are preserved but disabled, and the
package version is stamped `1.3.0` so the app never reuses persisted state
from the previous collision-free package.
