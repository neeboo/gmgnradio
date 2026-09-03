# GMGN Blender world pipeline

This directory compiles GLB collider meshes into editable GMGN world files,
bakes a lightweight waypoint/route navigation layer, and exports deterministic
gameplay metadata from Blender.

Five roles:

- `import_gmgn_glb.py` imports a binary glTF (GLB) mesh into a fresh editable
  `.blend` with the frozen GMGN collection contract and calibration metadata.
- `import_gmgn_world.py` reverse-imports an already-exported `world.json`
  manifest back into a fresh editable `.blend`, rebuilding every collision,
  waypoint, route, activity (with all six phases), camera and proxy surface.
- `bake_gmgn_navigation.py` bakes a sparse, deterministic waypoint/route graph
  from the editable `GMGN_NAV_SOURCE` geometry into `GMGN_WAYPOINTS` and
  `GMGN_ROUTES` without touching manual markers.
- `export_gmgn_world.py` exports authored gameplay metadata from that `.blend`
  to the `world.json` package consumed by `WorldRuntime`.
- `publish_gmgn_world.py` promotes a verified round-trip package into a bundled
  `world.json` for the macOS app: it re-validates the source, requires a
  semantic package version, proves the auto navigation graph alone reaches
  every activity entry from spawn, stamps the new version, and switches the
  package to auto navigation by preserving but disabling the manual routes.

The SPZ visual remains a separate asset: Marble/SPZ is the visual world, while
the collider GLB is the gameplay/navigation authoring input and `world.json` is
the authoritative proxy for coordinates, collision volumes, navigation markers,
activities, cameras and resource hashes.

## GLB sources

The import command accepts any binary glTF 2.0 file. The two supported sources
differ only in their coordinate convention (see `--source-coordinates`):

1. **Marble Collider Mesh download** — the Marble world catalog exposes a
   collider mesh download (binary glTF) for each world. It uses World Labs
   OpenCV-style coordinates, so import it with
   `--source-coordinates world-labs-opencv` (the default). The importer applies
   the documented OpenCV-to-OpenGL correction: rotation about X by `pi`, a
   uniform metric scale, and a Z translation of
   `-ground_plane_offset * metric_scale` so the source ground plane lands on
   `z = 0` in Blender.
2. **Blender glTF Binary export** — any GLB exported from Blender's
   `File > Export > glTF 2.0` (`.glb`). It is already right-handed Z-up, so
   import it with `--source-coordinates gltf`. Standard glTF receives no extra
   axis rotation; the metric scale and ground-plane translation still apply.

## No-paid-collider fallback: reverse import from the manifest

The public Marble example (including the warm-kitchen canary) has no
`collider_mesh_url` in the world catalog, and on-demand collider export
requires credits. To keep a version-controlled gameplay proxy without changing
the app, `import_gmgn_world.py` rebuilds the editable `.blend` from the
authoritative `world.json` package itself. The manifest already contains every
coordinate, collision volume, marker, activity phase and camera anchor that
`WorldRuntime` consumes, so the reverse import is lossless through the existing
exporter contract and needs no Marble download.

`import_gmgn_world.py` turns the gameplay Y-up manifest into Blender Z-up as
the exact inverse of `export_gmgn_world.py`:

- gameplay position `(x, y, z)` becomes Blender `(x, -z, y)`;
- gameplay scale `(sx, sy, sz)` becomes Blender `(sx, sz, sy)`;
- a gameplay quaternion restores the exporter yaw/pitch pair with
  `yaw = 2 * atan2(q.y, q.w)` and `pitch = 2 * atan2(q.x, q.w)`, so a re-export
  reproduces the original transform within float tolerance. The original
  quaternion is also stored on the marker (`gmgn.source_quaternion` plus the
  restored yaw/pitch), and the exporter reuses it verbatim while those values
  are unedited — so quaternions carrying roll round-trip exactly, not just
  within the yaw/pitch tolerance.

The importer validates schemaVersion 1 and the required package/world/display/
spawn keys and arrays before importing, rejects malformed or non-finite values
and duplicate IDs, and verifies that routes, activities and definitions
reference existing waypoints. The core parsing and coordinate conversion run in
plain Python (no `bpy` import), so they are covered by ordinary unit tests.

## Reverse import

Run the importer inside headless Blender 5.2. Arguments go after `--` so
Blender leaves them untouched. The command below regenerates the version-
controlled warm-kitchen canary artifacts in place, so it passes `--force`:

