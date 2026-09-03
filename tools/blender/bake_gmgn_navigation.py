#!/usr/bin/env python3
"""Bake a lightweight offline navigation graph from editable GMGN geometry.

This module is the navigation-baking slice of the GLB-to-GMGN compiler. It is
split into two layers so its deterministic contract can be tested without
Blender:

* Pure-Python layer (no ``bpy`` import at module level):
  - :func:`validate_triangle` rejects degenerate and non-finite triangles.
  - :func:`triangle_normal`, :func:`triangle_area` and
    :func:`triangle_upward_angle_degrees` describe triangle geometry.
  - :func:`is_walkable` applies a configurable maximum slope to upward-facing
    faces.
  - :func:`connected_regions` groups walkable triangles into connected regions
    through shared edges.
  - :func:`bake_nav_graph` turns world-space triangles into a sparse,
    deterministic waypoint/route graph whose density is bounded by ``spacing``
    instead of input triangle density.

* Blender layer (``main``): when run inside headless Blender 5.2 it opens
  ``--blend``, reads the visible world-space mesh geometry from
  ``GMGN_NAV_SOURCE``, removes only the baker's own previous markers
  (``gmgn.generated_by`` == ``navigation-baker-v1``), creates one waypoint
  empty per walkable grid cell in ``GMGN_WAYPOINTS``, creates one per-edge route
  marker in ``GMGN_ROUTES``, links every eligible manual waypoint (spawn keeps
  ``route.auto.spawn``; activity entry points and other manual markers get
  deterministic ``route.auto.anchor.<id>`` links) to the nearest generated
  point when reachable without crossing a blocker, drops generated nodes that
  end up with no auto edge unless a manual anchor links to them, records bake
  parameters as scene metadata, and saves the result to ``--output``.

The baked graph is the current lightweight offline path layer: waypoints sit on
the walkable surface at roughly ``--spacing`` intervals and edges follow the
walkable surface exactly, so turns and one-triangle corridors survive while a
dense input mesh never produces a dense graph. A Recast runtime adapter is a
later slice.

The baker never touches manual markers. Only objects carrying
``gmgn.generated_by = navigation-baker-v1`` are removed on re-bake, so running
the baker repeatedly over the same scene is deterministic and non-destructive.

CLI (after ``--`` so Blender leaves the arguments alone)::

    blender --background --python tools/blender/bake_gmgn_navigation.py -- \\
        --blend path/to/editable.blend \\
        --output path/to/editable.nav.blend \\
        --max-slope-degrees 45 \\
        --spacing 0.5 \\
        --agent-radius 0.2 \\
        --agent-height 1.8 \\
        --maximum-step-height 0.3 \\
        --arrival-radius 0.2

``--output`` defaults to ``<blend stem>.nav.blend`` next to the input. The bake
always writes a new file by default; overwriting an existing file or saving in
place requires ``--force`` (documented in ``tools/blender/README.md``).
"""

from __future__ import annotations

import argparse
import math
import os
import sys
from pathlib import Path
from typing import Any, Iterable

#: Mark placed on every object created by this baker; only these are cleared
#: on re-bake, so manual markers are always preserved.
GENERATED_BY = "navigation-baker-v1"

#: Version recorded in scene metadata (``gmgn.nav_baker_version``).
BAKER_VERSION = "1"

COLLECTION_NAV_SOURCE = "GMGN_NAV_SOURCE"
COLLECTION_COLLISION = "GMGN_COLLISION"
COLLECTION_WAYPOINTS = "GMGN_WAYPOINTS"
COLLECTION_ROUTES = "GMGN_ROUTES"

DEFAULT_MAX_SLOPE_DEGREES = 45.0
DEFAULT_SPACING = 0.5
DEFAULT_AGENT_RADIUS = 0.3
DEFAULT_AGENT_HEIGHT = 1.8
DEFAULT_MAX_STEP_HEIGHT = 0.3
DEFAULT_ARRIVAL_RADIUS = 0.2

#: The importer-owned spawn connects to the nearest generated waypoint when it
#: is within ``max(spacing * SPAWN_LINK_MAX_DISTANCE_FACTOR,
#: agent_radius * 2.0, 1.0)`` meters.
SPAWN_LINK_MAX_DISTANCE_FACTOR = 2.0

#: Squared triangle area below which a triangle is treated as degenerate.
_AREA_EPSILON = 1e-12

#: Vertex coordinates are quantized before they are used as shared-edge keys so
#: that identical grid-line clip points always compare equal.
_VERTEX_QUANTUM = 1e-6

#: Tolerance (degrees) so a face exactly at the configured maximum slope counts
#: as walkable despite floating-point round-off in the arc-cosine.
_SLOPE_EPSILON_DEGREES = 1e-9


class BakeError(ValueError):
    """Raised when geometry or parameters cannot produce a navigation graph."""


class NavWaypoint:
    """A generated waypoint in Blender/right-handed Z-up coordinates."""

    __slots__ = ("id", "x", "y", "z")

    def __init__(self, id: str, x: float, y: float, z: float) -> None:
        self.id = id
        self.x = x
        self.y = y
        self.z = z

    def __repr__(self) -> str:
        return f"NavWaypoint({self.id!r}, ({self.x}, {self.y}, {self.z}))"


class NavGraph:
    """Deterministic sparse graph of generated waypoints and route edges."""

    __slots__ = ("waypoints", "routes")

    def __init__(
        self,
        waypoints: Iterable[NavWaypoint],
        routes: Iterable[tuple[str, str]],
    ) -> None:
        self.waypoints = list(waypoints)
        self.routes = list(routes)

    @property
    def waypoint_count(self) -> int:
        return len(self.waypoints)

    @property
    def route_count(self) -> int:
        return len(self.routes)

    def __repr__(self) -> str:
        return (
            f"NavGraph(waypoints={self.waypoint_count}, routes={self.route_count})"
        )


# ---------------------------------------------------------------------------
# Pure geometry layer
# ---------------------------------------------------------------------------


