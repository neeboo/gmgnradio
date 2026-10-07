//! Engine-independent port of WorldRuntime's planar footprint and clearance rules.
//! Coordinates retain the Swift right-handed convention; Unity must convert at its boundary.
use serde::{Deserialize, Serialize};
mod capsule;
pub(crate) mod geometry_wire;
pub use capsule::capsule_can_occupy;

type V = [f32; 3];
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Column {
    pub x: i32,
    pub z: i32,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Layer {
    pub column: Column,
    pub layer: i32,
    pub support_height: f32,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Grid {
    pub spacing: f32,
    /// Inclusive column ranges, exactly as the already-derived Swift grid.
    pub minimum: Column,
    pub maximum: Column,
    pub layers: Vec<Layer>,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
pub struct Footprint {
    pub size: [f32; 2],
    pub yaw: f32,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BoxVolume {
    pub center: V,
    pub half_extents: V,
    pub yaw: f32,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "shape", rename_all = "camelCase")]
pub enum Obstacle {
    Box {
        id: String,
        volume: BoxVolume,
    },
    /// World-space proxy triangles, not an AABB substitute. Empty proxy is invalid.
    Mesh {
        id: String,
        #[serde(deserialize_with = "geometry_wire::deserialize_triangles")]
        triangles: Vec<[V; 3]>,
        #[serde(default, rename = "isClosed")]
        is_closed: bool,
    },
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EvaluateRequest {
    pub grid: Grid,
    pub anchor: Layer,
    pub footprint: Footprint,
    pub height: f32,
    /// Local geometry query result. Missing geometry rejects rather than allowing placement.
    #[serde(deserialize_with = "geometry_wire::deserialize_triangles")]
    pub triangles: Vec<[V; 3]>,
    #[serde(default)]
    pub blocking_volumes: Vec<Obstacle>,
    #[serde(default)]
    pub placed_obstacles: Vec<Obstacle>,
    #[serde(default = "default_tolerance")]
    pub resting_tolerance: f32,
    #[serde(default = "default_tolerance")]
    /// Compatibility wire name: near-resting-plane contact band only.
    /// Adjacent floor sample heights have no rejection threshold.
    pub support_height_deviation: f32,
}
fn default_tolerance() -> f32 {
    0.02
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(tag = "code", content = "id", rename_all = "camelCase")]
pub enum BlockReason {
    OutsideBounds,
    NoSupport,
    BlockedByMesh,
    BlockedByBlockingVolume(String),
    BlockedByPlacedProp(String),
    InsufficientClearance,
    UnmodelledPlacedProp(String),
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EvaluateResult {
    pub can_place: bool,
    pub reason: Option<BlockReason>,
    pub columns: Vec<Column>,
    pub volume: Option<BoxVolume>,
}
fn dot(a: V, b: V) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn sub(a: V, b: V) -> V {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn cross(a: V, b: V) -> V {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn valid_box(b: &BoxVolume) -> bool {
    b.center.iter().all(|x| x.is_finite())
        && b.half_extents.iter().all(|x| x.is_finite() && *x > 0.)
        && b.yaw.is_finite()
}
impl Footprint {
    pub fn valid(&self) -> bool {
        self.size.iter().all(|x| x.is_finite() && *x > 0.) && self.yaw.is_finite()
    }
    pub fn center(&self, a: Column, s: f32) -> [f32; 2] {
        let (sin, cos) = self.yaw.sin_cos();
        [
            a.x as f32 * s + cos * self.size[0] / 2. + sin * self.size[1] / 2.,
            a.z as f32 * s - sin * self.size[0] / 2. + cos * self.size[1] / 2.,
        ]
    }
    pub fn columns(&self, a: Column, s: f32) -> Vec<Column> {
        if !self.valid() || !s.is_finite() || s <= 0. {
            return vec![];
        }
        let p = self.center(a, s);
        let (sin, cos) = self.yaw.sin_cos();
        let h = [
            cos.abs() * self.size[0] / 2. + sin.abs() * self.size[1] / 2.,
            sin.abs() * self.size[0] / 2. + cos.abs() * self.size[1] / 2.,
        ];
        let lo = [((p[0] - h[0]) / s).floor(), ((p[1] - h[1]) / s).floor()];
        let hi = [((p[0] + h[0]) / s).floor(), ((p[1] + h[1]) / s).floor()];
        if lo
            .iter()
            .chain(hi.iter())
            .any(|v| !v.is_finite() || *v < i32::MIN as f32 || *v >= i32::MAX as f32)
            || (hi[0] - lo[0] + 1.) as f64 * (hi[1] - lo[1] + 1.) as f64 > 4096.
        {
            return vec![];
        }
        let u = [cos, -sin];
        let v = [sin, cos];
        let axes = [u, v, [1., 0.], [0., 1.]];
        let mut out = vec![];
        for x in lo[0] as i32..=hi[0] as i32 {
            for z in lo[1] as i32..=hi[1] as i32 {
                let d = [(x as f32 + 0.5) * s - p[0], (z as f32 + 0.5) * s - p[1]];
                let separated = axes.iter().any(|a| {
                    let r = self.size[0] / 2. * (u[0] * a[0] + u[1] * a[1]).abs()
                        + self.size[1] / 2. * (v[0] * a[0] + v[1] * a[1]).abs()
                        + s / 2. * (a[0].abs() + a[1].abs());
                    (d[0] * a[0] + d[1] * a[1]).abs() >= r - 0.0001
                });
                if !separated {
                    out.push(Column { x, z })
                }
            }
        }
        out
    }
}
/// Exact 13-axis triangle/box SAT, including support contact exception from Swift.
fn mesh_clear(b: &BoxVolume, support: f32, triangles: &[[V; 3]], tolerance: f32) -> bool {
    if !valid_box(b) || !support.is_finite() || !tolerance.is_finite() || tolerance < 0. {
        return false;
    }
    let (s, c) = b.yaw.sin_cos();
    let h = b.half_extents;
    let ex = c.abs() * h[0] + s.abs() * h[2];
    let ez = s.abs() * h[0] + c.abs() * h[2];
    let basis = [[1., 0., 0.], [0., 1., 0.], [0., 0., 1.]];
    for t in triangles {
        if t.iter().flatten().any(|v| !v.is_finite()) {
            return false;
        }
        let min = std::array::from_fn::<_, 3, _>(|i| {
            t.iter().map(|p| p[i]).fold(f32::INFINITY, f32::min)
        });
        let max = std::array::from_fn::<_, 3, _>(|i| {
            t.iter().map(|p| p[i]).fold(f32::NEG_INFINITY, f32::max)
        });
        if max[1] <= support + tolerance
            || min[1] >= b.center[1] + h[1]
            || max[1] <= b.center[1] - h[1]
            || max[0] < b.center[0] - ex
            || min[0] > b.center[0] + ex
            || max[2] < b.center[2] - ez
            || min[2] > b.center[2] + ez
        {
            continue;
        }
        let p = t.map(|v| {
            let d = sub(v, b.center);
            [c * d[0] - s * d[2], d[1], s * d[0] + c * d[2]]
        });
        let e = [sub(p[1], p[0]), sub(p[2], p[1]), sub(p[0], p[2])];
        let mut axes = basis.to_vec();
        axes.push(cross(e[0], e[1]));
        for edge in e {
            for axis in basis {
                axes.push(cross(edge, axis))
            }
        }
        let separated = axes.iter().any(|axis| {
            let len = dot(*axis, *axis).sqrt();
            if len < 0.0000001 {
                return false;
            }
            let a = axis.map(|v| v / len);
            let r = h[0] * a[0].abs() + h[1] * a[1].abs() + h[2] * a[2].abs();
            let min = p.iter().map(|v| dot(*v, a)).fold(f32::INFINITY, f32::min);
            let max = p
                .iter()
                .map(|v| dot(*v, a))
                .fold(f32::NEG_INFINITY, f32::max);
            min >= r - 0.000001 || max <= -r + 0.000001
        });
        if !separated {
            return false;
        }
    }
    true
}
fn boxes_overlap(a: &BoxVolume, b: &BoxVolume) -> bool {
    if !valid_box(a) || !valid_box(b) {
        return true;
    }
    let axes_for = |yaw: f32| {
        let (s, c) = yaw.sin_cos();
        [[c, 0., -s], [s, 0., c]]
    };
    let au = axes_for(a.yaw);
    let bu = axes_for(b.yaw);
    let vertical = [0., 1., 0.];
    let radius = |b: &BoxVolume, u: [V; 2], axis: V| {
        b.half_extents[0] * dot(u[0], axis).abs()
            + b.half_extents[2] * dot(u[1], axis).abs()
            + b.half_extents[1] * dot(vertical, axis).abs()
    };
    ![au[0], au[1], bu[0], bu[1], vertical].iter().any(|axis| {
        dot(sub(b.center, a.center), *axis).abs()
            >= radius(a, au, *axis) + radius(b, bu, *axis) - 0.0001
    })
}
fn point_inside(point: V, triangles: &[[V; 3]]) -> bool {
    let direction = [1. / 59f32.sqrt(), 3. / 59f32.sqrt(), 7. / 59f32.sqrt()];
    let mut crossings = 0;
    for t in triangles {
        let e1 = sub(t[1], t[0]);
        let e2 = sub(t[2], t[0]);
        let p = cross(direction, e2);
        let determinant = dot(e1, p);
        if determinant.abs() <= 0.0000001 {
            continue;
        }
        let inverse = 1. / determinant;
        let offset = sub(point, t[0]);
        let u = dot(offset, p) * inverse;
        if !(0. ..=1.).contains(&u) {
            continue;
        }
        let q = cross(offset, e1);
        let v = dot(direction, q) * inverse;
        if v < 0. || u + v > 1. {
            continue;
        }
        if dot(e2, q) * inverse > 0. {
            crossings += 1
        }
    }
    crossings % 2 == 1
}
fn obstacle_hit(b: &BoxVolume, o: &Obstacle) -> bool {
    match o {
        Obstacle::Box { volume, .. } => boxes_overlap(b, volume),
        Obstacle::Mesh {
            triangles,
            is_closed,
            ..
        } => {
            let minimum = triangles
                .iter()
                .flatten()
                .map(|v| v[1])
                .fold(f32::INFINITY, f32::min);
            triangles.is_empty()
                || (*is_closed && point_inside(b.center, triangles))
                || !mesh_clear(b, minimum - 1., triangles, 0.)
        }
    }
}
fn obstacle_id(o: &Obstacle) -> String {
    match o {
        Obstacle::Box { id, .. } | Obstacle::Mesh { id, .. } => id.clone(),
    }
}
fn support_encloses_center(points: &mut Vec<[f32; 2]>, center: [f32; 2]) -> bool {
    fn turn(a: [f32; 2], b: [f32; 2], c: [f32; 2]) -> f32 {
        (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    }
    points.sort_by(|a, b| a[0].total_cmp(&b[0]).then(a[1].total_cmp(&b[1])));
    points.dedup();
    let mut hull = Vec::new();
    for &p in points.iter() {
        while hull.len() >= 2 && turn(hull[hull.len() - 2], hull[hull.len() - 1], p) <= 0. {
            hull.pop();
        }
        hull.push(p);
    }
    let lower_len = hull.len();
    for &p in points.iter().rev().skip(1) {
        while hull.len() > lower_len && turn(hull[hull.len() - 2], hull[hull.len() - 1], p) <= 0. {
            hull.pop();
        }
        hull.push(p);
    }
    hull.pop();
    hull.len() >= 3
        && (0..hull.len()).all(|i| turn(hull[i], hull[(i + 1) % hull.len()], center) > 0.0001)
}
pub fn evaluate(r: EvaluateRequest) -> EvaluateResult {
    let columns = r.footprint.columns(r.anchor.column, r.grid.spacing);
    let mut result = EvaluateResult {
        can_place: false,
        reason: None,
        columns,
        volume: None,
    };
    let reason = (|| {
        if !r.height.is_finite()
            || r.height <= 0.
            || !r.anchor.support_height.is_finite()
            || !r.support_height_deviation.is_finite()
            || r.support_height_deviation < 0.
            || result.columns.is_empty()
        {
            return Some(BlockReason::InsufficientClearance);
        }
        let center = r.footprint.center(r.anchor.column, r.grid.spacing);
        let b = BoxVolume {
            center: [
                center[0],
                r.anchor.support_height + r.height / 2.,
                center[1],
            ],
            half_extents: [
                r.footprint.size[0] / 2.,
                r.height / 2.,
                r.footprint.size[1] / 2.,
            ],
            yaw: r.footprint.yaw,
        };
        result.volume = Some(b.clone());
        let mut heights = Vec::new();
        for col in &result.columns {
            if col.x < r.grid.minimum.x
                || col.x > r.grid.maximum.x
                || col.z < r.grid.minimum.z
                || col.z > r.grid.maximum.z
            {
                return Some(BlockReason::OutsideBounds);
            }
            let layer = r.grid.layers.iter().find(|l| {
                l.column == *col && l.layer == r.anchor.layer && l.support_height.is_finite()
            });
            let Some(layer) = layer else {
                return Some(BlockReason::NoSupport);
            };
            heights.push((*col, layer.support_height));
        }
        let plane = heights
            .iter()
            .map(|(_, h)| *h)
            .fold(f32::NEG_INFINITY, f32::max);
        if (plane - r.anchor.support_height).abs() > 0.0001 {
            return Some(BlockReason::NoSupport);
        }
        let mut contacts = Vec::new();
        for (col, height) in &heights {
            // The wire field is the contact band, not an adjacent floor-height limit.
            if *height >= plane - r.support_height_deviation - 0.0001 {
                let x = col.x as f32 * r.grid.spacing;
                let z = col.z as f32 * r.grid.spacing;
                contacts.extend([
                    [x, z],
                    [x + r.grid.spacing, z],
                    [x, z + r.grid.spacing],
                    [x + r.grid.spacing, z + r.grid.spacing],
                ]);
            }
        }
        if !support_encloses_center(&mut contacts, center) {
            return Some(BlockReason::NoSupport);
        }
        if r.triangles.is_empty() {
            return Some(BlockReason::NoSupport);
        }
        if !mesh_clear(
            &b,
            r.anchor.support_height,
            &r.triangles,
            r.resting_tolerance,
        ) {
            return Some(BlockReason::BlockedByMesh);
        }
        for o in &r.blocking_volumes {
            if obstacle_hit(&b, o) {
                return Some(BlockReason::BlockedByBlockingVolume(obstacle_id(o)));
            }
        }
        for o in &r.placed_obstacles {
            if obstacle_hit(&b, o) {
                return Some(BlockReason::BlockedByPlacedProp(obstacle_id(o)));
            }
        }
        None
    })();
    result.can_place = reason.is_none();
    result.reason = reason;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> EvaluateRequest {
        let anchor = Layer {
            column: Column { x: 0, z: 0 },
            layer: 0,
            support_height: 0.,
        };
        EvaluateRequest {
            grid: Grid {
                spacing: 0.25,
                minimum: Column { x: -10, z: -10 },
                maximum: Column { x: 10, z: 10 },
                layers: (-10..=10)
                    .flat_map(|x| {
                        (-10..=10).map(move |z| Layer {
                            column: Column { x, z },
                            layer: 0,
                            support_height: 0.,
                        })
                    })
                    .collect(),
            },
            anchor,
            footprint: Footprint {
                size: [0.45, 0.45],
                yaw: 0.,
            },
            height: 1.,
            triangles: vec![[[-10., 0., -10.], [10., 0., -10.], [0., 0., 10.]]],
            blocking_volumes: vec![],
            placed_obstacles: vec![],
            resting_tolerance: 0.02,
            support_height_deviation: 0.02,
        }
    }
    #[test]
    fn minimum_corner_and_four_cells() {
        let r = request();
        assert_eq!(r.footprint.center(r.anchor.column, 0.25), [0.225, 0.225]);
        assert_eq!(
            evaluate(r).columns,
            vec![
                Column { x: 0, z: 0 },
                Column { x: 0, z: 1 },
                Column { x: 1, z: 0 },
                Column { x: 1, z: 1 }
            ]
        );
    }
    #[test]
    fn support_contact_and_missing_geometry() {
        assert!(evaluate(request()).can_place);
        let mut r = request();
        r.triangles.clear();
        assert_eq!(evaluate(r).reason, Some(BlockReason::NoSupport));
    }
    #[test]
    fn support_must_cover_every_cell() {
        let mut r = request();
        r.grid.layers.retain(|l| l.column != Column { x: 1, z: 1 });
        assert_eq!(evaluate(r).reason, Some(BlockReason::NoSupport));
    }
    fn uneven_request() -> EvaluateRequest {
        let mut r = request();
        r.footprint.size = [1.75, 1.75];
        for l in &mut r.grid.layers {
            let edge_distance = l
                .column
                .x
                .min(l.column.z)
                .min(6 - l.column.x)
                .min(6 - l.column.z);
            l.support_height = -(edge_distance.max(0) as f32 * 0.012).min(0.035);
        }
        r
    }
    #[test]
    fn smooth_recess_bridges_between_surrounding_contacts() {
        assert!(evaluate(uneven_request()).can_place);
    }
    #[test]
    fn one_sided_contacts_do_not_support_center() {
        let mut r = uneven_request();
        for l in &mut r.grid.layers {
            l.support_height = -(l.column.x.max(0) as f32 * 0.012).min(0.06);
        }
        assert_eq!(evaluate(r).reason, Some(BlockReason::NoSupport));
    }
    #[test]
    fn five_centimeter_step_is_not_continuous_floor() {
        let mut r = uneven_request();
        for l in &mut r.grid.layers {
            l.support_height = if l.column.x >= 3 { -0.05 } else { 0. };
        }
        assert_eq!(evaluate(r).reason, Some(BlockReason::NoSupport));
    }
    #[test]
    fn resting_plane_must_be_highest_covered_height() {
        let mut r = uneven_request();
        r.anchor.support_height = -0.012;
        assert_eq!(evaluate(r).reason, Some(BlockReason::NoSupport));
    }
    #[test]
    fn smooth_recess_still_rejects_wall() {
        let mut r = uneven_request();
        r.triangles
            .push([[0.8, 0., 0.], [0.8, 1., 0.], [0.8, 0., 2.]]);
        assert_eq!(evaluate(r).reason, Some(BlockReason::BlockedByMesh));
    }
    #[test]
    fn single_cell_contact_supports_small_footprint() {
        let mut r = request();
        r.footprint.size = [0.1, 0.1];
        assert!(evaluate(r).can_place);
    }
    #[test]
    fn contact_hull_boundary_is_not_stable_support() {
        let mut points = vec![[0., 0.], [1., 0.], [1., 1.], [0., 1.]];
        assert!(!support_encloses_center(&mut points, [0., 0.5]));
        assert!(support_encloses_center(&mut points, [0.5, 0.5]));
    }
    #[test]
    fn adjacent_height_difference_is_not_a_rejection_rule() {
        let mut r = request();
        r.grid
            .layers
            .iter_mut()
            .filter(|l| l.column.x == 1)
            .for_each(|l| l.support_height = -0.02005);
        assert!(evaluate(r).can_place);
        let mut r = request();
        r.grid
            .layers
            .iter_mut()
            .filter(|l| l.column.x == 1)
            .for_each(|l| l.support_height = -0.16);
        r.triangles.push([[0.25, 0., 0.], [0.25, -0.16, 0.], [0.25, -0.16, 1.]]);
        assert!(evaluate(r).can_place);
    }
    #[test]
    fn cross_layer_rejected() {
        let mut r = request();
        r.grid
            .layers
            .iter_mut()
            .filter(|l| l.column == Column { x: 1, z: 1 })
            .for_each(|l| l.support_height = 0.021);
        assert_eq!(evaluate(r).reason, Some(BlockReason::NoSupport));
    }
    #[test]
    fn wall_triangle_penetration() {
        let mut r = request();
        r.triangles
            .push([[0.2, 0., 0.], [0.2, 1., 0.], [0.2, 0., 1.]]);
        assert_eq!(evaluate(r).reason, Some(BlockReason::BlockedByMesh));
    }
    #[test]
    fn triangle_aabb_overlap_is_not_collision() {
        let b = BoxVolume {
            center: [0., 0.5, 0.],
            half_extents: [0.5, 0.5, 0.5],
            yaw: 0.,
        };
        assert!(mesh_clear(
            &b,
            0.,
            &[[[0.4, 0.5, 2.], [2., 0.5, 0.4], [2., 0.5, 2.]]],
            0.
        ));
    }
    #[test]
    fn precise_rotated_box() {
        let b = BoxVolume {
            center: [0., 1., 0.],
            half_extents: [1., 0.5, 0.1],
            yaw: std::f32::consts::FRAC_PI_4,
        };
        let mut c = b.clone();
        c.center = [0.4, 1., 0.4];
        assert!(!boxes_overlap(&b, &c));
        c.center = [0.1, 1., -0.1];
        assert!(boxes_overlap(&b, &c));
    }
    #[test]
    fn placed_proxy_mesh_blocks() {
        let mut r = request();
        r.placed_obstacles.push(Obstacle::Mesh {
            id: "chair".into(),
            triangles: vec![[[0.2, 0., 0.], [0.2, 1., 0.], [0.2, 0., 1.]]],
            is_closed: false,
        });
        assert_eq!(
            evaluate(r).reason,
            Some(BlockReason::BlockedByPlacedProp("chair".into()))
        );
    }
    #[test]
    fn touching_box_not_collision() {
        let a = BoxVolume {
            center: [0., 1., 0.],
            half_extents: [0.5, 0.5, 0.5],
            yaw: 0.,
        };
        let mut b = a.clone();
        b.center[0] = 1.;
        assert!(!boxes_overlap(&a, &b));
    }
    #[test]
    fn nonfinite_and_excessive_input_rejected() {
        let mut r = request();
        r.footprint.yaw = f32::NAN;
        assert!(!evaluate(r).can_place);
        let mut r = request();
        r.footprint.size = [100., 100.];
        assert!(!evaluate(r).can_place);
    }
    #[test]
    fn swift_quarter_turn_footprint_parity() {
        let a = Column { x: 4, z: -3 };
        let f = Footprint {
            size: [0.75, 0.5],
            yaw: std::f32::consts::FRAC_PI_2,
        };
        let cols = f.columns(a, 0.25);
        assert_eq!(cols.len(), 6);
        assert_eq!(cols.iter().map(|c| c.x).min(), Some(4));
        assert_eq!(cols.iter().map(|c| c.x).max(), Some(5));
        assert_eq!(cols.iter().map(|c| c.z).min(), Some(-6));
        assert_eq!(cols.iter().map(|c| c.z).max(), Some(-4));
    }
    #[test]
    fn closed_proxy_contains_small_box() {
        let vertices = [
            [-2., -2., -2.],
            [2., -2., -2.],
            [2., 2., -2.],
            [-2., 2., -2.],
            [-2., -2., 2.],
            [2., -2., 2.],
            [2., 2., 2.],
            [-2., 2., 2.],
        ];
        let faces = [
            [0, 1, 2],
            [0, 2, 3],
            [4, 6, 5],
            [4, 7, 6],
            [0, 4, 5],
            [0, 5, 1],
            [3, 2, 6],
            [3, 6, 7],
            [0, 3, 7],
            [0, 7, 4],
            [1, 5, 6],
            [1, 6, 2],
        ];
        let triangles: Vec<_> = faces.iter().map(|f| f.map(|i| vertices[i])).collect();
        let b = BoxVolume {
            center: [0., 0., 0.],
            half_extents: [0.1, 0.1, 0.1],
            yaw: 0.,
        };
        assert!(mesh_clear(&b, -3., &triangles, 0.));
        assert!(obstacle_hit(
            &b,
            &Obstacle::Mesh {
                id: "closed".into(),
                triangles,
                is_closed: true
            }
        ));
    }
    #[test]
    fn stable_wire_roundtrip() {
        let r = request();
        let json = serde_json::to_value(&r).unwrap();
        assert!(json.get("restingTolerance").is_some());
        let decoded = serde_json::from_value(json).unwrap();
        assert!(evaluate(decoded).can_place);
    }
}