```bash
blender --background --factory-startup \
  --python tools/blender/import_gmgn_world.py -- \
  --manifest apps/macos/Resources/Worlds/warm-kitchen-canary/world.json \
  --output authoring/worlds/warm-kitchen-canary/warm-kitchen-canary.blend \
  --glb-output authoring/worlds/warm-kitchen-canary/warm-kitchen-canary-proxy.glb \
  --force
```

`--output` is the editable `.blend`. `--glb-output` optionally exports only the
editable `GMGN_NAV_SOURCE` proxy surfaces as a standard glTF Binary, which is
how the version-controlled gameplay proxy GLB is produced. Existing `.blend`
and `.glb` files are never overwritten unless `--force` is passed; `--force`
replaces the entire `.blend`, so authored markers are not preserved by
re-running against the same output.

The importer recreates the full GMGN contract:

| Collection | Recreated content |
|---|---|
| `GMGN_SOURCE` | Hidden helper geometry: the source box of every authored floor volume |
| `GMGN_NAV_SOURCE` | Editable walkable proxy quad per floor collision volume (id containing `floor`), with its top surface at gameplay ground |
| `GMGN_COLLISION` | Oriented box collision volumes from `collisionVolumes` |
| `GMGN_WAYPOINTS` | All navigation points plus exactly one `gmgn.spawn=true` marker restored from the manifest `spawn` transform |
| `GMGN_ROUTES` | Ordered waypoint paths with their stable ids |
| `GMGN_ACTIVITIES` | Activity anchors with `gmgn.action`, `gmgn.entry`, transforms and all six phase properties (`approach`/`enter`/`loop`/`exit`/`interrupt`/`failed`) |
| `GMGN_CAMERAS` | Camera anchors with fov/near/far and restored pitch |
| `GMGN_PROPS` | Package-local resource records |

Only floor volumes become walkable proxy surfaces; countertops and other
obstacles stay in `GMGN_COLLISION` and are never inferred as floors. The proxy
surfaces are the same data the navigation baker reads, so the
reverse-import -> edit -> bake -> export loop is fully self-contained.

## Import

```bash
blender --background --factory-startup \
  --python tools/blender/import_gmgn_glb.py -- \
  --input path/to/collider.glb \
  --output path/to/editable.blend \
  --package-id warm-kitchen-edit \
  --world-id world-labs-example-warm-kitchen \
  --display-name "Warm Kitchen Edit" \
  --source-coordinates world-labs-opencv \
  --metric-scale 1.75 \
  --ground-plane-offset 0.4
```

`--source-coordinates` is `world-labs-opencv` by default; pass `gltf` for
Blender-exported GLB files. `--metric-scale` converts one source unit into
meters, and `--ground-plane-offset` is the source-space distance from the scan
origin to the ground plane. The calibrated world is metric, so
`gmgn.meters_per_unit` is set to `1.0` on the scene.

The import always builds a **fresh scaffold** from Blender factory settings:
it creates all eight collections and the `wp.spawn` marker from scratch. If
`--output` already exists the run is refused unless you pass `--force`, and
`--force` **replaces the entire `.blend`** — it does not merge into the old
file. Authored markers are therefore *not* preserved by re-running against the
same output. To refresh source data (a new Marble collider download or a new
Blender export), write to a **new `.blend`** and compare or migrate your
authored markers deliberately; never rely on re-running the import to keep
them.

### Collections

The importer creates exactly these top-level collections in a fresh file:

| Collection | Purpose |
|---|---|
| `GMGN_SOURCE` | Raw imported GLB geometry; hidden and read-only. Never edit here. |
| `GMGN_NAV_SOURCE` | Editable mesh copy, calibrated to Blender meters. Author here. |
| `GMGN_COLLISION` | Oriented box collision volumes; object dimensions define the box |
| `GMGN_WAYPOINTS` | Navigation points and the single `wp.spawn` marker |
| `GMGN_ROUTES` | Ordered waypoint paths |
| `GMGN_ACTIVITIES` | Activity anchors |
| `GMGN_CAMERAS` | Authored camera anchors |
| `GMGN_PROPS` | Package-local files referenced by activities |

`wp.spawn` (with `gmgn.spawn=true`) is created at the calibrated origin, which
sits on the ground plane (`z = 0`). Imported geometry lives in the hidden,
read-only `GMGN_SOURCE`; `GMGN_NAV_SOURCE` holds one editable calibrated mesh
copy per imported object, so source data is never destroyed. Editable copies are
unparented (`parent=None`), visible and fully unlocked; each calibrated world
transform is baked into the copy's own mesh/data, so editing never depends on
the hidden `GMGN_SOURCE` hierarchy.