def _finite(value: Any, name: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as error:
        raise BakeError(f"{name} must be numeric") from error
    if not math.isfinite(result):
        raise BakeError(f"{name} must be finite")
    return result


def _point(value: Any, name: str) -> tuple[float, float, float]:
    try:
        x, y, z = value
    except (TypeError, ValueError) as error:
        raise BakeError(f"{name} must be a 3-component point") from error
    return (
        _finite(x, f"{name}.x"),
        _finite(y, f"{name}.y"),
        _finite(z, f"{name}.z"),
    )


def validate_triangle(
    triangle: Any, index: int | None = None
) -> tuple[tuple[float, float, float], ...]:
    """Validate one triangle and return it as a tuple of three finite points.

    Raises :class:`BakeError` for non-finite coordinates, fewer than three
    vertices, or degenerate (zero-area/collinear) triangles.
    """

    name = "triangle" if index is None else f"triangle {index}"
    try:
        a, b, c = triangle
    except (TypeError, ValueError) as error:
        raise BakeError(f"{name} must have exactly 3 vertices") from error
    a = _point(a, f"{name}.vertex0")
    b = _point(b, f"{name}.vertex1")
    c = _point(c, f"{name}.vertex2")
    if _triangle_area_squared(a, b, c) <= _AREA_EPSILON:
        raise BakeError(f"{name} is degenerate (zero area)")
    return (a, b, c)


def _triangle_area_squared(
    a: tuple[float, float, float],
    b: tuple[float, float, float],
    c: tuple[float, float, float],
) -> float:
    abx = b[0] - a[0]
    aby = b[1] - a[1]
    abz = b[2] - a[2]
    acx = c[0] - a[0]
    acy = c[1] - a[1]
    acz = c[2] - a[2]
    nx = aby * acz - abz * acy
    ny = abz * acx - abx * acz
    nz = abx * acy - aby * acx
    return 0.25 * (nx * nx + ny * ny + nz * nz)


def triangle_normal(
    a: tuple[float, float, float],
    b: tuple[float, float, float],
    c: tuple[float, float, float],
) -> tuple[float, float, float]:
    """Return the geometric normal of a validated triangle."""
    return (
        (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]),
        (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2]),
        (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]),
    )


def triangle_area(
    a: tuple[float, float, float],
    b: tuple[float, float, float],
    c: tuple[float, float, float],
) -> float:
    """Return the area of a validated triangle."""
    normal = triangle_normal(a, b, c)
    return 0.5 * math.sqrt(normal[0] ** 2 + normal[1] ** 2 + normal[2] ** 2)


def triangle_upward_angle_degrees(
    a: tuple[float, float, float],
    b: tuple[float, float, float],
    c: tuple[float, float, float],
) -> float:
    """Return the angle of the face normal from +Z, in degrees.

    ``0`` is a perfectly horizontal upward-facing surface, ``90`` is vertical,
    and anything above ``90`` points downward.
    """

    normal = triangle_normal(a, b, c)
    length = math.sqrt(normal[0] ** 2 + normal[1] ** 2 + normal[2] ** 2)
    if length == 0.0:
        return 90.0
    cosine = max(-1.0, min(1.0, normal[2] / length))
    return math.degrees(math.acos(cosine))


def is_walkable(
    a: tuple[float, float, float],
    b: tuple[float, float, float],
    c: tuple[float, float, float],
    max_slope_degrees: float,
) -> bool:
    """True when an upward-facing triangle is not steeper than the maximum slope."""
    return (
        triangle_upward_angle_degrees(a, b, c)
        <= max_slope_degrees + _SLOPE_EPSILON_DEGREES
    )


def _quantize(value: tuple[float, float, float]) -> tuple[float, float, float]:
    quantum = _VERTEX_QUANTUM
    return (
        round(value[0] / quantum) * quantum,
        round(value[1] / quantum) * quantum,
        round(value[2] / quantum) * quantum,
    )


def _edge_key(
    p: tuple[float, float, float], q: tuple[float, float, float]
) -> tuple[tuple[float, float, float], tuple[float, float, float]]:
    return tuple(sorted((_quantize(p), _quantize(q))))


class _UnionFind:
    def __init__(self, count: int) -> None:
        self.parent = list(range(count))
        self.rank = [0] * count

    def find(self, index: int) -> int:
        root = index
        while self.parent[root] != root:
            root = self.parent[root]
        while self.parent[index] != root:
            self.parent[index], index = root, self.parent[index]
        return root

    def union(self, left: int, right: int) -> None:
        lroot = self.find(left)
        rroot = self.find(right)
        if lroot == rroot:
            return
        if self.rank[lroot] < self.rank[rroot]:
            lroot, rroot = rroot, lroot
        self.parent[rroot] = lroot
        if self.rank[lroot] == self.rank[rroot]:
            self.rank[lroot] += 1

    def components(self) -> list[list[int]]:
        grouped: dict[int, list[int]] = {}
        for index in range(len(self.parent)):
            grouped.setdefault(self.find(index), []).append(index)
        return [indices for _, indices in sorted(grouped.items(), key=lambda kv: kv[1][0])]


def _components_by_shared_edges(
    triangles: list[tuple[tuple[float, float, float], ...]]
) -> list[list[tuple[tuple[float, float, float], ...]]]:
    """Group triangles that are connected through shared edges, deterministically."""
    edge_map: dict[Any, list[int]] = {}
    for index, triangle in enumerate(triangles):
        for vertex_index in range(3):
            edge = _edge_key(triangle[vertex_index], triangle[(vertex_index + 1) % 3])
            edge_map.setdefault(edge, []).append(index)
    union_find = _UnionFind(len(triangles))
    for members in edge_map.values():
        for member in members[1:]:
            union_find.union(members[0], member)
    return [
        [triangles[index] for index in indices] for indices in union_find.components()
    ]


def connected_regions(
    triangles: Iterable[Any],
) -> list[list[tuple[tuple[float, float, float], ...]]]:
    """Split validated walkable triangles into connected regions via shared edges.

    Two triangles belong to the same region when they share a geometric edge
    (quantized to ``1e-6`` to absorb float noise). Regions are returned in
    deterministic order (by first triangle index).
    """

    validated = [validate_triangle(triangle, index) for index, triangle in enumerate(triangles)]
    if not validated:
        return []
    edge_map: dict[Any, list[int]] = {}
    for index, triangle in enumerate(validated):
        for vertex_index in range(3):
            edge = _edge_key(triangle[vertex_index], triangle[(vertex_index + 1) % 3])
            edge_map.setdefault(edge, []).append(index)
    union_find = _UnionFind(len(validated))
    for members in edge_map.values():
        for member in members[1:]:
            union_find.union(members[0], member)
    return [
        [validated[index] for index in indices] for indices in union_find.components()
    ]


