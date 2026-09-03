from __future__ import annotations

import importlib.util
import json
import math
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "bake_gmgn_navigation.py"


def load_baker():
    spec = importlib.util.spec_from_file_location("bake_gmgn_navigation", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def grid_floor(size: int, subdivisions: int = 1, z: float = 0.0):
    """Return a flat size x size floor split into grid triangles with +Z normals."""
    step = size / subdivisions
    triangles = []
    for row in range(subdivisions):
        for col in range(subdivisions):
            x0, y0 = col * step, row * step
            x1, y1 = x0 + step, y0 + step
            triangles.append(((x0, y0, z), (x1, y0, z), (x1, y1, z)))
            triangles.append(((x0, y0, z), (x1, y1, z), (x0, y1, z)))
    return triangles


def l_shaped_floor():
    """Two 1m-wide arms forming an L plus a steep non-walkable wall face."""
    return [
        # Bottom arm: x in [0, 2], y in [0, 1]
        ((0.0, 0.0, 0.0), (2.0, 0.0, 0.0), (2.0, 1.0, 0.0)),
        ((0.0, 0.0, 0.0), (2.0, 1.0, 0.0), (1.0, 1.0, 0.0)),
        ((0.0, 0.0, 0.0), (1.0, 1.0, 0.0), (0.0, 1.0, 0.0)),
        # Top arm: x in [0, 1], y in [1, 2]
        ((0.0, 1.0, 0.0), (1.0, 1.0, 0.0), (1.0, 2.0, 0.0)),
        ((0.0, 1.0, 0.0), (1.0, 2.0, 0.0), (0.0, 2.0, 0.0)),
        # Vertical wall at x = 2 (normal +X, 90 degrees from up: not walkable)
        ((2.0, 0.0, 0.0), (2.0, 1.0, 0.0), (2.0, 0.0, 1.0)),
    ]


class BakeNavigationGeometryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.baker = load_baker()

    def test_rejects_non_finite_and_degenerate_geometry(self) -> None:
        with self.assertRaisesRegex(self.baker.BakeError, "finite"):
            self.baker.bake_nav_graph(
                [((0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (float("nan"), 1.0, 0.0))],
                max_slope_degrees=45.0,
                spacing=0.5,
            )
        with self.assertRaisesRegex(self.baker.BakeError, "finite"):
            self.baker.bake_nav_graph(
                [((0.0, 0.0, 0.0), (float("inf"), 0.0, 0.0), (0.0, 1.0, 0.0))],
                max_slope_degrees=45.0,
                spacing=0.5,
            )
        with self.assertRaisesRegex(self.baker.BakeError, "degenerate"):
            self.baker.bake_nav_graph(
                [((0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (2.0, 0.0, 0.0))],
                max_slope_degrees=45.0,
                spacing=0.5,
            )

    def test_upward_facing_slope_filtering(self) -> None:
        baker = self.baker
        flat = ((0.0, 0.0, 0.0), (2.0, 0.0, 0.0), (0.0, 2.0, 0.0))
        wall = ((0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 0.0, 1.0))
        ramp = ((0.0, 0.0, 0.0), (2.0, 0.0, 0.0), (1.0, 1.0, 1.0))

        self.assertTrue(baker.is_walkable(*flat, 45.0))
        self.assertFalse(baker.is_walkable(*wall, 45.0))
        self.assertAlmostEqual(baker.triangle_upward_angle_degrees(*ramp), 45.0, places=9)
        self.assertTrue(baker.is_walkable(*ramp, 45.0))
        self.assertFalse(baker.is_walkable(*ramp, 20.0))

        graph = baker.bake_nav_graph([flat, wall, ramp], max_slope_degrees=45.0, spacing=1.0)
        self.assertEqual(graph.waypoint_count, 3)

    def test_connected_regions_split_disconnected_walkable_surfaces(self) -> None:
        baker = self.baker
        square_a = grid_floor(size=1.0, subdivisions=1)
        square_b = [
            (
                (a[0] + 10.0, a[1] + 10.0, a[2]),
                (b[0] + 10.0, b[1] + 10.0, b[2]),
                (c[0] + 10.0, c[1] + 10.0, c[2]),
            )
            for (a, b, c) in grid_floor(size=1.0, subdivisions=1)
        ]

        regions = baker.connected_regions(square_a + square_b)
        self.assertEqual(len(regions), 2)

        joined = grid_floor(size=1.0, subdivisions=2)
        self.assertEqual(len(baker.connected_regions(joined)), 1)

    def test_dense_input_produces_sparse_bounded_graph(self) -> None:
        baker = self.baker
        triangles = grid_floor(size=4.0, subdivisions=20)  # 800 input triangles
        graph = baker.bake_nav_graph(triangles, max_slope_degrees=45.0, spacing=1.0)

        # One waypoint per occupied 1m cell, regardless of input density.
        self.assertEqual(graph.waypoint_count, 16)
        self.assertEqual(graph.route_count, 24)
        positions = {(round(wp.x, 3), round(wp.y, 3)) for wp in graph.waypoints}
        self.assertEqual(
            positions,
            {
                (round(ix + 0.5, 3), round(iy + 0.5, 3))
                for ix in range(4)
                for iy in range(4)
            },
        )
        for from_id, to_id in graph.routes:
            self.assertNotEqual(from_id, to_id)

    def test_bake_is_deterministic_and_ids_are_stable(self) -> None:
        baker = self.baker
        triangles = grid_floor(size=4.0, subdivisions=5) + l_shaped_floor()
        first = baker.bake_nav_graph(triangles, max_slope_degrees=45.0, spacing=0.5)
        second = baker.bake_nav_graph(triangles, max_slope_degrees=45.0, spacing=0.5)

        self.assertEqual(
            [(wp.id, wp.x, wp.y, wp.z) for wp in first.waypoints],
            [(wp.id, wp.x, wp.y, wp.z) for wp in second.waypoints],
        )
        self.assertEqual(first.routes, second.routes)
        self.assertEqual(len({wp.id for wp in first.waypoints}), first.waypoint_count)
        self.assertEqual(len({r for r in first.routes}), first.route_count)

    def test_l_shaped_floor_preserves_turn_and_corridor_connectivity(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(l_shaped_floor(), max_slope_degrees=45.0, spacing=0.5)

        # L arms (3 m^2) at 0.5 m spacing => 12 occupied cells, one node each.
        self.assertEqual(graph.waypoint_count, 12)
        self.assertEqual(graph.route_count, 16)

        # The steep wall contributes nothing: every waypoint sits on the floor.
        for wp in graph.waypoints:
            self.assertAlmostEqual(wp.z, 0.0, places=9)

        adjacency = {wp.id: set() for wp in graph.waypoints}
        for from_id, to_id in graph.routes:
            adjacency[from_id].add(to_id)
            adjacency[to_id].add(from_id)
        seen = set()
        queue = [graph.waypoints[0].id]
        while queue:
            current = queue.pop()
            if current in seen:
                continue
            seen.add(current)
            queue.extend(adjacency[current] - seen)
        self.assertEqual(len(seen), graph.waypoint_count)

        def nearest(px: float, py: float) -> str:
            return min(
                graph.waypoints,
                key=lambda wp: (wp.x - px) ** 2 + (wp.y - py) ** 2,
            ).id

        corner = nearest(0.25, 0.25)
        bottom_arm = nearest(0.25, 0.75)
        top_arm = nearest(0.25, 1.25)
        corner_wp = next(wp for wp in graph.waypoints if wp.id == corner)
        self.assertLess((corner_wp.x - 0.25) ** 2 + (corner_wp.y - 0.25) ** 2, 0.04)
        self.assertIn(bottom_arm, adjacency[corner])
        self.assertIn(top_arm, adjacency[bottom_arm])

    def test_empty_walkable_input_returns_empty_graph(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(
            [((0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 0.0, 1.0))],
            max_slope_degrees=45.0,
            spacing=0.5,
        )
        self.assertEqual(graph.waypoint_count, 0)
        self.assertEqual(graph.route_count, 0)

    def test_parameters_are_validated(self) -> None:
        baker = self.baker
        triangles = grid_floor(size=1.0, subdivisions=1)
        with self.assertRaisesRegex(baker.BakeError, "spacing"):
            baker.bake_nav_graph(triangles, max_slope_degrees=45.0, spacing=0.0)
        with self.assertRaisesRegex(baker.BakeError, "max_slope_degrees"):
            baker.bake_nav_graph(triangles, max_slope_degrees=90.0, spacing=0.5)
        with self.assertRaisesRegex(baker.BakeError, "max_slope_degrees"):
            baker.bake_nav_graph(triangles, max_slope_degrees=-1.0, spacing=0.5)
        with self.assertRaisesRegex(baker.BakeError, "arrival_radius"):
            baker.validate_bake_parameters(
                max_slope_degrees=45.0,
                spacing=0.5,
                agent_radius=0.3,
                arrival_radius=0.0,
            )

    def test_nearest_waypoint_is_deterministic_and_bounded(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(grid_floor(size=2.0, subdivisions=2), spacing=1.0)

        nearest = baker.nearest_waypoint(graph, (0.0, 0.0, 0.0), max_distance=2.0)
        self.assertEqual((nearest.x, nearest.y, nearest.z), (0.5, 0.5, 0.0))
        self.assertIsNone(
            baker.nearest_waypoint(graph, (0.0, 0.0, 0.0), max_distance=0.1)
        )

    def test_spawn_link_distance_uses_spacing_and_agent_radius(self) -> None:
        baker = self.baker
        self.assertEqual(baker.spawn_link_max_distance(0.5, 0.3), 1.0)
        self.assertEqual(baker.spawn_link_max_distance(2.0, 0.3), 4.0)
        self.assertEqual(baker.spawn_link_max_distance(0.25, 0.8), 1.6)

    def test_anchor_link_route_id_is_deterministic_and_unique(self) -> None:
        baker = self.baker
        self.assertEqual(
            baker.anchor_link_route_id("wp.dining.table"),
            "route.auto.anchor.wp.dining.table",
        )
        self.assertEqual(
            baker.anchor_link_route_id("wp.spawn"),
            "route.auto.anchor.wp.spawn",
        )
        self.assertNotEqual(
            baker.anchor_link_route_id("wp.a"),
            baker.anchor_link_route_id("wp.b"),
        )

    def test_anchor_links_connect_manual_waypoints_to_nearest_node(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(
            grid_floor(size=2.0, subdivisions=1), max_slope_degrees=45.0, spacing=1.0
        )
        # Nodes sit at (0.5,0.5), (1.5,0.5), (0.5,1.5), (1.5,1.5).
        manual = [
            ("wp.spawn", (0.0, 0.0, 0.0)),
            ("wp.chair", (1.5, 1.5, 0.0)),
            ("wp.far", (5.0, 5.0, 0.0)),
            ("wp.dupe", (0.2, 0.2, 0.0)),
            ("wp.dupe", (1.0, 1.0, 0.0)),
        ]
        links = baker.anchor_links(
            graph,
            manual,
            [],
            max_distance=1.0,
            agent_radius=0.2,
            agent_height=1.8,
            max_step_height=0.3,
        )
        by_manual = dict(links)
        self.assertEqual(by_manual["wp.spawn"], "wp.auto.0")
        self.assertEqual(by_manual["wp.chair"], "wp.auto.3")
        # Too far to reach any node.
        self.assertNotIn("wp.far", by_manual)
        # Duplicate manual ids keep only the first (sorted) link.
        self.assertEqual(len(links), 3)
        self.assertEqual([mid for mid, _ in links], ["wp.chair", "wp.dupe", "wp.spawn"])

    def test_anchor_links_reject_segments_crossing_blockers(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(
            grid_floor(size=3.0, subdivisions=1), max_slope_degrees=45.0, spacing=1.0
        )
        # A wall along x = 1.5 spans the whole floor.
        wall = baker.NavObstacle("wall", (1.5, 1.0, 1.0), (0.05, 1.5, 2.0))
        manual = [
            # Same cell as its nearest node: no crossing, link is fine.
            ("wp.near_left", (0.5, 1.5, 0.0)),
            # Nearest node sits on the far side of the wall: link rejected.
            ("wp.far_left", (1.4, 1.5, 0.0)),
        ]
        links = baker.anchor_links(
            graph,
            manual,
            [wall],
            max_distance=1.0,
            agent_radius=0.2,
            agent_height=1.8,
            max_step_height=0.3,
        )
        by_manual = dict(links)
        self.assertIn("wp.near_left", by_manual)
        self.assertNotIn("wp.far_left", by_manual)

    def test_remove_orphan_nodes_drops_unlinked_isolated_nodes(self) -> None:
        baker = self.baker
        graph = baker.NavGraph(
            [
                baker.NavWaypoint("wp.auto.0", 0.0, 0.0, 0.0),
                baker.NavWaypoint("wp.auto.1", 1.0, 0.0, 0.0),
                baker.NavWaypoint("wp.auto.2", 2.0, 0.0, 0.0),
            ],
            [("wp.auto.0", "wp.auto.1")],
        )
        pruned = baker.remove_orphan_nodes(graph, linked_node_ids=())
        self.assertEqual([wp.id for wp in pruned.waypoints], ["wp.auto.0", "wp.auto.1"])
        self.assertEqual(pruned.routes, [("wp.auto.0", "wp.auto.1")])

        # A linked orphan (target of a manual anchor) is kept even with no edges.
        kept = baker.remove_orphan_nodes(graph, linked_node_ids=["wp.auto.2"])
        self.assertEqual([wp.id for wp in kept.waypoints], ["wp.auto.0", "wp.auto.1", "wp.auto.2"])


class BakeNavigationCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.baker = load_baker()

    def test_check_output_policy_refuses_destructive_overwrite(self) -> None:
        baker = self.baker
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            blend = root / "world.blend"
            existing = root / "existing.nav.blend"
            existing.write_bytes(b"x")
            fresh = root / "fresh.nav.blend"

            self.assertIsNone(baker.check_output_policy(blend, fresh, force=False))
            self.assertIsNotNone(baker.check_output_policy(blend, existing, force=False))
            self.assertIsNone(baker.check_output_policy(blend, existing, force=True))
            self.assertIsNotNone(baker.check_output_policy(blend, blend, force=False))
            self.assertIsNone(baker.check_output_policy(blend, blend, force=True))

    def test_main_refuses_missing_blend_without_blender(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.baker.main(
                [
                    "--blend",
                    str(root / "missing.blend"),
                    "--output",
                    str(root / "out.nav.blend"),
                ]
            )
        self.assertEqual(result, 1)


@unittest.skipUnless(shutil.which("blender"), "Blender is required")
class BakeNavigationBlenderIntegrationTests(unittest.TestCase):
    BLENDER = shutil.which("blender") or "blender"

    def _run_blender(self, *args, python_expr=None, python_script=None):
        # Blend paths must precede --python-expr so the file is loaded first.
        command = [self.BLENDER, "--background"] + list(args)
        if python_script:
            command += ["--python", str(python_script)]
        else:
            command += ["--python-expr", python_expr]
        return subprocess.run(
            command, check=False, capture_output=True, text=True, timeout=120
        )

    def _write_l_floor_blend(self, path: Path) -> None:
        expression = """
import bpy, json

scene = bpy.context.scene
for name in ("GMGN_SOURCE", "GMGN_NAV_SOURCE", "GMGN_WAYPOINTS", "GMGN_ROUTES"):
    scene.collection.children.link(bpy.data.collections.new(name))

verts = [
    (0.0, 0.0, 0.0), (2.0, 0.0, 0.0), (2.0, 1.0, 0.0),
    (1.0, 1.0, 0.0), (0.0, 1.0, 0.0), (1.0, 2.0, 0.0), (0.0, 2.0, 0.0),
    (2.0, 0.0, 1.0),
]
faces = [(0, 1, 2), (0, 2, 3), (0, 3, 4), (4, 3, 5), (4, 5, 6), (1, 2, 7)]
mesh = bpy.data.meshes.new("LFloor")
mesh.from_pydata(verts, [], faces)
mesh.update()
obj = bpy.data.objects.new("LFloor", mesh)
bpy.data.collections["GMGN_NAV_SOURCE"].objects.link(obj)

spawn = bpy.data.objects.new("wp.spawn", None)
spawn.location = (0.0, 0.0, 0.0)
spawn["gmgn.id"] = "wp.spawn"
spawn["gmgn.spawn"] = True
bpy.data.collections["GMGN_WAYPOINTS"].objects.link(spawn)

manual = bpy.data.objects.new("wp.manual.flag", None)
manual.location = (1.5, 0.5, 0.0)
manual["gmgn.id"] = "wp.manual.flag"
manual["gmgn.arrival_radius"] = 0.5
bpy.data.collections["GMGN_WAYPOINTS"].objects.link(manual)

scene["gmgn.package_id"] = "nav-test"
scene["gmgn.package_version"] = "1.0.0"
scene["gmgn.world_id"] = "world.nav-test"
scene["gmgn.display_name"] = "Navigation Test"

bpy.ops.wm.save_as_mainfile(filepath=r"PATH")
print("GMGN_FLOOR_WRITTEN")
"""
        expression = expression.replace("PATH", str(path))
        completed = self._run_blender(python_expr=expression)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertTrue(path.is_file())

    def _inspect(self, blend: Path) -> dict:
        expression = """
import bpy, json

def payload_from_objects(collection):
    out = []
    for obj in collection.objects:
        entry = {"name": obj.name, "type": obj.type, "location": list(obj.location)}
        for key in ("gmgn.id", "gmgn.arrival_radius", "gmgn.enabled",
                    "gmgn.generated_by", "gmgn.spawn", "gmgn.bidirectional"):
            if key in obj:
                entry[key] = obj[key]
        if "gmgn.waypoints" in obj:
            entry["gmgn.waypoints"] = list(obj["gmgn.waypoints"])
        out.append(entry)
    return sorted(out, key=lambda item: str(item.get("gmgn.id")))

payload = {
    "waypoints": payload_from_objects(bpy.data.collections["GMGN_WAYPOINTS"]),
    "routes": payload_from_objects(bpy.data.collections["GMGN_ROUTES"]),
}
print("GMGN_INSPECT " + json.dumps(payload, sort_keys=True))
"""
        completed = self._run_blender(str(blend), python_expr=expression)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        line = next(
            line for line in completed.stdout.splitlines() if line.startswith("GMGN_INSPECT ")
        )
        return json.loads(line.removeprefix("GMGN_INSPECT "))

    def test_bakes_l_floor_preserves_manual_markers_and_reruns_deterministically(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "l-floor.blend"
            baked = root / "l-floor.nav.blend"
            self._write_l_floor_blend(source)

            command = [
                self.BLENDER,
                "--background",
                "--python",
                str(MODULE_PATH),
                "--",
                "--blend",
                str(source),
                "--output",
                str(baked),
                "--max-slope-degrees",
                "45",
                "--spacing",
                "0.5",
                "--agent-radius",
                "0.3",
                "--arrival-radius",
                "0.3",
            ]
            first = subprocess.run(command, check=False, capture_output=True, text=True, timeout=120)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            self.assertTrue(baked.is_file())

            state = self._inspect(baked)
            auto_waypoints = [w for w in state["waypoints"] if w.get("gmgn.generated_by") == "navigation-baker-v1"]
            auto_routes = [r for r in state["routes"] if r.get("gmgn.generated_by") == "navigation-baker-v1"]
            self.assertEqual(len(auto_waypoints), 12)
            # 16 graph edges + 1 spawn link + 1 manual anchor link.
            self.assertEqual(len(auto_routes), 18)

            spawn = next(w for w in state["waypoints"] if w.get("gmgn.spawn"))
            manual = next(w for w in state["waypoints"] if w.get("gmgn.id") == "wp.manual.flag")
            self.assertEqual(spawn["gmgn.id"], "wp.spawn")
            self.assertEqual(manual["gmgn.arrival_radius"], 0.5)

            spawn_route = next(r for r in state["routes"] if r.get("gmgn.id") == "route.auto.spawn")
            self.assertEqual(list(spawn_route["gmgn.waypoints"])[0], "wp.spawn")

            anchor_route = next(
                r for r in state["routes"]
                if r.get("gmgn.id") == "route.auto.anchor.wp.manual.flag"
            )
            self.assertEqual(list(anchor_route["gmgn.waypoints"])[0], "wp.manual.flag")
            anchor_target = anchor_route["gmgn.waypoints"][1]
            self.assertIn(anchor_target, {w["gmgn.id"] for w in auto_waypoints})

            generated_ids = [w["gmgn.id"] for w in auto_waypoints]
            self.assertEqual(len(generated_ids), len(set(generated_ids)))
            for wp in auto_waypoints:
                self.assertEqual(wp["gmgn.arrival_radius"], 0.3)
                self.assertTrue(wp["gmgn.enabled"])
                self.assertAlmostEqual(wp["location"][2], 0.0, places=6)
            for route in auto_routes:
                self.assertTrue(route["gmgn.bidirectional"])
                self.assertTrue(route["gmgn.enabled"])
                self.assertEqual(len(route["gmgn.waypoints"]), 2)

            # A second bake over the same blend is refused without --force ...
            refused = subprocess.run(
                command, check=False, capture_output=True, text=True, timeout=120
            )
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("force", (refused.stdout + refused.stderr).lower())

            # ... and an in-place rerun with --force is deterministic.
            in_place = subprocess.run(
                command + ["--force", "--output", str(baked)],
                check=False,
                capture_output=True,
                text=True,
                timeout=120,
            )
            self.assertEqual(in_place.returncode, 0, in_place.stdout + in_place.stderr)
            rerun = self._inspect(baked)
            rerun_auto = [w for w in rerun["waypoints"] if w.get("gmgn.generated_by") == "navigation-baker-v1"]
            self.assertEqual(
                [w["gmgn.id"] for w in rerun_auto],
                generated_ids,
            )
            self.assertEqual(
                len([r for r in rerun["routes"] if r.get("gmgn.generated_by") == "navigation-baker-v1"]),
                len(auto_routes),
            )
            self.assertTrue(
                any(w.get("gmgn.id") == "wp.manual.flag" for w in rerun["waypoints"])
            )
            self.assertTrue(
                any(w.get("gmgn.spawn") for w in rerun["waypoints"])
            )

    def test_baked_scene_exports_and_validates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "l-floor.blend"
            baked = root / "l-floor.nav.blend"
            package = root / "package"
            self._write_l_floor_blend(source)

            bake = subprocess.run(
                [
                    self.BLENDER,
                    "--background",
                    "--python",
                    str(MODULE_PATH),
                    "--",
                    "--blend",
                    str(source),
                    "--output",
                    str(baked),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=120,
            )
            self.assertEqual(bake.returncode, 0, bake.stdout + bake.stderr)

            exported = subprocess.run(
                [
                    self.BLENDER,
                    "--background",
                    str(baked),
                    "--python",
                    str(Path(__file__).parents[1] / "export_gmgn_world.py"),
                    "--",
                    str(package / "world.json"),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=120,
            )
            self.assertEqual(exported.returncode, 0, exported.stdout + exported.stderr)
            manifest = json.loads((package / "world.json").read_text())
            self.assertEqual(manifest["schemaVersion"], 1)
            self.assertEqual(manifest["waypoints"].__len__(), 14)  # 12 auto + spawn + manual
            # 16 graph edges + spawn link + manual anchor link.
            self.assertEqual(manifest["routes"].__len__(), 18)
            route_ids = [route["id"] for route in manifest["routes"]]
            self.assertEqual(len(route_ids), len(set(route_ids)))
            waypoint_ids = {wp["id"] for wp in manifest["waypoints"]}
            for route in manifest["routes"]:
                for waypoint_id in route["waypointIDs"]:
                    self.assertIn(waypoint_id, waypoint_ids)

            validated = subprocess.run(
                [
                    "python3",
                    str(Path(__file__).parents[1] / "validate_gmgn_world.py"),
                    str(package),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(validated.returncode, 0, validated.stdout + validated.stderr)
            self.assertIn("PASS", validated.stdout)


    def _write_obstacle_floor_blend(self, path: Path) -> None:
        expression = r'''
import bpy

scene = bpy.context.scene
for name in ("GMGN_NAV_SOURCE", "GMGN_COLLISION", "GMGN_WAYPOINTS", "GMGN_ROUTES"):
    scene.collection.children.link(bpy.data.collections.new(name))

# 3 x 3 m flat floor at z = 0 (9 cells at 1 m spacing).
floor_mesh = bpy.data.meshes.new("ObstacleFloor")
verts = [(0.0, 0.0, 0.0), (3.0, 0.0, 0.0), (3.0, 3.0, 0.0), (0.0, 3.0, 0.0)]
faces = [(0, 1, 2), (0, 2, 3)]
floor_mesh.from_pydata(verts, [], faces)
floor_mesh.update()
floor_obj = bpy.data.objects.new("ObstacleFloor", floor_mesh)
bpy.data.collections["GMGN_NAV_SOURCE"].objects.link(floor_obj)

def cube(name, collection, location, size, blocking=True):
    m = bpy.data.meshes.new(name + ".mesh")
    hx, hy, hz = size[0] * 0.5, size[1] * 0.5, size[2] * 0.5
    cube_verts = [
        (-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz),
        (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz),
    ]
    cube_faces = [(0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1),
                  (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]
    m.from_pydata(cube_verts, [], cube_faces)
    m.update()
    obj = bpy.data.objects.new(name, m)
    obj.location = location
    obj["gmgn.id"] = name
    obj["gmgn.blocking"] = blocking
    bpy.data.collections[collection].objects.link(obj)

# Worktop box over the (0.5, 0.5) grid cell center.
cube("collision.worktop", "GMGN_COLLISION", (0.5, 0.5, 0.45), (0.5, 0.5, 0.9))
# Wall along x = 1.0 spanning the whole floor (must block cross-wall edges).
cube("collision.wall", "GMGN_COLLISION", (1.0, 1.5, 1.0), (0.1, 3.0, 2.0))
# Non-blocking decor box over (2.5, 2.5): must be ignored.
cube("collision.decor", "GMGN_COLLISION", (2.5, 2.5, 0.45), (0.5, 0.5, 0.9), blocking=False)

spawn = bpy.data.objects.new("wp.spawn", None)
spawn.location = (0.0, 0.0, 0.0)
spawn["gmgn.id"] = "wp.spawn"
spawn["gmgn.spawn"] = True
bpy.data.collections["GMGN_WAYPOINTS"].objects.link(spawn)

manual = bpy.data.objects.new("wp.manual.flag", None)
manual.location = (2.5, 0.5, 0.0)
manual["gmgn.id"] = "wp.manual.flag"
manual["gmgn.arrival_radius"] = 0.5
bpy.data.collections["GMGN_WAYPOINTS"].objects.link(manual)

scene["gmgn.package_id"] = "nav-obstacle-test"
scene["gmgn.package_version"] = "1.0.0"
scene["gmgn.world_id"] = "world.nav-obstacle-test"
scene["gmgn.display_name"] = "Obstacle Navigation Test"

bpy.ops.wm.save_as_mainfile(filepath=r"PATH")
print("GMGN_OBSTACLE_FLOOR_WRITTEN")
'''
        expression = expression.replace("PATH", str(path))
        completed = self._run_blender(python_expr=expression)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertTrue(path.is_file())

    def test_bakes_prunes_obstacles_keeps_manual_markers_and_reruns_deterministically(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "obstacle-floor.blend"
            baked = root / "obstacle-floor.nav.blend"
            self._write_obstacle_floor_blend(source)

            command = [
                self.BLENDER,
                "--background",
                "--python",
                str(MODULE_PATH),
                "--",
                "--blend",
                str(source),
                "--output",
                str(baked),
                "--spacing",
                "1.0",
                "--agent-radius",
                "0.2",
                "--agent-height",
                "1.8",
                "--maximum-step-height",
                "0.3",
                "--arrival-radius",
                "0.2",
            ]
            first = subprocess.run(
                command, check=False, capture_output=True, text=True, timeout=120
            )
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            self.assertTrue(baked.is_file())

            state = self._inspect(baked)
            auto_waypoints = [
                w for w in state["waypoints"] if w.get("gmgn.generated_by") == "navigation-baker-v1"
            ]
            auto_routes = [
                r for r in state["routes"] if r.get("gmgn.generated_by") == "navigation-baker-v1"
            ]

            # 9 floor cells minus the worktop cell; the wall removes no nodes.
            self.assertEqual(len(auto_waypoints), 8)
            # 12 grid edges minus 3 wall crossings minus 1 worktop-node edge,
            # plus the manual flag anchor link (the spawn link is rejected).
            self.assertEqual(len(auto_routes), 9)
            self.assertTrue(
                any(
                    r.get("gmgn.id") == "route.auto.anchor.wp.manual.flag"
                    for r in state["routes"]
                )
            )

            # The worktop footprint is excluded ...
            self.assertFalse(
                any(
                    abs(w["location"][0] - 0.5) < 1e-5
                    and abs(w["location"][1] - 0.5) < 1e-5
                    for w in auto_waypoints
                )
            )
            # ... the non-blocking decor box is ignored ...
            self.assertTrue(
                any(
                    abs(w["location"][0] - 2.5) < 1e-5
                    and abs(w["location"][1] - 2.5) < 1e-5
                    for w in auto_waypoints
                )
            )
            # Manual markers survive.
            self.assertTrue(
                any(w.get("gmgn.id") == "wp.manual.flag" for w in state["waypoints"])
            )
            self.assertTrue(
                any(w.get("gmgn.spawn") for w in state["waypoints"])
            )
            # No cross-wall edges: no generated route spans the wall at x=1.0.
            location_of = {
                w["gmgn.id"]: (w["location"][0], w["location"][1])
                for w in state["waypoints"]
            }
            for route in auto_routes:
                first_id, second_id = route["gmgn.waypoints"]
                first_x, _ = location_of[first_id]
                second_x, _ = location_of[second_id]
                self.assertFalse(
                    min(first_x, second_x) < 0.75 and max(first_x, second_x) > 1.25,
                    f"route {route['gmgn.id']} crosses the wall",
                )
            # The automatic spawn link is rejected: the segment from the spawn
            # to the nearest waypoint crosses the worktop footprint.
            self.assertFalse(
                any(r.get("gmgn.id") == "route.auto.spawn" for r in state["routes"])
            )

            scene = self._scene_metadata(baked)
            self.assertAlmostEqual(scene["gmgn.nav_agent_radius"], 0.2, places=6)
            self.assertAlmostEqual(scene["gmgn.nav_agent_height"], 1.8, places=6)
            self.assertAlmostEqual(scene["gmgn.nav_max_step_height"], 0.3, places=6)

            # Deterministic rerun over the same file with --force is identical.
            rerun = subprocess.run(
                command + ["--force", "--output", str(baked)],
                check=False,
                capture_output=True,
                text=True,
                timeout=120,
            )
            self.assertEqual(rerun.returncode, 0, rerun.stdout + rerun.stderr)
            rerun_state = self._inspect(baked)
            rerun_auto = [
                w for w in rerun_state["waypoints"]
                if w.get("gmgn.generated_by") == "navigation-baker-v1"
            ]
            self.assertEqual(
                [w["gmgn.id"] for w in rerun_auto],
                [w["gmgn.id"] for w in auto_waypoints],
            )
            self.assertEqual(
                len(
                    [
                        r for r in rerun_state["routes"]
                        if r.get("gmgn.generated_by") == "navigation-baker-v1"
                    ]
                ),
                len(auto_routes),
            )
            self.assertTrue(
                any(w.get("gmgn.id") == "wp.manual.flag" for w in rerun_state["waypoints"])
            )

    def _scene_metadata(self, blend: Path) -> dict:
        expression = r'''
import bpy, json
metadata = {key: value for key, value in bpy.context.scene.items()}
print("GMGN_METADATA " + json.dumps(metadata, sort_keys=True))
'''
        completed = self._run_blender(str(blend), python_expr=expression)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        line = next(
            line for line in completed.stdout.splitlines() if line.startswith("GMGN_METADATA ")
        )
        return json.loads(line.removeprefix("GMGN_METADATA "))


class BakeNavigationObstacleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.baker = load_baker()

    def test_axis_aligned_blocker_removes_interior_nodes_and_touching_edges(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(
            grid_floor(size=2.0, subdivisions=1), max_slope_degrees=45.0, spacing=1.0
        )
        self.assertEqual(graph.waypoint_count, 4)
        # Box covering the far corner cell center (1.5, 1.5), rising 0.9 m.
        obstacle = baker.NavObstacle("blocker", (1.5, 1.5, 0.45), (0.4, 0.4, 0.45))
        pruned = baker.prune_graph(
            graph, [obstacle], agent_radius=0.2, agent_height=1.8, max_step_height=0.3
        )
        self.assertEqual(pruned.waypoint_count, 3)
        self.assertEqual(
            [wp.id for wp in pruned.waypoints], ["wp.auto.0", "wp.auto.1", "wp.auto.2"]
        )
        # The two edges that touch the removed corner are gone as well.
        self.assertEqual(pruned.route_count, 2)
        self.assertEqual(
            pruned.routes,
            [("wp.auto.0", "wp.auto.1"), ("wp.auto.0", "wp.auto.2")],
        )

    def test_axis_aligned_blocker_removes_crossing_edges_but_keeps_nodes(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(
            grid_floor(size=2.0, subdivisions=1), max_slope_degrees=45.0, spacing=1.0
        )
        # Thin box straddling the horizontal grid line at x=1: no cell center
        # is covered, but the (0.5, 0.5) -> (1.5, 0.5) edge crosses it.
        obstacle = baker.NavObstacle("divider", (1.0, 0.5, 0.45), (0.1, 0.4, 0.45))
        pruned = baker.prune_graph(
            graph, [obstacle], agent_radius=0.2, agent_height=1.8, max_step_height=0.3
        )
        self.assertEqual(pruned.waypoint_count, 4)
        self.assertEqual(pruned.route_count, 3)
        self.assertNotIn(("wp.auto.0", "wp.auto.2"), pruned.routes)
        self.assertIn(("wp.auto.1", "wp.auto.3"), pruned.routes)

    def test_rotated_blocker_uses_oriented_footprint(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(
            grid_floor(size=3.0, subdivisions=3), max_slope_degrees=45.0, spacing=0.5
        )
        positions = {
            (round(wp.x, 6), round(wp.y, 6)): wp.id for wp in graph.waypoints
        }
        inside_id = positions[(2.25, 1.75)]
        outside_id = positions[(2.25, 0.75)]
        # A 45-degree box whose long axis follows the diagonal: (2.25, 1.75) is
        # inside the rotated footprint, while (2.25, 0.75) would be inside an
        # axis-aligned box of the same expanded extents but is outside the
        # rotated one.
        obstacle = baker.NavObstacle(
            "rotated", (1.75, 1.25, 0.45), (1.0, 0.3, 0.45), rotation_z=math.pi / 4
        )
        pruned = baker.prune_graph(
            graph, [obstacle], agent_radius=0.2, agent_height=1.8, max_step_height=0.3
        )
        surviving = {wp.id for wp in pruned.waypoints}
        self.assertNotIn(inside_id, surviving)
        self.assertIn(outside_id, surviving)

        # Proof the orientation matters: the same box without rotation would
        # remove the outside point.
        axis_aligned = baker.NavObstacle(
            "axis", (1.75, 1.25, 0.45), (1.0, 0.3, 0.45), rotation_z=0.0
        )
        pruned_axis = baker.prune_graph(
            graph, [axis_aligned], agent_radius=0.2, agent_height=1.8, max_step_height=0.3
        )
        self.assertNotIn(outside_id, {wp.id for wp in pruned_axis.waypoints})

    def test_floor_slab_below_step_height_never_erases_walkable_floor(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(
            grid_floor(size=2.0, subdivisions=1), max_slope_degrees=45.0, spacing=1.0
        )
        # A floor slab whose top is 0.05 m above the walkable floor.
        slab = baker.NavObstacle("floor.slab", (1.5, 1.5, 0.0), (0.4, 0.4, 0.05))
        pruned = baker.prune_graph(
            graph, [slab], agent_radius=0.2, agent_height=1.8, max_step_height=0.3
        )
        self.assertEqual(pruned.waypoint_count, 4)
        self.assertEqual(pruned.route_count, 4)

        # A riser whose top is exactly feet + maximum step height is a legal
        # step, not a blocker.
        step = baker.NavObstacle("step", (1.5, 1.5, 0.25), (0.4, 0.4, 0.05))
        pruned = baker.prune_graph(
            graph, [step], agent_radius=0.2, agent_height=1.8, max_step_height=0.3
        )
        self.assertEqual(pruned.waypoint_count, 4)
        self.assertEqual(pruned.route_count, 4)

    def test_non_blocking_box_is_ignored(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(
            grid_floor(size=2.0, subdivisions=1), max_slope_degrees=45.0, spacing=1.0
        )
        decor = baker.NavObstacle(
            "decor", (1.5, 1.5, 0.45), (0.4, 0.4, 0.45), blocking=False
        )
        pruned = baker.prune_graph(
            graph, [decor], agent_radius=0.2, agent_height=1.8, max_step_height=0.3
        )
        self.assertEqual(pruned.waypoint_count, 4)
        self.assertEqual(pruned.route_count, 4)
        self.assertEqual(
            baker.find_graph_obstacle_penetrations(
                graph, [decor], agent_radius=0.2, agent_height=1.8, max_step_height=0.3
            ),
            [],
        )

    def test_floating_box_above_capsule_is_ignored(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(
            grid_floor(size=2.0, subdivisions=1), max_slope_degrees=45.0, spacing=1.0
        )
        # Vertical interval [1.7, 2.0] sits entirely above the capsule top 1.6.
        shelf = baker.NavObstacle("shelf", (1.5, 1.5, 1.85), (0.4, 0.4, 0.15))
        pruned = baker.prune_graph(
            graph, [shelf], agent_radius=0.2, agent_height=1.8, max_step_height=0.3
        )
        self.assertEqual(pruned.waypoint_count, 4)
        self.assertEqual(pruned.route_count, 4)

    def test_segment_crosses_obstacles_acceptance_for_spawn_link(self) -> None:
        baker = self.baker
        box = baker.NavObstacle("box", (1.0, 0.0, 0.45), (0.1, 0.5, 0.45))
        kwargs = dict(agent_radius=0.2, agent_height=1.8, max_step_height=0.3)
        self.assertTrue(
            baker.segment_crosses_obstacles(
                (0.0, 0.0, 0.0), (2.0, 0.0, 0.0), [box], **kwargs
            )
        )
        self.assertFalse(
            baker.segment_crosses_obstacles(
                (0.0, 2.0, 0.0), (2.0, 2.0, 0.0), [box], **kwargs
            )
        )
        decor = baker.NavObstacle(
            "decor", (1.0, 0.0, 0.45), (0.1, 0.5, 0.45), blocking=False
        )
        self.assertFalse(
            baker.segment_crosses_obstacles(
                (0.0, 0.0, 0.0), (2.0, 0.0, 0.0), [decor], **kwargs
            )
        )
        lip = baker.NavObstacle("lip", (1.0, 0.0, 0.15), (0.1, 0.5, 0.15))
        self.assertFalse(
            baker.segment_crosses_obstacles(
                (0.0, 0.0, 0.0), (2.0, 0.0, 0.0), [lip], **kwargs
            )
        )

    def test_obstacles_reject_non_finite_and_non_positive_data(self) -> None:
        baker = self.baker
        with self.assertRaisesRegex(baker.BakeError, "finite"):
            baker.NavObstacle("bad", (float("nan"), 0.0, 0.45), (0.3, 0.3, 0.45))
        with self.assertRaisesRegex(baker.BakeError, "finite"):
            baker.NavObstacle("bad", (0.0, 0.0, 0.0), (0.3, 0.3, float("inf")))
        with self.assertRaisesRegex(baker.BakeError, "half_extents"):
            baker.NavObstacle("bad", (0.0, 0.0, 0.0), (0.0, 0.3, 0.45))
        with self.assertRaisesRegex(baker.BakeError, "finite"):
            baker.NavObstacle(
                "bad", (0.0, 0.0, 0.0), (0.3, 0.3, 0.45), rotation_z=float("inf")
            )

    def test_prune_is_deterministic(self) -> None:
        baker = self.baker
        triangles = grid_floor(size=2.0, subdivisions=2) + l_shaped_floor()
        graph = baker.bake_nav_graph(triangles, max_slope_degrees=45.0, spacing=0.5)
        obstacle = baker.NavObstacle("box", (0.5, 0.5, 0.45), (0.3, 0.3, 0.45))
        kwargs = dict(agent_radius=0.2, agent_height=1.8, max_step_height=0.3)
        first = baker.prune_graph(graph, [obstacle], **kwargs)
        second = baker.prune_graph(graph, [obstacle], **kwargs)
        self.assertEqual(
            [(wp.id, wp.x, wp.y, wp.z) for wp in first.waypoints],
            [(wp.id, wp.x, wp.y, wp.z) for wp in second.waypoints],
        )
        self.assertEqual(first.routes, second.routes)

    def test_penetration_finder_reports_unpruned_violations(self) -> None:
        baker = self.baker
        graph = baker.bake_nav_graph(
            grid_floor(size=2.0, subdivisions=1), max_slope_degrees=45.0, spacing=1.0
        )
        obstacle = baker.NavObstacle("blocker", (1.5, 1.5, 0.45), (0.4, 0.4, 0.45))
        kwargs = dict(agent_radius=0.2, agent_height=1.8, max_step_height=0.3)
        findings = baker.find_graph_obstacle_penetrations(graph, [obstacle], **kwargs)
        self.assertTrue(any("wp.auto.3" in finding for finding in findings))
        self.assertTrue(any("crosses" in finding for finding in findings))
        pruned = baker.prune_graph(graph, [obstacle], **kwargs)
        self.assertEqual(
            baker.find_graph_obstacle_penetrations(pruned, [obstacle], **kwargs), []
        )

    def test_obstacle_from_gameplay_volume_matches_roundtrip_convention(self) -> None:
        baker = self.baker
        volume = {
            "id": "collision.worktop",
            "center": {"x": 1.35, "y": 0.45, "z": 0.55},
            "halfExtents": {"x": 0.35, "y": 0.45, "z": 0.35},
            "rotation": {"w": 1.0, "x": 0.0, "y": 0.0, "z": 0.0},
            "isBlocking": True,
        }
        obstacle = baker.obstacle_from_gameplay_volume(volume)
        self.assertEqual(obstacle.id, "collision.worktop")
        self.assertEqual(obstacle.center, (1.35, -0.55, 0.45))
        self.assertEqual(obstacle.half_extents, (0.35, 0.35, 0.45))
        self.assertTrue(obstacle.blocking)




class BakeNavigationPackageAcceptanceTests(unittest.TestCase):
    REPO_ROOT = Path(__file__).parents[3]
    ROUNDTRIP = (
        REPO_ROOT / "authoring/worlds/warm-kitchen-canary/roundtrip/world.json"
    )
    ORIGINAL = (
        REPO_ROOT / "apps/macos/Resources/Worlds/warm-kitchen-canary/world.json"
    )

    def setUp(self) -> None:
        self.baker = load_baker()

    def _generated_graph(self, path: Path):
        manifest = json.loads(path.read_text(encoding="utf-8"))
        obstacles = [
            self.baker.obstacle_from_gameplay_volume(volume)
            for volume in manifest["collisionVolumes"]
        ]
        waypoints = []
        for waypoint in manifest["waypoints"]:
            if not waypoint["id"].startswith("wp.auto"):
                continue
            position = waypoint["position"]
            px, py, pz = self.baker._gameplay_to_blender_position(
                (position["x"], position["y"], position["z"])
            )
            waypoints.append(self.baker.NavWaypoint(waypoint["id"], px, py, pz))
        waypoint_ids = {waypoint.id for waypoint in waypoints}
        routes = [
            (route["waypointIDs"][0], route["waypointIDs"][1])
            for route in manifest["routes"]
            if route["id"].startswith("route.auto")
            and route["waypointIDs"][0] in waypoint_ids
            and route["waypointIDs"][1] in waypoint_ids
        ]
        return self.baker.NavGraph(waypoints, routes), obstacles

    def test_roundtrip_package_generated_graph_has_zero_obstacle_penetrations(self) -> None:
        graph, obstacles = self._generated_graph(self.ROUNDTRIP)
        self.assertGreater(graph.waypoint_count, 0)
        # Obstacle pruning must have removed every node/edge that pierces a
        # blocker (the pre-fix graph contained worktop penetrations).
        findings = self.baker.find_graph_obstacle_penetrations(
            graph,
            obstacles,
            agent_radius=0.2,
            agent_height=1.8,
            max_step_height=0.3,
        )
        self.assertEqual(findings, [])

        # The automatic spawn link (a generated route) must not cross a
        # blocker either; it links wp.spawn to a surviving auto waypoint.
        manifest = json.loads(self.ROUNDTRIP.read_text(encoding="utf-8"))
        spawn_route = next(
            route
            for route in manifest["routes"]
            if route["id"] == "route.auto.spawn"
        )
        spawn = manifest["spawn"]["position"]
        spawn_point = self.baker._gameplay_to_blender_position(
            (spawn["x"], spawn["y"], spawn["z"])
        )
        nearest = next(
            waypoint
            for waypoint in manifest["waypoints"]
            if waypoint["id"] == spawn_route["waypointIDs"][1]
        )
        nearest_position = nearest["position"]
        nearest_point = self.baker._gameplay_to_blender_position(
            (
                nearest_position["x"],
                nearest_position["y"],
                nearest_position["z"],
            )
        )
        self.assertFalse(
            self.baker.segment_crosses_obstacles(
                spawn_point,
                nearest_point,
                obstacles,
                agent_radius=0.2,
                agent_height=1.8,
                max_step_height=0.3,
            )
        )

    def test_deployed_package_has_generated_graph_without_penetrations(self) -> None:
        graph, obstacles = self._generated_graph(self.ORIGINAL)
        self.assertEqual(graph.waypoint_count, 8)
        self.assertEqual(len(obstacles), 10)
        findings = self.baker.find_graph_obstacle_penetrations(
            graph,
            obstacles,
            agent_radius=0.2,
            agent_height=1.8,
            max_step_height=0.3,
        )
        self.assertEqual(findings, [])

    def test_auto_graph_and_anchor_links_reach_every_activity_entry(self) -> None:
        """Without any original manual route, the auto graph + generated
        anchor links must still route from spawn to every activity entry and
        every path segment must remain collision-clean."""
        baker = self.baker
        manifest = json.loads(self.ROUNDTRIP.read_text(encoding="utf-8"))
        obstacles = [
            baker.obstacle_from_gameplay_volume(volume)
            for volume in manifest["collisionVolumes"]
        ]
        waypoint_by_id = {wp["id"]: wp for wp in manifest["waypoints"]}
        auto_waypoint_ids = {
            wp["id"] for wp in manifest["waypoints"] if wp["id"].startswith("wp.auto")
        }
        manual_route_ids = {
            route["id"] for route in manifest["routes"]
            if not route["id"].startswith("route.auto")
        }
        self.assertTrue(manual_route_ids)  # the three authored canary routes
        auto_routes = [
            route for route in manifest["routes"]
            if route["id"].startswith("route.auto")
        ]
        self.assertTrue(auto_routes)

        adjacency: dict[str, set[str]] = {wid: set() for wid in waypoint_by_id}
        anchor_links: list[tuple[str, str]] = []
        for route in auto_routes:
            first, second = route["waypointIDs"]
            adjacency.setdefault(first, set()).add(second)
            adjacency.setdefault(second, set()).add(first)
            if first not in auto_waypoint_ids or second not in auto_waypoint_ids:
                anchor_links.append((first, second))

        # Every anchor link is collision-clean and within the guarded distance.
        for manual_id, generated_id in anchor_links:
            manual_position = waypoint_by_id[manual_id]["position"]
            generated_position = waypoint_by_id[generated_id]["position"]
            start = baker._gameplay_to_blender_position(
                (manual_position["x"], manual_position["y"], manual_position["z"])
            )
            end = baker._gameplay_to_blender_position(
                (generated_position["x"], generated_position["y"], generated_position["z"])
            )
            self.assertFalse(
                baker.segment_crosses_obstacles(
                    start,
                    end,
                    obstacles,
                    agent_radius=0.2,
                    agent_height=1.8,
                    max_step_height=0.3,
                ),
                f"anchor link {manual_id}->{generated_id} crosses a blocker",
            )
            self.assertLessEqual(
                math.dist(start, end),
                baker.spawn_link_max_distance(0.5, 0.2),
                f"anchor link {manual_id}->{generated_id} exceeds the guarded distance",
            )

        # Every auto node participates in an auto edge unless a manual anchor
        # links to it (no unlinked orphan auto nodes remain).
        incident = {endpoint for route in auto_routes for endpoint in route["waypointIDs"]}
        for waypoint in manifest["waypoints"]:
            if waypoint["id"].startswith("wp.auto") and waypoint["id"] not in incident:
                self.assertTrue(
                    any(
                        generated_id == waypoint["id"]
                        for _, generated_id in anchor_links
                    ),
                    f"orphan auto node {waypoint['id']} has no auto edge and no anchor link",
                )

        # BFS from spawn over the auto graph + anchor links only.
        reachable: set[str] = set()
        queue = ["wp.spawn"]
        while queue:
            current = queue.pop()
            if current in reachable:
                continue
            reachable.add(current)
            queue.extend(adjacency.get(current, set()) - reachable)
        entries = sorted({activity["entryWaypointID"] for activity in manifest["activities"]})
        self.assertEqual(
            entries,
            [
                "wp.center",
                "wp.chair",
                "wp.dining.table",
                "wp.kitchen.counter",
                "wp.spawn",
                "wp.speaker",
                "wp.window",
            ],
        )
        for entry in entries:
            self.assertIn(
                entry,
                reachable,
                f"activity entry {entry} unreachable from spawn through "
                "auto graph + anchor links",
            )




if __name__ == "__main__":
    unittest.main()