### Non-destructive editing workflow

1. Import the collider GLB with the command above to produce the editable
   `.blend`.
2. Open the `.blend` and edit the mesh copy in `GMGN_NAV_SOURCE` (retopology,
   simplification or collision-authoring helpers).
3. Add markers to `GMGN_COLLISION`, `GMGN_WAYPOINTS`, `GMGN_ROUTES`,
   `GMGN_ACTIVITIES`, `GMGN_CAMERAS` and `GMGN_PROPS` as documented below.
   Never move or delete objects in `GMGN_SOURCE`; a fresh import into a new
   `.blend` restores the raw mesh.
4. Refresh source data by importing into a **new** `.blend` (e.g.
   `warm-kitchen-edit-2.blend`) whenever the Marble collider mesh or Blender
   export changes. Re-running against the same output requires `--force` and
   replaces the whole `.blend`, so it does *not* preserve authored markers;
   compare the fresh scaffold with your authored file and migrate markers
   deliberately.

## Navigation bake

`bake_gmgn_navigation.py` turns the editable `GMGN_NAV_SOURCE` geometry into a
sparse waypoint/route graph that exports through the existing `world.json`
contract. It is the **current lightweight offline path layer**: one waypoint
per connected walkable fragment in each occupied grid cell (cell size =
`--spacing`). Generated surface edges follow shared walkable geometry, so turns
and one-triangle corridors survive while dense input meshes never produce dense
graphs. A Recast runtime adapter is a later slice and will replace this baked
graph without changing the exported contract.

The baker only reads **visible** world-space mesh geometry from
`GMGN_NAV_SOURCE`, so hide objects you do not want baked. Faces steeper than
`--max-slope-degrees` from horizontal are not walkable (default 45). Non-finite
and degenerate triangles are rejected with an error.

Obstacles come from `GMGN_COLLISION`: only objects whose `gmgn.blocking` is
exactly `true` are read, using their evaluated world transform (center),
dimensions (box half extents) and rotation (yaw around Z). Every generated
waypoint whose center lies inside an active blocker's footprint expanded by
`--agent-radius` is removed, and every generated edge whose segment crosses
such a footprint is removed too. A blocker is **active** for a waypoint or
segment when it overlaps the agent capsule's vertical interval
(`[ground + radius, ground + height - radius]`) and rises more than
`--maximum-step-height` above the ground it stands on — floor slabs and low
risers never erase the walkable floor. Generated nodes and edges never pierce
authored collision volumes, and `find_graph_obstacle_penetrations` in the baker
module exposes the same check for package acceptance.

Every manual `GMGN_WAYPOINTS` marker — the importer-owned `wp.spawn`, activity
entry points and any author-added waypoint — is then linked to the nearest
surviving generated node when one is within `max(2 * --spacing,
2 * --agent-radius, 1.0)` meters and the straight segment does not cross an
active blocker. The spawn keeps its stable `route.auto.spawn` id; every other
manual marker gets a deterministic `route.auto.anchor.<manual id>` link, so
the auto graph alone (generated edges + spawn link + anchor links, with the
original manual routes excluded) can route from spawn to every activity entry.
Ineligible waypoints (too far or behind a blocker) are left unlinked but are
never deleted. After pruning and linking, generated nodes that participate in
no auto edge and are not linked to a manual anchor are dropped as orphans, so
the exported graph contains no dead nodes.

Only objects carrying `gmgn.generated_by = "navigation-baker-v1"` are removed
on re-bake, so manual markers in `GMGN_WAYPOINTS` and `GMGN_ROUTES` always
survive, and re-running the bake is deterministic.

```bash
blender --background --python tools/blender/bake_gmgn_navigation.py -- \
  --blend path/to/editable.blend \
  --output path/to/editable.nav.blend \
  --max-slope-degrees 45 \
  --spacing 0.5 \
  --agent-radius 0.2 \
  --agent-height 1.8 \
  --maximum-step-height 0.3 \
  --arrival-radius 0.2
```

Options:

| Option | Default | Meaning |
|---|---|---|
| `--blend` | required | Editable GMGN `.blend` to read geometry from |
| `--output` | `<blend stem>.nav.blend` | `.blend` to write; the bake always saves a **new file** by default |
| `--max-slope-degrees` | `45` | Steepest walkable face angle from horizontal (`[0, 90)`) |
| `--spacing` | `0.5` | Grid cell size in meters; bounds the waypoint density |
| `--agent-radius` | `0.3` | Agent capsule radius; expands every active blocker footprint and bounds the spawn link together with `--spacing` |
| `--agent-height` | `1.8` | Agent capsule height; together with `--agent-radius` defines the capsule vertical interval tested against blockers |
| `--maximum-step-height` | `0.3` | Maximum riser height a capsule may step over; blockers that rise no more than this above the ground never prune nodes/edges |
| `--arrival-radius` | `0.2` | `gmgn.arrival_radius` written onto every generated waypoint |
| `--force` | off | Confirm overwriting an existing output or **saving in place** |

Refusing destructive overwrites: the baker never silently replaces a file. If
`--output` already exists the run fails unless `--force` is passed, and saving
**in place** (`--output` equal to `--blend`) is a deliberate destructive edit
that also requires `--force`. Prefer a new `.blend` per bake and keep the
previous file as a checkpoint.

Generated markers are tagged `gmgn.generated_by = "navigation-baker-v1"` so a
re-bake replaces only its own previous output. Waypoints carry
`gmgn.id`, `gmgn.arrival_radius`, `gmgn.enabled`; routes carry `gmgn.id`,
`gmgn.waypoints`, `gmgn.bidirectional` and `gmgn.enabled`. Bake parameters are
recorded as scene metadata (`gmgn.nav_baker_version`, `gmgn.nav_spacing`,
`gmgn.nav_max_slope_degrees`, `gmgn.nav_agent_radius`,
`gmgn.nav_agent_height`, `gmgn.nav_max_step_height`,
`gmgn.nav_arrival_radius`, `gmgn.nav_waypoint_count`, `gmgn.nav_route_count`).

## Scene collections

Objects may be empties unless noted. Each marker carries `gmgn.id`; the exporter
requires unique IDs across all collections.

| Collection | Purpose | Required custom properties |
|---|---|---|
| `GMGN_COLLISION` | Oriented box collision volumes; object dimensions define the box | `gmgn.id`; optional `gmgn.blocking` |
| `GMGN_WAYPOINTS` | Navigation points and the single spawn point | `gmgn.id`; exactly one `gmgn.spawn=true`; optional `gmgn.arrival_radius`, `gmgn.enabled`; baker output adds `gmgn.generated_by` |
| `GMGN_ROUTES` | Ordered waypoint paths | `gmgn.id`, `gmgn.waypoints`; optional `gmgn.bidirectional`, `gmgn.enabled`; baker output adds `gmgn.generated_by` |
| `GMGN_ACTIVITIES` | Activity anchors | `gmgn.id`, `gmgn.action`, `gmgn.entry`; optional `gmgn.motion`, `gmgn.props`, `gmgn.interruptible`, `gmgn.pitch`, `gmgn.display_name` (exported as `activityDefinitions[].displayName` when present) |
| `GMGN_CAMERAS` | Authored camera anchors | `gmgn.id`; optional `gmgn.fov`, `gmgn.near`, `gmgn.far`, `gmgn.pitch` |
| `GMGN_PROPS` | Package-local files referenced by activities | `gmgn.id`, `gmgn.kind`, `gmgn.path`, `gmgn.package_path` |

Reverse-imported transform markers (`GMGN_COLLISION`, the spawn waypoint,
`GMGN_ACTIVITIES` and `GMGN_CAMERAS`) additionally carry
`gmgn.source_quaternion` (the original manifest `[w, x, y, z]`), `gmgn.source_yaw`
and `gmgn.source_pitch`. The exporter reuses the stored quaternion verbatim
while the authored yaw/pitch still match those source values, so quaternions
with a roll component the two-degree-of-freedom yaw/pitch space cannot
represent survive a round trip exactly; once either angle is edited the
exporter falls back to the current authored yaw/pitch conversion.

`gmgn.waypoints` and `gmgn.props` accept either a comma-separated string or a
Blender list-like custom property. Every `gmgn.id` must be unique across all
collections.

The importer records package/world/source/calibration metadata as scene custom
properties:

```text
gmgn.package_id=warm-kitchen-edit
gmgn.package_version=1.0.0
gmgn.world_id=world-labs-example-warm-kitchen
gmgn.display_name=Warm Kitchen Edit
gmgn.source_coordinates=world-labs-opencv
gmgn.source_glb=path/to/collider.glb
gmgn.source_glb_sha256=<sha256 of the input GLB>
gmgn.importer_version=1
gmgn.source_generator=...
gmgn.source_mesh_count=...
gmgn.source_primitive_count=...
gmgn.source_triangle_count=...
gmgn.calibration_rotation_x_radians=3.141592653589793
gmgn.calibration_metric_scale=1.75
gmgn.calibration_ground_plane_offset=0.4
gmgn.calibration_translation_z=-0.7
gmgn.meters_per_unit=1.0
```

Optional `gmgn.capabilities` values are appended to the capabilities generated
for every activity and camera.

## Coordinates and transforms

Blender uses right-handed Z-up coordinates. Gameplay uses right-handed Y-up
coordinates. Export applies `(x, y, z) -> (x, z, -y)` and writes the same
row-major 4 x 4 transform once at `calibration.visualToGameplay`. Marker Z
rotation becomes gameplay yaw. `gmgn.pitch` supplies a camera or anchor pitch in
radians. Reverse-imported markers keep their exact source quaternion under
`gmgn.source_quaternion` and re-export it verbatim while yaw/pitch are
unedited (see the scene-collections table below), so a round trip preserves the
full orientation including roll.

Import calibration is explicit: `source_transform(source_coordinates,
metric_scale, ground_plane_offset)` returns `rotation_x_radians`,
`uniform_scale` and `translation_z`. `world-labs-opencv` maps the source ground
plane to Blender `z = 0`; `gltf` skips the axis rotation. The matrix is baked
into each `GMGN_NAV_SOURCE` mesh copy, so editing happens in calibrated meters.

## Export

Run the exporter inside Blender:

```bash
blender --background path/to/world.blend \
  --python tools/blender/export_gmgn_world.py -- \
  path/to/package/world.json
```

The exporter refuses to overwrite an existing output unless `--force` is
passed (the existing file is left byte-identical on refusal):

```bash
blender --background path/to/world.blend \
  --python tools/blender/export_gmgn_world.py -- \
  --force path/to/package/world.json
```

The exporter sorts every array by stable ID, emits canonical formatted JSON,
rejects duplicate IDs, and calculates SHA-256 from each `GMGN_PROPS` source
file. Copy each source file into the package path declared by
`gmgn.package_path` before validation.

Validate without Blender:

```bash
python3 tools/blender/validate_gmgn_world.py path/to/package
```

Inspect a GLB and report version, generator, mesh, primitive and triangle counts
without Blender:

```bash
python3 -c "import sys; sys.path.insert(0, 'tools/blender'); import import_gmgn_glb as g; print(g.inspect_glb('path/to/collider.glb'))"
```

## Publish

The navigation baker's round-trip export still carries the original manual
routes. `publish_gmgn_world.py` is the explicit promotion gate between that
verified authoring graph and the bundled package the app ships with. It runs in
plain Python (no Blender) and never modifies the source.

```bash
python3 tools/blender/publish_gmgn_world.py \
  --source authoring/worlds/warm-kitchen-canary/roundtrip/world.json \
  --output apps/macos/Resources/Worlds/warm-kitchen-canary/world.json \
  --package-version 1.2.0 \
  --force
```

`--source` accepts either a `world.json` file or a package directory
containing one. The publisher re-validates the source, requires
`--package-version` to be a semantic version (`X.Y.Z` with optional
`-prerelease`/`+build`), and requires that the enabled `route.auto.*` edges
alone can route from `wp.spawn` to every activity entry. It stamps the new
version, keeps every `route.auto.*` route enabled, and preserves but disables
every other route so legacy manual routes never drive runtime navigation. The
output is canonical JSON (sorted keys, two-space indent, trailing newline)
written atomically via a sibling temp file. If that temp file cannot be created
or replaced, publishing fails without touching the destination. An existing
output is refused without `--force` and left byte-identical on refusal.

## Tests

Run the pure Python and Blender tests:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tools.blender.tests.test_bake_gmgn_navigation -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tools.blender.tests.test_import_gmgn_glb -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tools.blender.tests.test_import_gmgn_world -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/blender/tests -v
```

The navigation baker geometry/graph tests, the world-importer manifest/coordinate
tests and the exporter scene tests are pure and run without Blender; the
headless L-floor integration tests, the GLB collection-contract tests and the
world-importer round-trip tests are skipped when `blender` is not on `PATH`.