def _centroid(
    triangle: tuple[tuple[float, float, float], ...]
) -> tuple[float, float, float]:
    return (
        (triangle[0][0] + triangle[1][0] + triangle[2][0]) / 3.0,
        (triangle[0][1] + triangle[1][1] + triangle[2][1]) / 3.0,
        (triangle[0][2] + triangle[1][2] + triangle[2][2]) / 3.0,
    )


def _centroid_sort_key(
    triangle: tuple[tuple[float, float, float], ...]
) -> tuple[tuple[float, float, float], tuple[tuple[float, float, float], ...]]:
    return (_centroid(triangle), triangle)


def _cell_index(coord: float, origin: float, spacing: float) -> int:
    return int(math.floor((coord - origin) / spacing))


def _clip_polygon_axis(
    polygon: list[tuple[float, float, float]],
    axis: int,
    threshold: float,
    keep_above: bool,
) -> list[tuple[float, float, float]]:
    """Sutherland-Hodgman clip against one axis-aligned line (in 3D)."""
    if not polygon:
        return []
    result: list[tuple[float, float, float]] = []
    count = len(polygon)
    for index in range(count):
        current = polygon[index]
        following = polygon[(index + 1) % count]
        current_inside = (
            current[axis] >= threshold if keep_above else current[axis] <= threshold
        )
        following_inside = (
            following[axis] >= threshold if keep_above else following[axis] <= threshold
        )
        if current_inside:
            result.append(current)
        if current_inside != following_inside:
            denominator = following[axis] - current[axis]
            fraction = (threshold - current[axis]) / denominator
            result.append(
                (
                    current[0] + fraction * (following[0] - current[0]),
                    current[1] + fraction * (following[1] - current[1]),
                    current[2] + fraction * (following[2] - current[2]),
                )
            )
    return result


def _clip_triangle_to_cell(
    triangle: tuple[tuple[float, float, float], ...],
    x0: float,
    y0: float,
    x1: float,
    y1: float,
) -> list[tuple[tuple[float, float, float], ...]]:
    """Clip a triangle to an axis-aligned cell and fan-triangulate the result."""
    polygon = _clip_polygon_axis(list(triangle), 0, x0, True)
    polygon = _clip_polygon_axis(polygon, 0, x1, False)
    polygon = _clip_polygon_axis(polygon, 1, y0, True)
    polygon = _clip_polygon_axis(polygon, 1, y1, False)
    if len(polygon) < 3:
        return []
    out: list[tuple[tuple[float, float, float], ...]] = []
    for index in range(1, len(polygon) - 1):
        piece = (polygon[0], polygon[index], polygon[index + 1])
        if _triangle_area_squared(*piece) > _AREA_EPSILON:
            out.append(piece)
    return out


def validate_bake_parameters(
    *,
    max_slope_degrees: float,
    spacing: float,
    agent_radius: float,
    arrival_radius: float,
    agent_height: float = DEFAULT_AGENT_HEIGHT,
    max_step_height: float = DEFAULT_MAX_STEP_HEIGHT,
) -> None:
    """Validate every CLI bake parameter and raise :class:`BakeError` on misuse."""
    if not math.isfinite(max_slope_degrees) or not (0.0 <= max_slope_degrees < 90.0):
        raise BakeError("max_slope_degrees must be finite and in [0, 90)")
    if not math.isfinite(spacing) or spacing <= 0.0:
        raise BakeError("spacing must be positive and finite")
    if not math.isfinite(agent_radius) or agent_radius <= 0.0:
        raise BakeError("agent_radius must be positive and finite")
    if not math.isfinite(agent_height) or agent_height <= 0.0:
        raise BakeError("agent_height must be positive and finite")
    if not math.isfinite(max_step_height) or max_step_height < 0.0:
        raise BakeError("max_step_height must be finite and non-negative")
    if not math.isfinite(arrival_radius) or arrival_radius <= 0.0:
        raise BakeError("arrival_radius must be positive and finite")


