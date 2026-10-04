//! Real geometry support derivation, ported from WorldRuntime PropSupportGrid.
//! Coordinates are right-handed world metres, not Unity coordinates.
use crate::placement::{capsule_can_occupy, Column, Grid, Layer, Obstacle};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
type V = [f32; 3];
type Triangle = [V; 3];
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Parameters {
    pub spacing: f32,
    pub layer_step_down: f32,
    pub scan_ceiling_margin: f32,
    pub algorithm_version: u32,
    pub maximum_step_height: f32,
    pub capsule_radius: f32,
    pub capsule_height: f32,
    pub furniture_band_height: f32,
}
impl Default for Parameters {
    fn default() -> Self {
        Self {
            spacing: 0.25,
            layer_step_down: 0.101,
            scan_ceiling_margin: 0.1,
            algorithm_version: 2,
            maximum_step_height: 0.3,
            capsule_radius: 0.2,
            capsule_height: 1.8,
            furniture_band_height: 1.6,
        }
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Bounds {
    pub minimum_x: f32,
    pub maximum_x: f32,
    pub minimum_z: f32,
    pub maximum_z: f32,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeriveRequest {
    pub triangles: Vec<Triangle>,
    #[serde(default)]
    pub blocking_volumes: Vec<Obstacle>,
    pub bounds: Bounds,
    pub seed: V,
    #[serde(default)]
    pub parameters: Parameters,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub columns: usize,
    pub layers_before_filter: usize,
    pub layers_after_filter: usize,
    pub standable_layers: usize,
    pub covered_ground_layers: usize,
    pub reachable_layers: usize,
    pub furniture_band_layers: usize,
    pub seeded: bool,
}
#[derive(Clone, Debug, Serialize)]
pub struct DeriveResult {
    pub grid: Grid,
    pub report: Report,
}
fn sub(a: V, b: V) -> V {
    std::array::from_fn(|i| a[i] - b[i])
}
fn cross(a: V, b: V) -> V {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn walkable(t: &Triangle) -> bool {
    let n = cross(sub(t[1], t[0]), sub(t[2], t[0]));
    let d = n.iter().map(|v| v * v).sum::<f32>();
    d > 1e-8 && n[1] * n[1] >= d * 0.5
}
fn height(t: &Triangle, x: f32, z: f32) -> Option<f32> {
    let [a, b, c] = *t;
    let d = (b[2] - c[2]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[2] - c[2]);
    if d.abs() <= 1e-6 {
        return None;
    }
    let u = ((b[2] - c[2]) * (x - c[0]) + (c[0] - b[0]) * (z - c[2])) / d;
    let v = ((c[2] - a[2]) * (x - c[0]) + (a[0] - c[0]) * (z - c[2])) / d;
    let w = 1. - u - v;
    (u >= -1e-5 && v >= -1e-5 && w >= -1e-5).then_some(u * a[1] + v * b[1] + w * c[1])
}
fn ground(ts: &[Triangle], p: V, above: f32) -> Option<f32> {
    let exact = ts
        .iter()
        .filter_map(|t| height(t, p[0], p[2]))
        .filter(|h| *h <= p[1] + above + 0.0001)
        .reduce(f32::max);
    if exact.is_some() {
        return exact;
    }
    // The Swift query resolves only real walkable edges within 3 cm; no infinite plane.
    ts.iter()
        .filter(|t| walkable(t))
        .flat_map(|t| {
            (0..3).filter_map(move |i| {
                let a = t[i];
                let b = t[(i + 1) % 3];
                let dx = b[0] - a[0];
                let dz = b[2] - a[2];
                let d = dx * dx + dz * dz;
                if d <= 1e-8 {
                    return None;
                }
                let u = (((p[0] - a[0]) * dx + (p[2] - a[2]) * dz) / d).clamp(0., 1.);
                let distance = (p[0] - a[0] - dx * u).powi(2) + (p[2] - a[2] - dz * u).powi(2);
                let y = a[1] + (b[1] - a[1]) * u;
                (distance <= 0.03f32.powi(2) && y <= p[1] + above + 0.0001).then_some(y)
            })
        })
        .reduce(f32::max)
}
fn box_tops(obstacles: &[Obstacle]) -> Vec<Triangle> {
    let mut ts = vec![];
    for o in obstacles {
        if let Obstacle::Box { volume: b, .. } = o {
            let (s, c) = b.yaw.sin_cos();
            let p = [[-1., -1.], [1., -1.], [1., 1.], [-1., 1.]].map(|v| {
                let x = v[0] * b.half_extents[0];
                let z = v[1] * b.half_extents[2];
                [
                    b.center[0] + c * x + s * z,
                    b.center[1] + b.half_extents[1],
                    b.center[2] - s * x + c * z,
                ]
            });
            ts.push([p[0], p[1], p[2]]);
            ts.push([p[0], p[2], p[3]]);
        }
    }
    ts
}
struct Spatial<'a> {
    triangles: &'a [Triangle],
    cells: HashMap<(i32, i32), Vec<usize>>,
}
impl<'a> Spatial<'a> {
    fn new(triangles: &'a [Triangle]) -> Self {
        let mut cells: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
        for (i, t) in triangles.iter().enumerate() {
            let lo = [0, 2].map(|axis| {
                t.iter()
                    .map(|v| v[axis])
                    .fold(f32::INFINITY, f32::min)
                    .floor() as i32
            });
            let hi = [0, 2].map(|axis| {
                t.iter()
                    .map(|v| v[axis])
                    .fold(f32::NEG_INFINITY, f32::max)
                    .floor() as i32
            });
            for x in lo[0]..=hi[0] {
                for z in lo[1]..=hi[1] {
                    cells.entry((x, z)).or_default().push(i);
                }
            }
        }
        Self { triangles, cells }
    }
    fn query(&self, p: V, radius: f32) -> Vec<Triangle> {
        let mut ids = HashSet::new();
        for x in (p[0] - radius).floor() as i32..=(p[0] + radius).floor() as i32 {
            for z in (p[2] - radius).floor() as i32..=(p[2] + radius).floor() as i32 {
                if let Some(cell) = self.cells.get(&(x, z)) {
                    ids.extend(cell.iter().copied());
                }
            }
        }
        let mut ids: Vec<_> = ids.into_iter().collect();
        ids.sort_unstable();
        ids.into_iter().map(|i| self.triangles[i]).collect()
    }
    fn ground(&self, p: V, above: f32) -> Option<f32> {
        ground(&self.query(p, 0.03), p, above)
    }
}
fn occupy(r: &DeriveRequest, spatial: &Spatial<'_>, p: V) -> bool {
    capsule_can_occupy(
        &spatial.query(p, r.parameters.capsule_radius),
        &r.blocking_volumes,
        p,
        r.parameters.capsule_radius,
        r.parameters.capsule_height,
    )
}
fn traverse(r: &DeriveRequest, spatial: &Spatial<'_>, a: V, b: V) -> bool {
    let p = &r.parameters;
    let Some(ga) = spatial.ground(a, p.maximum_step_height) else {
        return false;
    };
    let Some(gb) = spatial.ground(b, p.maximum_step_height) else {
        return false;
    };
    if (gb - ga).abs() > p.maximum_step_height + 0.0001 || !occupy(r, spatial, [a[0], ga, a[2]]) {
        return false;
    }
    let d = sub(b, a);
    let distance = d.iter().map(|x| x * x).sum::<f32>().sqrt();
    let n = (distance / p.capsule_radius).ceil().max(1.) as usize;
    let mut previous = ga;
    for i in 1..=n {
        let q = std::array::from_fn(|j| a[j] + d[j] * i as f32 / n as f32);
        let Some(g) = spatial.ground(q, p.maximum_step_height) else {
            return false;
        };
        if (g - previous).abs() > p.maximum_step_height + 0.0001 {
            return false;
        }
        if !occupy(r, spatial, [q[0], g, q[2]]) {
            let lifted = g.max(ga).max(gb);
            if lifted - g > p.maximum_step_height + 0.0001
                || !occupy(r, spatial, [q[0], lifted, q[2]])
            {
                return false;
            }
        }
        previous = g;
    }
    // Furniture volumes additionally block every radius/2 sweep sample.
    let n = (distance / (p.capsule_radius / 2.).max(0.01))
        .ceil()
        .max(1.) as usize;
    (0..=n).all(|i| {
        capsule_can_occupy(
            &[],
            &r.blocking_volumes,
            std::array::from_fn(|j| a[j] + d[j] * i as f32 / n as f32),
            p.capsule_radius,
            p.capsule_height,
        )
    })
}
pub fn derive(r: DeriveRequest) -> Result<DeriveResult, String> {
    let p = &r.parameters;
    let b = &r.bounds;
    if ![
        p.spacing,
        p.layer_step_down,
        p.scan_ceiling_margin,
        p.maximum_step_height,
        p.capsule_radius,
        p.capsule_height,
        p.furniture_band_height,
        b.minimum_x,
        b.maximum_x,
        b.minimum_z,
        b.maximum_z,
    ]
    .iter()
    .all(|v| v.is_finite())
        || !r.seed.iter().all(|v| v.is_finite())
        || p.spacing <= 0.
        || p.layer_step_down <= 0.
        || p.scan_ceiling_margin < 0.
        || p.maximum_step_height < 0.
        || p.capsule_radius <= 0.
        || p.capsule_height < 2. * p.capsule_radius
        || p.furniture_band_height < 0.
        || p.algorithm_version < 1
        || b.minimum_x > b.maximum_x
        || b.minimum_z > b.maximum_z
    {
        return Err("invalid support derivation parameters".into());
    }
    if r.triangles
        .iter()
        .flatten()
        .flatten()
        .any(|v| !v.is_finite())
    {
        return Err("non-finite support geometry".into());
    }
    let mut index_entries = 0f64;
    for t in &r.triangles {
        let lo = [0, 2].map(|axis| {
            t.iter()
                .map(|v| v[axis])
                .fold(f32::INFINITY, f32::min)
                .floor()
        });
        let hi = [0, 2].map(|axis| {
            t.iter()
                .map(|v| v[axis])
                .fold(f32::NEG_INFINITY, f32::max)
                .floor()
        });
        if lo
            .iter()
            .chain(hi.iter())
            .any(|v| *v < i32::MIN as f32 || *v >= i32::MAX as f32)
        {
            return Err("geometry exceeds spatial coordinate limits".into());
        }
        index_entries += (hi[0] as f64 - lo[0] as f64 + 1.) * (hi[1] as f64 - lo[1] as f64 + 1.);
        if index_entries > 20_000_000. {
            return Err("geometry exceeds spatial index limit".into());
        }
    }
    for o in &r.blocking_volumes {
        match o {
            Obstacle::Box { volume, .. }
                if !volume
                    .center
                    .iter()
                    .chain(volume.half_extents.iter())
                    .all(|v| v.is_finite())
                    || volume.half_extents.iter().any(|v| *v <= 0.)
                    || !volume.yaw.is_finite() =>
            {
                return Err("invalid blocking box".into())
            }
            Obstacle::Mesh { triangles, .. }
                if triangles.is_empty()
                    || triangles.iter().flatten().flatten().any(|v| !v.is_finite()) =>
            {
                return Err("invalid blocking mesh".into())
            }
            _ => {}
        }
    }
    let ranges = [
        (b.minimum_x / p.spacing).ceil(),
        (b.maximum_x / p.spacing).floor(),
        (b.minimum_z / p.spacing).ceil(),
        (b.maximum_z / p.spacing).floor(),
    ];
    if ranges
        .iter()
        .any(|v| *v < i32::MIN as f32 || *v >= i32::MAX as f32)
        || ranges[0] > ranges[1]
        || ranges[2] > ranges[3]
        || (ranges[1] as f64 - ranges[0] as f64 + 1.) * (ranges[3] as f64 - ranges[2] as f64 + 1.)
            > 2_000_000.
    {
        return Err("support grid bounds exceed column limit".into());
    }
    let mut out = DeriveResult {
        grid: Grid {
            spacing: p.spacing,
            minimum: Column {
                x: ranges[0] as i32,
                z: ranges[2] as i32,
            },
            maximum: Column {
                x: ranges[1] as i32,
                z: ranges[3] as i32,
            },
            layers: vec![],
        },
        report: Report::default(),
    };
    let mut ts = r.triangles.clone();
    ts.extend(box_tops(&r.blocking_volumes));
    ts.retain(|t| {
        (0..3).any(|i| {
            t[i][0] >= b.minimum_x
                && t[i][0] <= b.maximum_x
                && t[i][2] >= b.minimum_z
                && t[i][2] <= b.maximum_z
        }) || (t.iter().map(|v| v[0]).fold(f32::INFINITY, f32::min) <= b.maximum_x
            && t.iter().map(|v| v[0]).fold(f32::NEG_INFINITY, f32::max) >= b.minimum_x
            && t.iter().map(|v| v[2]).fold(f32::INFINITY, f32::min) <= b.maximum_z
            && t.iter().map(|v| v[2]).fold(f32::NEG_INFINITY, f32::max) >= b.minimum_z)
    });
    if ts.is_empty() {
        return Ok(out);
    }
    let min = ts
        .iter()
        .flatten()
        .map(|v| v[1])
        .fold(f32::INFINITY, f32::min);
    let max = ts
        .iter()
        .flatten()
        .map(|v| v[1])
        .fold(f32::NEG_INFINITY, f32::max);
    let spatial = Spatial::new(&r.triangles);
    let support_spatial = Spatial::new(&ts);
    let mut columns: BTreeMap<(i32, i32), Vec<usize>> = BTreeMap::new();
    let mut scanned = vec![];
    for x in out.grid.minimum.x..=out.grid.maximum.x {
        for z in out.grid.minimum.z..=out.grid.maximum.z {
            let mut ceiling = max + p.scan_ceiling_margin;
            let mut hs = vec![];
            while hs.len() < 256 {
                let Some(h) = support_spatial
                    .ground([x as f32 * p.spacing, ceiling, z as f32 * p.spacing], 0.05)
                else {
                    break;
                };
                if h < min - 0.001 {
                    break;
                }
                hs.push(h);
                ceiling = h - p.layer_step_down;
            }
            hs.sort_by(f32::total_cmp);
            for (i, h) in hs.into_iter().enumerate() {
                columns.entry((x, z)).or_default().push(scanned.len());
                scanned.push(Layer {
                    column: Column { x, z },
                    layer: i as i32,
                    support_height: h,
                });
            }
        }
    }
    let center = |i: usize| {
        let l: &Layer = &scanned[i];
        [
            l.column.x as f32 * p.spacing,
            l.support_height,
            l.column.z as f32 * p.spacing,
        ]
    };
    let probe = |i: usize| {
        let mut q = center(i);
        q[0] += p.spacing / 2.;
        q[2] += p.spacing / 2.;
        q
    };
    let mut stand = HashSet::new();
    let mut covered = HashSet::new();
    let mut candidates = HashSet::new();
    for ids in columns.values() {
        for &i in ids {
            if occupy(&r, &spatial, probe(i)) {
                stand.insert(i);
            } else if scanned[i].layer == 0
                && ids.iter().skip(1).any(|&j| {
                    let d = scanned[j].support_height - scanned[i].support_height;
                    d > 0.0001 && d <= p.furniture_band_height + 0.0001
                })
            {
                covered.insert(i);
            }
            if scanned[i].layer == 0 {
                candidates.insert(i);
            }
        }
    }
    candidates.extend(&stand);
    candidates.extend(&covered);
    out.report.columns = columns.len();
    out.report.layers_before_filter = scanned.len();
    out.report.standable_layers = stand.len();
    out.report.covered_ground_layers = covered.len();
    if r.seed[0] < b.minimum_x
        || r.seed[0] > b.maximum_x
        || r.seed[2] < b.minimum_z
        || r.seed[2] > b.maximum_z
    {
        return Ok(out);
    }
    let start = (0..scanned.len())
        .filter(|i| candidates.contains(i))
        .min_by(|a, b| {
            let dist = |i| sub(center(i), r.seed).iter().map(|v| v * v).sum::<f32>();
            dist(*a).total_cmp(&dist(*b))
        });
    let Some(start) = start else { return Ok(out) };
    let mut reached = HashSet::from([start]);
    let mut queue = vec![start];
    let mut cursor = 0;
    let mut full_height = BTreeMap::new();
    while cursor < queue.len() {
        let i = queue[cursor];
        cursor += 1;
        let l = &scanned[i];
        for dx in -1..=1 {
            for dz in -1..=1 {
                let Some(ids) = columns.get(&(l.column.x + dx, l.column.z + dz)) else {
                    continue;
                };
                for &j in ids {
                    if dx != 0 || dz != 0 {
                        if scanned[j].layer != l.layer {
                            continue;
                        }
                    }
                    if !candidates.contains(&j)
                        || reached.contains(&j)
                        || (scanned[j].support_height - l.support_height).abs()
                            > p.maximum_step_height + 0.0001
                    {
                        continue;
                    }
                    let vertical = dx == 0 && dz == 0;
                    let both = l.layer == 0 && scanned[j].layer == 0;
                    let blocked = *full_height
                        .entry((scanned[j].column.x, scanned[j].column.z))
                        .or_insert_with(|| {
                            let g = scanned[j].support_height;
                            ids.iter()
                                .map(|&k| scanned[k].support_height)
                                .chain([g, g + p.maximum_step_height])
                                .filter(|h| *h >= g - 0.0001 && *h <= g + p.capsule_height + 0.0001)
                                .all(|h| {
                                    let mut q = probe(j);
                                    q[1] = h;
                                    !occupy(&r, &spatial, q)
                                })
                        });
                    if vertical
                        || (both && (covered.contains(&i) || covered.contains(&j) || !blocked))
                        || traverse(&r, &spatial, center(i), center(j))
                    {
                        reached.insert(j);
                        queue.push(j);
                    }
                }
            }
        }
    }
    let mut retained = reached.clone();
    for &i in &reached {
        let l = &scanned[i];
        for &j in &columns[&(l.column.x, l.column.z)] {
            let d = scanned[j].support_height - l.support_height;
            if d > 0. && d <= p.furniture_band_height + 0.0001 {
                retained.insert(j);
            }
        }
    }
    out.report.seeded = true;
    out.report.reachable_layers = reached.len();
    out.report.furniture_band_layers = retained.len() - reached.len();
    out.grid.layers = scanned
        .into_iter()
        .enumerate()
        .filter_map(|(i, l)| retained.contains(&i).then_some(l))
        .collect();
    out.report.layers_after_filter = out.grid.layers.len();
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn quad(lo: f32, hi: f32, y: f32) -> Vec<Triangle> {
        vec![
            [[lo, y, lo], [hi, y, lo], [hi, y, hi]],
            [[lo, y, lo], [hi, y, hi], [lo, y, hi]],
        ]
    }
    fn request(ts: Vec<Triangle>) -> DeriveRequest {
        DeriveRequest {
            triangles: ts,
            blocking_volumes: vec![],
            bounds: Bounds {
                minimum_x: -2.,
                maximum_x: 2.,
                minimum_z: -2.,
                maximum_z: 2.,
            },
            seed: [-1., 0., -1.],
            parameters: Parameters::default(),
        }
    }
    #[test]
    fn flat_floor() {
        let out = derive(request(quad(-2., 2., 0.))).unwrap();
        assert_eq!(out.grid.layers.len(), 17 * 17);
        assert!(out
            .grid
            .layers
            .iter()
            .all(|l| l.layer == 0 && l.support_height == 0.));
    }
    #[test]
    fn table_two_layers() {
        let mut ts = quad(-2., 2., 0.);
        ts.extend(quad(0., 1., 1.2));
        let out = derive(request(ts)).unwrap();
        assert_eq!(out.grid.layers.len(), 17 * 17 + 25);
        let ls: Vec<_> = out
            .grid
            .layers
            .iter()
            .filter(|l| l.column.x == 2 && l.column.z == 2)
            .collect();
        assert_eq!(ls.len(), 2);
        assert_eq!(ls[1].support_height, 1.2);
    }
    #[test]
    fn roof_removed() {
        let mut ts = quad(-2., 2., 0.);
        ts.extend(quad(-2., 2., 5.));
        let out = derive(request(ts)).unwrap();
        assert!(out.grid.layers.iter().all(|l| l.support_height == 0.));
        assert_eq!(out.report.layers_before_filter, 17 * 17 * 2);
    }
    #[test]
    fn absent_geometry_and_outside_seed_fail_closed() {
        assert!(derive(request(vec![])).unwrap().grid.layers.is_empty());
        let mut r = request(quad(-2., 2., 0.));
        r.seed = [3., 0., 0.];
        let out = derive(r).unwrap();
        assert!(!out.report.seeded);
        assert!(out.grid.layers.is_empty());
    }
    #[test]
    fn deterministic_input_order() {
        let mut ts = quad(-2., 2., 0.);
        ts.extend(quad(0., 1., 0.8));
        let first = derive(request(ts.clone())).unwrap();
        ts.reverse();
        let second = derive(request(ts)).unwrap();
        assert_eq!(
            serde_json::to_value(first).unwrap(),
            serde_json::to_value(second).unwrap()
        );
    }
    #[test]
    fn real_triangle_not_bounds_support() {
        let ts = vec![[[0., 0., 0.], [1., 0., 0.], [0., 0., 1.]]];
        let out = derive(request(ts)).unwrap();
        assert!(!out
            .grid
            .layers
            .iter()
            .any(|l| l.column.x == 3 && l.column.z == 3));
    }
    #[test]
    fn blocking_box_top_is_real_surface() {
        let mut r = request(quad(-2., 2., 0.));
        r.blocking_volumes.push(Obstacle::Box {
            id: "table".into(),
            volume: crate::placement::BoxVolume {
                center: [0.5, 0.5, 0.5],
                half_extents: [0.5, 0.5, 0.5],
                yaw: 0.,
            },
        });
        let out = derive(r).unwrap();
        assert!(out
            .grid
            .layers
            .iter()
            .any(|l| l.column.x == 2 && l.column.z == 2 && (l.support_height - 1.).abs() < 0.0001));
    }
    #[test]
    fn invalid_parameters_rejected() {
        let mut r = request(quad(-2., 2., 0.));
        r.parameters.spacing = 0.;
        assert!(derive(r).is_err());
    }
}