def bake_nav_graph(
    triangles: Iterable[Any],
    *,
    max_slope_degrees: float = DEFAULT_MAX_SLOPE_DEGREES,
    spacing: float = DEFAULT_SPACING,
) -> NavGraph:
    """Bake a sparse deterministic waypoint/route graph from world-space triangles.

    Triangles are validated (non-finite and degenerate input raises
    :class:`BakeError`), filtered to upward-facing faces within
    ``max_slope_degrees``, split into connected regions through shared edges, and
    then sampled onto a grid whose cell size is ``spacing``. One waypoint is
    emitted per connected walkable fragment inside each occupied cell, so the
    output density is bounded by ``spacing`` and never by input triangle
    density. Edges connect fragments that share a geometric edge, preserving
    turns and one-triangle corridors exactly.
    """

    validate_bake_parameters(
        max_slope_degrees=max_slope_degrees,
        spacing=spacing,
        agent_radius=DEFAULT_AGENT_RADIUS,
        agent_height=DEFAULT_AGENT_HEIGHT,
        max_step_height=DEFAULT_MAX_STEP_HEIGHT,
        arrival_radius=DEFAULT_ARRIVAL_RADIUS,
    )
    validated = [validate_triangle(triangle, index) for index, triangle in enumerate(triangles)]
    walkable = [
        triangle
        for triangle in validated
        if is_walkable(*triangle, max_slope_degrees)
    ]
    if not walkable:
        return NavGraph([], [])

    # Sort so the whole pipeline is independent of mesh iteration order.
    walkable.sort(key=_centroid_sort_key)
    regions = _connected_regions_validated(walkable)

    node_records: list[tuple[int, int, int, int, float, float, float]] = []
    edges: set[frozenset[tuple[int, int, int, int]]] = set()

    for region_index, region in enumerate(regions):
        min_x = min(vertex[0] for triangle in region for vertex in triangle)
        max_x = max(vertex[0] for triangle in region for vertex in triangle)
        min_y = min(vertex[1] for triangle in region for vertex in triangle)
        max_y = max(vertex[1] for triangle in region for vertex in triangle)

        cells: dict[tuple[int, int], list[Any]] = {}
        for triangle in region:
            tri_min_x = min(vertex[0] for vertex in triangle)
            tri_max_x = max(vertex[0] for vertex in triangle)
            tri_min_y = min(vertex[1] for vertex in triangle)
            tri_max_y = max(vertex[1] for vertex in triangle)
            ix_start = _cell_index(tri_min_x, min_x, spacing)
            ix_end = _cell_index(tri_max_x, min_x, spacing)
            iy_start = _cell_index(tri_min_y, min_y, spacing)
            iy_end = _cell_index(tri_max_y, min_y, spacing)
            for ix in range(ix_start, ix_end + 1):
                x0 = min_x + ix * spacing
                x1 = x0 + spacing
                for iy in range(iy_start, iy_end + 1):
                    y0 = min_y + iy * spacing
                    y1 = y0 + spacing
                    pieces = _clip_triangle_to_cell(triangle, x0, y0, x1, y1)
                    if pieces:
                        cells.setdefault((ix, iy), []).extend(pieces)

        # One node per connected fragment inside each occupied cell.
        node_of_piece: dict[int, tuple[int, int, int, int]] = {}
        for (ix, iy) in sorted(cells):
            pieces = cells[(ix, iy)]
            pieces.sort(key=_centroid_sort_key)
            components = _components_by_shared_edges(pieces)
            for component_index, component in enumerate(components):
                node = (region_index, ix, iy, component_index)
                cx = sum(_centroid(piece)[0] for piece in component) / len(component)
                cy = sum(_centroid(piece)[1] for piece in component) / len(component)
                cz = sum(_centroid(piece)[2] for piece in component) / len(component)
                node_records.append((*node, cx, cy, cz))
                for piece in component:
                    node_of_piece[id(piece)] = node

        # Edges follow the walkable surface: two fragments that share an edge
        # belong to the same surface, so connect their nodes.
        edge_nodes: dict[Any, set[tuple[int, int, int, int]]] = {}
        for pieces in cells.values():
            for piece in pieces:
                node = node_of_piece[id(piece)]
                for vertex_index in range(3):
                    edge = _edge_key(piece[vertex_index], piece[(vertex_index + 1) % 3])
                    edge_nodes.setdefault(edge, set()).add(node)
        for members in edge_nodes.values():
            ordered = sorted(members)
            for left, right in zip(ordered, ordered[1:]):
                edges.add(frozenset((left, right)))

    node_records.sort(key=lambda record: record[:4])
    waypoints: list[NavWaypoint] = []
    id_by_node: dict[tuple[int, int, int, int], str] = {}
    width = len(str(max(len(node_records) - 1, 0)))
    for index, (region, ix, iy, component, x, y, z) in enumerate(node_records):
        waypoint_id = f"wp.auto.{index:0{width}d}"
        waypoints.append(NavWaypoint(waypoint_id, x, y, z))
        id_by_node[(region, ix, iy, component)] = waypoint_id

    routes: list[tuple[str, str]] = []
    for pair in edges:
        left, right = sorted(pair)
        routes.append((id_by_node[left], id_by_node[right]))
    routes.sort(key=lambda route: (route[0], route[1]))

    return NavGraph(waypoints, routes)


def _connected_regions_validated(
    triangles: list[tuple[tuple[float, float, float], ...]],
) -> list[list[tuple[tuple[float, float, float], ...]]]:
    if not triangles:
        return []
    edge_map: dict[Any, list[int]] = {}
    for index, triangle in enumerate(triangles):
        for vertex_index in range(3):
            edge = _edge_key(triangle[vertex_index], triangle[(vertex_index + 1) % 3])
            edge_map.setdefault(edge, []).append(index)
    union_find = _UnionFind(len(triangles))
    for members in edge_map.values():
        for member in members[1:]:
            union_find.union(members[0], member)
    return [
        [triangles[index] for index in indices] for indices in union_find.components()
    ]


def nearest_waypoint(
    graph: NavGraph,
    point: tuple[float, float, float],
    *,
    max_distance: float | None = None,
) -> NavWaypoint | None:
    """Return the nearest generated waypoint to ``point``, optionally bounded."""
    best: NavWaypoint | None = None
    best_squared = float("inf")
    px, py, pz = point
    for waypoint in graph.waypoints:
        dx = waypoint.x - px
        dy = waypoint.y - py
        dz = waypoint.z - pz
        squared = dx * dx + dy * dy + dz * dz
        if squared < best_squared:
            best_squared = squared
            best = waypoint
    if best is None:
        return None
    if max_distance is not None and math.sqrt(best_squared) > max_distance:
        return None
    return best


def route_id(index: int, count: int) -> str:
    """Stable generated route id: ``route.auto.<zero-padded index>``."""
    width = len(str(max(count - 1, 0)))
    return f"route.auto.{index:0{width}d}"


def spawn_link_max_distance(spacing: float, agent_radius: float) -> float:
    """Distance within which a manual marker may connect to the graph."""
    return max(spacing * SPAWN_LINK_MAX_DISTANCE_FACTOR, agent_radius * 2.0, 1.0)


def anchor_link_route_id(manual_id: str) -> str:
    """Deterministic generated route id for a manual anchor link."""
    return f"route.auto.anchor.{manual_id}"


def anchor_links(
    graph: NavGraph,
    manual_waypoints: Iterable[tuple[str, tuple[float, float, float]]],
    obstacles: Iterable[NavObstacle],
    *,
    max_distance: float,
    agent_radius: float,
    agent_height: float,
    max_step_height: float,
) -> list[tuple[str, str]]:
    """Link every eligible manual waypoint to the nearest generated node.

    Returns deterministic ``(manual_id, generated_id)`` pairs sorted by manual
    id. A waypoint is eligible when a generated node exists within
    ``max_distance`` and the straight segment to it does not cross an active
    blocker. Manual markers are never deleted; ineligible waypoints simply get
    no link.
    """

    obstacles = list(obstacles)
    links: list[tuple[str, str]] = []
    seen: set[str] = set()
    for manual_id, point in sorted(manual_waypoints, key=lambda item: item[0]):
        if manual_id in seen:
            continue
        seen.add(manual_id)
        nearest = nearest_waypoint(graph, point, max_distance=max_distance)
        if nearest is None:
            continue
        if segment_crosses_obstacles(
            point,
            (nearest.x, nearest.y, nearest.z),
            obstacles,
            agent_radius=agent_radius,
            agent_height=agent_height,
            max_step_height=max_step_height,
        ):
            continue
        links.append((manual_id, nearest.id))
    return links


def remove_orphan_nodes(
    graph: NavGraph,
    linked_node_ids: Iterable[str] = (),
) -> NavGraph:
    """Drop generated waypoints that participate in no auto edge.

    A generated node that survives obstacle pruning but has no auto edge is
    unreachable through the graph, so it is removed unless it is linked to a
    manual anchor (``linked_node_ids``) - those stay so the anchor link has a
    target. Waypoint ids of surviving nodes are untouched, so re-bakes stay
    deterministic.
    """

    linked = set(linked_node_ids)
    incident: set[str] = set()
    for from_id, to_id in graph.routes:
        incident.add(from_id)
        incident.add(to_id)
    kept = [wp for wp in graph.waypoints if wp.id in incident or wp.id in linked]
    return NavGraph(kept, graph.routes)


# ---------------------------------------------------------------------------
# Pure obstacle layer
# ---------------------------------------------------------------------------

#: Tolerance (meters) absorbed when deciding whether a box rises above the
#: agent's step height or overlaps the capsule vertical interval, so exact
#: boundary contact is never misread as penetration.
_HEIGHT_EPSILON = 1e-6


class NavObstacle:
    """An oriented box blocker in Blender/right-handed Z-up world space.

    ``center`` is the world-space box center, ``half_extents`` the box half
    size along its own axes (half of the evaluated world dimensions), and
    ``rotation_z`` the yaw around +Z in radians. Horizontal half extents are
    expanded by the agent radius when queried, mirroring how a
    ``WorldCapsule`` of that radius is kept clear of the box in
    ``CollisionVolumeWorld``.
    """

    __slots__ = (
        "id",
        "center",
        "half_extents",
        "rotation_z",
        "blocking",
        "_cos",
        "_sin",
    )

    def __init__(
        self,
        id: str,
        center: Any,
        half_extents: Any,
        rotation_z: float = 0.0,
        blocking: bool = True,
    ) -> None:
        cx, cy, cz = _point(center, "obstacle center")
        hx, hy, hz = _point(half_extents, "obstacle half_extents")
        if hx <= 0.0 or hy <= 0.0 or hz <= 0.0:
            raise BakeError("obstacle half_extents must be positive")
        yaw = _finite(rotation_z, "obstacle rotation_z")
        self.id = str(id)
        self.center = (cx, cy, cz)
        self.half_extents = (hx, hy, hz)
        self.rotation_z = yaw
        self.blocking = bool(blocking)
        self._cos = math.cos(yaw)
        self._sin = math.sin(yaw)

    def __repr__(self) -> str:
        return (
            f"NavObstacle({self.id!r}, center={self.center}, "
            f"half={self.half_extents}, yaw={self.rotation_z:.4f})"
        )

    def to_local(self, point: Any) -> tuple[float, float]:
        """Project a world-space point into the box's local XY frame."""
        x, y, _z = _point(point, "obstacle query point")
        dx = x - self.center[0]
        dy = y - self.center[1]
        cosine = self._cos
        sine = self._sin
        return (dx * cosine + dy * sine, -dx * sine + dy * cosine)

    @property
    def min_z(self) -> float:
        return self.center[2] - self.half_extents[2]

    @property
    def max_z(self) -> float:
        return self.center[2] + self.half_extents[2]


def obstacle_blocks_ground(
    obstacle: NavObstacle,
    ground_z: float,
    *,
    agent_radius: float,
    agent_height: float,
    max_step_height: float,
) -> bool:
    """True when a blocking box obstructs a capsule standing on ``ground_z``.

    A box matters only when it is blocking, rises more than
    ``max_step_height`` above the ground (low lips and floor slabs are
    traversable), and its vertical extent overlaps the capsule vertical
    interval ``[ground_z + radius, ground_z + height - radius]``.
    """

    if not obstacle.blocking:
        return False
    top = obstacle.max_z
    if top - ground_z <= max_step_height + _HEIGHT_EPSILON:
        return False
    capsule_bottom = ground_z + agent_radius
    capsule_top = ground_z + agent_height - agent_radius
    if top < capsule_bottom - _HEIGHT_EPSILON:
        return False
    if obstacle.min_z > capsule_top + _HEIGHT_EPSILON:
        return False
    return True


def point_in_expanded_footprint(
    obstacle: NavObstacle, point: Any, agent_radius: float
) -> bool:
    """True when ``point`` lies inside the box footprint expanded by radius."""
    lx, ly = obstacle.to_local(point)
    hx, hy, _hz = obstacle.half_extents
    return abs(lx) <= hx + agent_radius and abs(ly) <= hy + agent_radius


def _segment_intersects_rectangle_2d(
    ax: float, ay: float, bx: float, by: float, hx: float, hy: float
) -> bool:
    """Liang-Barsky clip of the segment a->b against an axis-aligned rectangle."""
    dx = bx - ax
    dy = by - ay
    t0, t1 = 0.0, 1.0
    for p, q in (
        (-dx, ax + hx),
        (dx, hx - ax),
        (-dy, ay + hy),
        (dy, hy - ay),
    ):
        if p == 0.0:
            if q < 0.0:
                return False
            continue
        ratio = q / p
        if p < 0.0:
            if ratio > t1:
                return False
            if ratio > t0:
                t0 = ratio
        else:
            if ratio < t0:
                return False
            if ratio < t1:
                t1 = ratio
    return True


def segment_crosses_expanded_footprint(
    obstacle: NavObstacle,
    start: Any,
    end: Any,
    agent_radius: float,
) -> bool:
    """True when the ``start``->``end`` segment intersects the expanded box."""
    lx0, ly0 = obstacle.to_local(start)
    lx1, ly1 = obstacle.to_local(end)
    hx, hy, _hz = obstacle.half_extents
    return _segment_intersects_rectangle_2d(
        lx0, ly0, lx1, ly1, hx + agent_radius, hy + agent_radius
    )


def _waypoint_blocked_by_obstacles(
    waypoint: NavWaypoint,
    obstacles: Iterable[NavObstacle],
    *,
    agent_radius: float,
    agent_height: float,
    max_step_height: float,
) -> bool:
    point = (waypoint.x, waypoint.y, waypoint.z)
    for obstacle in obstacles:
        if obstacle_blocks_ground(
            obstacle,
            waypoint.z,
            agent_radius=agent_radius,
            agent_height=agent_height,
            max_step_height=max_step_height,
        ) and point_in_expanded_footprint(obstacle, point, agent_radius):
            return True
    return False


def _segment_blocked_by_obstacles(
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    obstacles: Iterable[NavObstacle],
    *,
    agent_radius: float,
    agent_height: float,
    max_step_height: float,
) -> bool:
    ground_z = min(start[2], end[2])
    for obstacle in obstacles:
        if obstacle_blocks_ground(
            obstacle,
            ground_z,
            agent_radius=agent_radius,
            agent_height=agent_height,
            max_step_height=max_step_height,
        ) and segment_crosses_expanded_footprint(obstacle, start, end, agent_radius):
            return True
    return False


def segment_crosses_obstacles(
    start: Any,
    end: Any,
    obstacles: Iterable[NavObstacle],
    *,
    agent_radius: float,
    agent_height: float,
    max_step_height: float,
) -> bool:
    """True when the ``start``->``end`` segment crosses any active blocker.

    Used to reject the automatic ``wp.spawn`` link when the straight segment to
    the nearest generated waypoint would walk through a blocker.
    """

    return _segment_blocked_by_obstacles(
        tuple(_point(start, "segment start")),
        tuple(_point(end, "segment end")),
        obstacles,
        agent_radius=agent_radius,
        agent_height=agent_height,
        max_step_height=max_step_height,
    )


def prune_graph(
    graph: NavGraph,
    obstacles: Iterable[NavObstacle],
    *,
    agent_radius: float,
    agent_height: float,
    max_step_height: float,
) -> NavGraph:
    """Remove generated nodes inside active blockers and edges crossing them.

    Nodes whose center lies inside any active blocker's footprint expanded by
    ``agent_radius`` are dropped, and generated edges whose segment crosses an
    active blocker footprint are dropped too. Manual markers are never touched
    because they are not part of ``graph`` (only generated waypoints and edges
    are passed in). Surviving waypoint ids stay stable, so re-bakes remain
    deterministic.
    """

    obstacles = list(obstacles)
    kept: list[NavWaypoint] = []
    removed: set[str] = set()
    for waypoint in graph.waypoints:
        if _waypoint_blocked_by_obstacles(
            waypoint,
            obstacles,
            agent_radius=agent_radius,
            agent_height=agent_height,
            max_step_height=max_step_height,
        ):
            removed.add(waypoint.id)
        else:
            kept.append(waypoint)
    kept_by_id = {waypoint.id: waypoint for waypoint in kept}
    routes: list[tuple[str, str]] = []
    for from_id, to_id in graph.routes:
        if from_id in removed or to_id in removed:
            continue
        start = kept_by_id[from_id]
        end = kept_by_id[to_id]
        if _segment_blocked_by_obstacles(
            (start.x, start.y, start.z),
            (end.x, end.y, end.z),
            obstacles,
            agent_radius=agent_radius,
            agent_height=agent_height,
            max_step_height=max_step_height,
        ):
            continue
        routes.append((from_id, to_id))
    return NavGraph(kept, routes)


def find_graph_obstacle_penetrations(
    graph: NavGraph,
    obstacles: Iterable[NavObstacle],
    *,
    agent_radius: float,
    agent_height: float,
    max_step_height: float,
) -> list[str]:
    """Return findings for generated waypoints/edges that pierce blockers.

    This is the acceptance gate for baked packages: every generated waypoint
    must sit outside every active blocker's radius-expanded footprint and every
    generated edge must avoid crossing one.
    """

    obstacles = list(obstacles)
    findings: list[str] = []
    for waypoint in graph.waypoints:
        for obstacle in obstacles:
            if obstacle_blocks_ground(
                obstacle,
                waypoint.z,
                agent_radius=agent_radius,
                agent_height=agent_height,
                max_step_height=max_step_height,
            ) and point_in_expanded_footprint(
                obstacle, (waypoint.x, waypoint.y, waypoint.z), agent_radius
            ):
                findings.append(
                    f"generated waypoint {waypoint.id} lies inside {obstacle.id} "
                    "expanded by agent radius"
                )
                break
    for from_id, to_id in graph.routes:
        start = next(wp for wp in graph.waypoints if wp.id == from_id)
        end = next(wp for wp in graph.waypoints if wp.id == to_id)
        if _segment_blocked_by_obstacles(
            (start.x, start.y, start.z),
            (end.x, end.y, end.z),
            obstacles,
            agent_radius=agent_radius,
            agent_height=agent_height,
            max_step_height=max_step_height,
        ):
            findings.append(
                f"generated edge {from_id}->{to_id} crosses an active blocker"
            )
    return findings


def _volume_vector(value: Any, name: str) -> tuple[float, float, float]:
    if not isinstance(value, dict):
        raise BakeError(f"{name} must be an object")
    return (
        _finite(value.get("x"), f"{name}.x"),
        _finite(value.get("y"), f"{name}.y"),
        _finite(value.get("z"), f"{name}.z"),
    )


def _gameplay_to_blender_position(
    position: Any,
) -> tuple[float, float, float]:
    """Convert gameplay Y-up (x, y, z) to Blender Z-up (x, -z, y)."""
    x, y, z = position
    return (x, -z, y)


def _gameplay_to_blender_half_extents(
    half: Any,
) -> tuple[float, float, float]:
    """Map gameplay half extents (hx, hy, hz) to Blender (hx, hz, hy)."""
    hx, hy, hz = half
    return (hx, hz, hy)


def obstacle_from_gameplay_volume(volume: dict[str, Any]) -> NavObstacle:
    """Build a :class:`NavObstacle` from a manifest collision volume (Y-up).

    This is the exact inverse of ``export_gmgn_world``'s ``_collision``: the
    center and half extents are mapped back to Blender Z-up and the exported
    yaw/pitch quaternion is reduced to its yaw.
    """

    center = _volume_vector(volume.get("center", {}), "collision volume center")
    half = _volume_vector(
        volume.get("halfExtents", {}), "collision volume halfExtents"
    )
    rotation = volume.get("rotation", {})
    w = _finite(rotation.get("w", 1.0), "collision volume rotation.w")
    y = _finite(rotation.get("y", 0.0), "collision volume rotation.y")
    yaw = 2.0 * math.atan2(y, w)
    blocking = _bool_optional(
        volume.get("isBlocking", True), "collision volume isBlocking"
    )
    return NavObstacle(
        str(volume["id"]),
        _gameplay_to_blender_position(center),
        _gameplay_to_blender_half_extents(half),
        rotation_z=yaw,
        blocking=blocking,
    )


def _bool_optional(value: Any, name: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in ("true", "1", "yes"):
            return True
        if normalized in ("false", "0", "no"):
            return False
    raise BakeError(f"{name} must be a boolean")



# ---------------------------------------------------------------------------
# Blender layer
# ---------------------------------------------------------------------------


def read_nav_source_triangles(bpy: Any) -> list[tuple[Any, ...]]:
    """Read visible world-space triangles from the ``GMGN_NAV_SOURCE`` collection."""
    collection = bpy.data.collections.get(COLLECTION_NAV_SOURCE)
    if collection is None:
        raise BakeError(
            f"missing {COLLECTION_NAV_SOURCE} collection; not a GMGN editable world"
        )
    triangles: list[tuple[Any, ...]] = []
    for obj in collection.objects:
        if obj.type != "MESH":
            continue
        try:
            visible = obj.visible_get()
        except Exception:  # noqa: BLE001 - background headless fallback
            visible = not obj.hide_viewport and not collection.hide_viewport
        if not visible:
            continue
        matrix = obj.matrix_world
        mesh = obj.data
        positions = [(matrix @ vertex.co) for vertex in mesh.vertices]
        triangles.extend(_mesh_world_triangles(mesh, positions))
    return triangles


def read_blocking_obstacles(bpy: Any) -> list[NavObstacle]:
    """Read evaluated world-space oriented boxes from ``GMGN_COLLISION``.

    Only objects whose ``gmgn.blocking`` property is exactly ``True`` are read.
    Box half extents come from the evaluated world dimensions, the center from
    the evaluated world transform, and the yaw from the evaluated world
    rotation (Blender Z-up). Non-finite or non-positive obstacle data raises
    :class:`BakeError`.
    """

    collection = bpy.data.collections.get(COLLECTION_COLLISION)
    if collection is None:
        return []
    obstacles: list[NavObstacle] = []
    for obj in collection.objects:
        if obj.get("gmgn.blocking") is not True:
            continue
        matrix = obj.matrix_world
        translation = matrix.translation
        dimensions = obj.dimensions
        yaw = matrix.to_euler("XYZ").z
        obstacles.append(
            NavObstacle(
                str(obj.get("gmgn.id") or obj.name),
                (translation.x, translation.y, translation.z),
                (dimensions.x * 0.5, dimensions.y * 0.5, dimensions.z * 0.5),
                rotation_z=float(yaw),
            )
        )
    return obstacles



def _mesh_world_triangles(mesh: Any, positions: list[Any]) -> list[tuple[Any, ...]]:
    """Triangulate a Blender mesh into world-space coordinate triples."""
    out: list[tuple[Any, ...]] = []
    if hasattr(mesh, "calc_loop_triangles"):
        try:
            mesh.calc_loop_triangles()
            for loop_triangle in mesh.loop_triangles:
                indices = loop_triangle.vertices
                if len(indices) != 3:
                    continue
                out.append(
                    tuple(
                        (positions[index].x, positions[index].y, positions[index].z)
                        for index in indices
                    )
                )
            return out
        except Exception:  # noqa: BLE001 - fall back to fan triangulation
            pass
    for polygon in mesh.polygons:
        vertices = [positions[index] for index in polygon.vertices]
        if len(vertices) < 3:
            continue
        for index in range(1, len(vertices) - 1):
            out.append(
                (
                    (vertices[0].x, vertices[0].y, vertices[0].z),
                    (vertices[index].x, vertices[index].y, vertices[index].z),
                    (vertices[index + 1].x, vertices[index + 1].y, vertices[index + 1].z),
                )
            )
    return out


def _ensure_collection(bpy: Any, name: str) -> Any:
    collection = bpy.data.collections.get(name)
    if collection is None:
        collection = bpy.data.collections.new(name)
        bpy.context.scene.collection.children.link(collection)
    return collection


def _remove_generated_objects(bpy: Any, *collection_names: str) -> None:
    for name in collection_names:
        collection = bpy.data.collections.get(name)
        if collection is None:
            continue
        for obj in list(collection.objects):
            if obj.get("gmgn.generated_by") == GENERATED_BY:
                bpy.data.objects.remove(obj, do_unlink=True)


def _find_spawn(bpy: Any, waypoints_collection: Any) -> Any | None:
    for obj in waypoints_collection.objects:
        if obj.get("gmgn.spawn") is True:
            return obj
    return None


def _mark(empty: Any, **properties: Any) -> None:
    empty["gmgn.generated_by"] = GENERATED_BY
    for key, value in properties.items():
        empty[key] = value


def apply_graph(
    bpy: Any,
    graph: NavGraph,
    *,
    arrival_radius: float,
    agent_radius: float,
    agent_height: float,
    max_step_height: float,
    max_slope_degrees: float,
    spacing: float,
    obstacles: Iterable[NavObstacle] = (),
) -> int:
    """Create/refresh generated waypoints and routes in the current scene.

    Only objects marked ``gmgn.generated_by == navigation-baker-v1`` are
    removed, so manual markers always survive. Every eligible manual waypoint
    (importer-owned markers and author-added ones, including activity entry
    points) is linked to the nearest generated node within the guarded
    distance when the straight segment does not cross an active blocker; the
    spawn keeps its stable ``route.auto.spawn`` id while other manual
    waypoints get deterministic ``route.auto.anchor.<id>`` ids. Generated
    nodes with no auto edge are dropped unless a manual anchor links to them.
    Returns the total number of route markers created (graph edges plus the
    manual anchor links).
    """

    waypoints_collection = _ensure_collection(bpy, COLLECTION_WAYPOINTS)
    routes_collection = _ensure_collection(bpy, COLLECTION_ROUTES)
    _remove_generated_objects(bpy, COLLECTION_WAYPOINTS, COLLECTION_ROUTES)

    manual_waypoints: list[tuple[str, tuple[float, float, float]]] = sorted(
        (
            (
                str(obj.get("gmgn.id") or obj.name),
                (obj.location.x, obj.location.y, obj.location.z),
            )
            for obj in waypoints_collection.objects
            if obj.get("gmgn.generated_by") != GENERATED_BY
        ),
        key=lambda item: item[0],
    )
    links = anchor_links(
        graph,
        manual_waypoints,
        obstacles,
        max_distance=spawn_link_max_distance(spacing, agent_radius),
        agent_radius=agent_radius,
        agent_height=agent_height,
        max_step_height=max_step_height,
    )
    graph = remove_orphan_nodes(graph, [target for _, target in links])

    for waypoint in graph.waypoints:
        empty = bpy.data.objects.new(waypoint.id, None)
        empty.location = (waypoint.x, waypoint.y, waypoint.z)
        _mark(
            empty,
            **{
                "gmgn.id": waypoint.id,
                "gmgn.arrival_radius": float(arrival_radius),
                "gmgn.enabled": True,
            },
        )
        waypoints_collection.objects.link(empty)

    route_count = len(graph.routes)
    for index, (from_id, to_id) in enumerate(graph.routes):
        route_id_value = route_id(index, route_count)
        empty = bpy.data.objects.new(route_id_value, None)
        _mark(
            empty,
            **{
                "gmgn.id": route_id_value,
                "gmgn.waypoints": [from_id, to_id],
                "gmgn.bidirectional": True,
                "gmgn.enabled": True,
            },
        )
        routes_collection.objects.link(empty)

    spawn = _find_spawn(bpy, waypoints_collection)
    spawn_id = str(spawn["gmgn.id"]) if spawn is not None else None
    for manual_id, target_id in links:
        if manual_id == spawn_id:
            route_id_value = "route.auto.spawn"
        else:
            route_id_value = anchor_link_route_id(manual_id)
        empty = bpy.data.objects.new(route_id_value, None)
        _mark(
            empty,
            **{
                "gmgn.id": route_id_value,
                "gmgn.waypoints": [manual_id, target_id],
                "gmgn.bidirectional": True,
                "gmgn.enabled": True,
            },
        )
        routes_collection.objects.link(empty)
        route_count += 1

    scene = bpy.context.scene
    scene["gmgn.nav_baker_version"] = BAKER_VERSION
    scene["gmgn.nav_max_slope_degrees"] = float(max_slope_degrees)
    scene["gmgn.nav_spacing"] = float(spacing)
    scene["gmgn.nav_agent_radius"] = float(agent_radius)
    scene["gmgn.nav_agent_height"] = float(agent_height)
    scene["gmgn.nav_max_step_height"] = float(max_step_height)
    scene["gmgn.nav_arrival_radius"] = float(arrival_radius)
    scene["gmgn.nav_waypoint_count"] = graph.waypoint_count
    scene["gmgn.nav_route_count"] = route_count
    return route_count


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _arguments_after_double_dash(arguments: list[str]) -> list[str]:
    if "--" in arguments:
        return arguments[arguments.index("--") + 1 :]
    if arguments and not arguments[0].startswith("-"):
        # Plain interpreter invocation: drop the script path.
        return arguments[1:]
    return arguments


def _parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="bake_gmgn_navigation.py",
        description=(
            "Bake a sparse offline waypoint/route graph from editable "
            "GMGN_NAV_SOURCE geometry and save it to a new .blend."
        ),
    )
    parser.add_argument("--blend", required=True, help="editable GMGN .blend to read")
    parser.add_argument(
        "--output",
        default=None,
        help=".blend to write (default: <blend stem>.nav.blend next to the input)",
    )
    parser.add_argument("--max-slope-degrees", type=float, default=DEFAULT_MAX_SLOPE_DEGREES)
    parser.add_argument("--spacing", type=float, default=DEFAULT_SPACING)
    parser.add_argument("--agent-radius", type=float, default=DEFAULT_AGENT_RADIUS)
    parser.add_argument(
        "--agent-height", type=float, default=DEFAULT_AGENT_HEIGHT,
        help="agent capsule height in meters (default %(default)s)",
    )
    parser.add_argument(
        "--maximum-step-height", type=float, default=DEFAULT_MAX_STEP_HEIGHT,
        help="maximum riser height a capsule may step over (default %(default)s)",
    )
    parser.add_argument("--arrival-radius", type=float, default=DEFAULT_ARRIVAL_RADIUS)
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite an existing output or save in place",
    )
    return parser.parse_args(arguments)


def default_output_path(blend_path: Path) -> Path:
    return blend_path.with_name(f"{blend_path.stem}.nav.blend")


def check_output_policy(blend_path: Path, output_path: Path, force: bool) -> str | None:
    """Return an error message when a destructive save is not confirmed."""
    if output_path.absolute() == blend_path.absolute():
        if not force:
            return (
                "in-place save would replace the source blend; "
                "pass --force to confirm deliberate in-place use"
            )
        return None
    if output_path.exists() and not force:
        return f"output already exists: {output_path}; pass --force to overwrite"
    return None


def main(arguments: list[str] | None = None) -> int:
    args = _parse_args(_arguments_after_double_dash(arguments or sys.argv))

    blend_path = Path(args.blend)
    if not blend_path.is_file():
        print(f"ERROR input blend does not exist: {blend_path}", file=sys.stderr)
        return 1
    output_path = (
        Path(args.output) if args.output else default_output_path(blend_path)
    )
    policy_error = check_output_policy(blend_path, output_path, args.force)
    if policy_error:
        print(f"ERROR {policy_error}", file=sys.stderr)
        return 1

    try:
        validate_bake_parameters(
            max_slope_degrees=args.max_slope_degrees,
            spacing=args.spacing,
            agent_radius=args.agent_radius,
            agent_height=args.agent_height,
            max_step_height=args.maximum_step_height,
            arrival_radius=args.arrival_radius,
        )
    except BakeError as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1

    try:
        import bpy  # type: ignore
    except ImportError:
        print("ERROR this command must run inside Blender", file=sys.stderr)
        return 2

    try:
        bpy.ops.wm.open_mainfile(filepath=str(blend_path))
        triangles = read_nav_source_triangles(bpy)
        obstacles = read_blocking_obstacles(bpy)
        graph = bake_nav_graph(
            triangles,
            max_slope_degrees=args.max_slope_degrees,
            spacing=args.spacing,
        )
        graph = prune_graph(
            graph,
            obstacles,
            agent_radius=args.agent_radius,
            agent_height=args.agent_height,
            max_step_height=args.maximum_step_height,
        )
        route_count = apply_graph(
            bpy,
            graph,
            arrival_radius=args.arrival_radius,
            agent_radius=args.agent_radius,
            agent_height=args.agent_height,
            max_step_height=args.maximum_step_height,
            max_slope_degrees=args.max_slope_degrees,
            spacing=args.spacing,
            obstacles=obstacles,
        )
        output_path.parent.mkdir(parents=True, exist_ok=True)
        bpy.ops.wm.save_as_mainfile(filepath=str(output_path))
        # apply_graph may drop orphan generated nodes, so report the final
        # waypoint count recorded on the scene rather than the pre-prune graph.
        waypoint_count = int(bpy.context.scene["gmgn.nav_waypoint_count"])
    except (BakeError, OSError) as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1

    print(
        f"BAKED {waypoint_count} waypoint(s), {route_count} route(s) "
        f"from {args.blend} -> {output_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
