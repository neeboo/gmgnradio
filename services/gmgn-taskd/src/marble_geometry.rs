//! Marble package geometry policy. Native owns byte decoding/node transforms
//! and actual physics queries; this module owns framing, probe order and spawn.
//! Pure helpers do not authorize an operation, registration or durable write.
//! The caller must load geometry from its verified owned artifact boundary.
use crate::model::Result;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

type Point = [f32; 3];
const CAPSULE_RADIUS: f32 = 0.2;
const CAPSULE_HEIGHT: f32 = 1.8;
const GROUND_DIFFERENCE: f32 = 0.05;

fn point(v: &Value) -> Result<Point> {
    let a = v
        .as_array()
        .filter(|a| a.len() == 3)
        .ok_or("marble_geometry_invalid_input")?;
    let mut p = [0.0; 3];
    for (i, value) in a.iter().enumerate() {
        p[i] = value
            .as_f64()
            .filter(|v| v.is_finite())
            .ok_or("marble_geometry_invalid_input")? as f32;
        if !p[i].is_finite() {
            return Err("marble_geometry_invalid_input");
        }
    }
    Ok(p)
}
fn hash(v: &Value) -> Result<String> {
    let encoded = crate::canonical_json::to_vec(v).map_err(|_| "marble_geometry_invalid_input")?;
    Ok(format!("{:x}", Sha256::digest(encoded)))
}
fn xyz(p: Point) -> Value {
    json!({"x":p[0],"y":p[1],"z":p[2]})
}
fn transform(p: Point) -> Value {
    json!({"position":xyz(p),"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":1,"y":1,"z":1}})
}

/// Input: {positions:[source f32 xyz], triangles:[node-transformed source xyz*3],
/// sourceCoordinates:"glTF"|"worldLabsOpenCV"}. Array order is source identity.
pub fn plan(geometry: &Value) -> Result<Value> {
    let raw_positions = geometry["positions"]
        .as_array()
        .filter(|a| !a.is_empty())
        .ok_or("marble_geometry_invalid_input")?;
    let raw_triangles = geometry["triangles"]
        .as_array()
        .filter(|a| !a.is_empty())
        .ok_or("marble_geometry_invalid_input")?;
    let flip = match geometry["sourceCoordinates"].as_str() {
        Some("glTF") => false,
        Some("worldLabsOpenCV") => true,
        _ => return Err("marble_geometry_invalid_input"),
    };
    // Validate every decoded source point, including those outside the sample.
    let positions = raw_positions
        .iter()
        .map(point)
        .collect::<Result<Vec<_>>>()?;
    let sample_stride = (positions.len() / 40_000).max(1);
    let sampled: Vec<Point> = positions.iter().step_by(sample_stride).copied().collect();
    let mut minimum = [0.0; 3];
    let mut maximum = [0.0; 3];
    for axis in 0..3 {
        let mut values: Vec<f32> = sampled.iter().map(|p| p[axis]).collect();
        values.sort_by(f32::total_cmp);
        let trim = if values.len() >= 100 {
            values.len() / 50
        } else {
            0
        };
        minimum[axis] = values[trim];
        maximum[axis] = values[values.len() - trim - 1];
    }
    let center = [
        (minimum[0] + maximum[0]) * 0.5,
        (minimum[1] + maximum[1]) * 0.5,
        (minimum[2] + maximum[2]) * 0.5,
    ];
    let origin = [center[0], minimum[1], center[2]];
    let extent = (maximum[0] - minimum[0])
        .max(maximum[1] - minimum[1])
        .max(maximum[2] - minimum[2]);
    let scale = if extent > 0.0001 {
        (4.0_f32 / extent).clamp(0.05, 20.0)
    } else {
        1.0
    };
    let normalized_minimum: Point = if extent > 0.0001 {
        std::array::from_fn(|i| (minimum[i] - origin[i]) * scale)
    } else {
        [0.0; 3]
    };
    let normalized_maximum: Point = if extent > 0.0001 {
        std::array::from_fn(|i| (maximum[i] - origin[i]) * scale)
    } else {
        [0.0; 3]
    };
    // The runtime document uses the normalization round trip, including the
    // degenerate branch, rather than the unnormalized quantile bounds.
    let runtime_minimum: Point = std::array::from_fn(|i| normalized_minimum[i] / scale + origin[i]);
    let runtime_maximum: Point = std::array::from_fn(|i| normalized_maximum[i] / scale + origin[i]);
    if center
        .iter()
        .chain(origin.iter())
        .chain(normalized_minimum.iter())
        .chain(normalized_maximum.iter())
        .any(|v| !v.is_finite())
    {
        return Err("marble_geometry_invalid_input");
    }
    let mut candidates = Vec::with_capacity(raw_triangles.len());
    for (index, triangle) in raw_triangles.iter().enumerate() {
        let vertices = triangle
            .as_array()
            .filter(|a| a.len() == 3)
            .ok_or("marble_geometry_invalid_input")?;
        let mut converted = [[0.0; 3]; 3];
        for (j, vertex) in vertices.iter().enumerate() {
            let mut p = point(vertex)?;
            if flip {
                p[1] = -p[1];
                p[2] = -p[2];
            }
            converted[j] = std::array::from_fn(|i| (p[i] - origin[i]) * scale);
        }
        // Match Swift Float operations: (first + second + third) / Float(3).
        let centroid: Point =
            std::array::from_fn(|i| ((converted[0][i] + converted[1][i]) + converted[2][i]) / 3.0);
        let distance = centroid[0] * centroid[0] + centroid[2] * centroid[2];
        if converted
            .iter()
            .flatten()
            .chain(centroid.iter())
            .any(|v| !v.is_finite())
            || !distance.is_finite()
        {
            return Err("marble_geometry_invalid_input");
        }
        candidates.push((index, centroid, distance));
    }
    // Swift's existing equal-distance input order is preserved explicitly.
    candidates.sort_by(|a, b| a.2.total_cmp(&b.2).then(a.0.cmp(&b.0)));
    let probes: Vec<Value> = candidates
        .iter()
        .map(|(index, p, _)| {
            json!({
                "key":format!("triangle:{index}"),"triangleIndex":index,"position":p,
                "capsule":{"radius":CAPSULE_RADIUS,"height":CAPSULE_HEIGHT}
            })
        })
        .collect();
    let geometry_hash = hash(geometry)?;
    let mut value = json!({"schemaVersion":1,"geometryHash":geometry_hash,
        "sampleStride":sample_stride,"sampleCount":sampled.len(),
        "framing":{"center":center,"origin":origin,"uniformScale":scale,
            "minimum":minimum,"maximum":maximum,"normalizedMinimum":normalized_minimum,"normalizedMaximum":normalized_maximum,
            "runtimeMinimum":runtime_minimum,"runtimeMaximum":runtime_maximum},
        "meshTransform":{"axisConversion":if flip {"flipYAndZ"} else {"identity"},"origin":origin,"uniformScale":scale},
        "probes":probes});
    value["planHash"] = json!(hash(&value)?);
    Ok(value)
}

/// Resolve only against a newly recomputed plan from the same verified source.
/// Measurements may be a prefix ending at the first usable point. An absent
/// higher-ranked probe is unknown, never permission to choose a later point.
/// Native reports groundHeight and canOccupy; it does not report a policy verdict.
pub fn resolve(input: &Value) -> Result<Value> {
    let value = plan(&input["geometry"])?;
    if input["planHash"] != value["planHash"] {
        return Err("marble_geometry_plan_mismatch");
    }
    let probes = value["probes"]
        .as_array()
        .ok_or("marble_geometry_invalid_input")?;
    let rows = input["measurements"]
        .as_array()
        .ok_or("marble_geometry_invalid_proof")?;
    let by_key: HashMap<&str, &Value> = probes
        .iter()
        .map(|p| Ok((p["key"].as_str().ok_or("marble_geometry_invalid_input")?, p)))
        .collect::<Result<_>>()?;
    let mut measurements = HashMap::new();
    for row in rows {
        let key = row["key"].as_str().ok_or("marble_geometry_invalid_proof")?;
        let probe = by_key.get(key).ok_or("marble_geometry_invalid_proof")?;
        let measured = point(&row["position"]).map_err(|_| "marble_geometry_invalid_proof")?;
        if measured != point(&probe["position"])? || measurements.insert(key, row).is_some() {
            return Err("marble_geometry_invalid_proof");
        }
        if row.get("groundHeight").is_none()
            || (!row["groundHeight"].is_null()
                && row["groundHeight"]
                    .as_f64()
                    .is_none_or(|v| !v.is_finite() || !(v as f32).is_finite()))
            || row.get("canOccupy").is_none()
            || (!row["canOccupy"].is_null() && row["canOccupy"].as_bool().is_none())
        {
            return Err("marble_geometry_invalid_proof");
        }
    }
    for probe in probes {
        let key = probe["key"]
            .as_str()
            .ok_or("marble_geometry_invalid_input")?;
        let row = measurements
            .get(key)
            .ok_or("marble_geometry_incomplete_proof")?;
        let position = point(&probe["position"])?;
        let Some(ground) = row["groundHeight"].as_f64() else {
            continue;
        };
        if ((ground as f32) - position[1]).abs() >= GROUND_DIFFERENCE {
            continue;
        }
        let occupancy = row["canOccupy"]
            .as_bool()
            .ok_or("marble_geometry_incomplete_proof")?;
        if !occupancy {
            continue;
        }
        let camera = [position[0], position[1] + 1.5, position[2]];
        return Ok(
            json!({"schemaVersion":1,"geometryHash":value["geometryHash"],"planHash":value["planHash"],
            "selectedProbeKey":key,"spawn":transform(position),
            "waypoint":{"id":"wp.spawn","position":xyz(position),"arrivalRadius":0.2,"enabled":true},
            "camera":{"id":"camera.home","transform":transform(camera),"fieldOfViewDegrees":60,"nearPlane":0.01,"farPlane":100}}),
        );
    }
    Err("marble_geometry_no_spawn")
}

pub fn request(method: &str, input: &Value) -> Result<Value> {
    match method {
        "marble_geometry_plan" => plan(&input["geometry"]),
        "marble_geometry_resolve" => resolve(input),
        _ => Err("method_not_found"),
    }
}

/// The host samples only these Rust-selected indices. The SPZ decoder still
/// validates every decoded source point; sampling must not skip decode errors.
pub fn sample_plan(point_count: usize) -> Result<Value> {
    if point_count == 0 || point_count > 8_600_000 {
        return Err("marble_geometry_invalid_input");
    }
    let stride = (point_count / 40_000).max(1);
    let indices: Vec<usize> = (0..point_count).step_by(stride).collect();
    Ok(json!({"sourcePointCount":point_count,"sampleStride":stride,"indices":indices}))
}

/// SHA references only: never accept host paths. The daemon supplies a loader
/// for descriptors already resolved from its one world_blobs store. Execute
/// this entire function outside the storage transaction / mutex.
fn read_chunks(
    refs: &Value,
    total: usize,
    field: &str,
    load: &mut impl FnMut(&str) -> Result<Vec<u8>>,
) -> Result<Vec<Value>> {
    let refs = refs.as_array().ok_or("marble_geometry_invalid_input")?;
    let mut result = Vec::new();
    for reference in refs {
        let sha = reference
            .as_str()
            .filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or("marble_geometry_invalid_input")?;
        let bytes = load(sha)?;
        if bytes.len() > 4 * 1024 * 1024 || format!("{:x}", Sha256::digest(&bytes)) != sha {
            return Err("marble_geometry_invalid_proof");
        }
        let chunk: Value =
            serde_json::from_slice(&bytes).map_err(|_| "marble_geometry_invalid_input")?;
        if chunk["offset"].as_u64() != Some(result.len() as u64) {
            return Err("marble_geometry_invalid_proof");
        }
        let values = chunk[field]
            .as_array()
            .filter(|v| !v.is_empty())
            .ok_or("marble_geometry_invalid_input")?;
        if values.len() > total.saturating_sub(result.len()) {
            return Err("marble_geometry_invalid_proof");
        }
        result.extend(values.iter().cloned());
    }
    if result.len() != total {
        return Err("marble_geometry_incomplete_proof");
    }
    Ok(result)
}

fn assembled_plan(
    input: &Value,
    load: &mut impl FnMut(&str) -> Result<Vec<u8>>,
) -> Result<(Value, Value)> {
    let count = input["sourcePointCount"]
        .as_u64()
        .and_then(|v| usize::try_from(v).ok())
        .ok_or("marble_geometry_invalid_input")?;
    let sampling = sample_plan(count)?;
    let expected = sampling["indices"]
        .as_array()
        .ok_or("marble_geometry_invalid_input")?;
    let samples = input["samples"]
        .as_array()
        .ok_or("marble_geometry_invalid_input")?;
    if samples.len() != expected.len() {
        return Err("marble_geometry_incomplete_proof");
    }
    let mut positions = Vec::with_capacity(samples.len());
    for (sample, index) in samples.iter().zip(expected) {
        if sample["index"] != *index {
            return Err("marble_geometry_invalid_proof");
        }
        point(&sample["position"])?;
        positions.push(sample["position"].clone());
    }
    let total = input["triangleCount"]
        .as_u64()
        .and_then(|v| usize::try_from(v).ok())
        .filter(|v| *v > 0)
        .ok_or("marble_geometry_invalid_input")?;
    let triangles = read_chunks(&input["triangleChunks"], total, "triangles", load)?;
    let geometry = json!({"positions":positions,"triangles":triangles,"sourceCoordinates":input["sourceCoordinates"]});
    let mut value = plan(&geometry)?;
    value["sampleStride"] = sampling["sampleStride"].clone();
    value["sourcePointCount"] = json!(count);
    // Bind the actual chunk bytes and original source count/index selection.
    value["geometryHash"] = json!(hash(input)?);
    value
        .as_object_mut()
        .ok_or("marble_geometry_invalid_input")?
        .remove("planHash");
    value["planHash"] = json!(hash(&value)?);
    Ok((geometry, value))
}

/// input.geometry is the small sampled-source/chunk manifest. Every page
/// recomputes against verified bytes; there is no in-memory-only plan authority.
pub fn plan_page(input: &Value, load: &mut impl FnMut(&str) -> Result<Vec<u8>>) -> Result<Value> {
    let (_, mut value) = assembled_plan(&input["geometry"], load)?;
    if let Some(expected) = input.get("planHash") {
        if expected != &value["planHash"] {
            return Err("marble_geometry_plan_mismatch");
        }
    }
    let offset = input["offset"]
        .as_u64()
        .and_then(|v| usize::try_from(v).ok())
        .ok_or("marble_geometry_invalid_input")?;
    let limit = input["limit"]
        .as_u64()
        .filter(|v| (1..=4096).contains(v))
        .ok_or("marble_geometry_invalid_input")? as usize;
    let probes = value["probes"]
        .as_array()
        .ok_or("marble_geometry_invalid_input")?;
    if offset > probes.len() {
        return Err("marble_geometry_invalid_input");
    }
    let total = probes.len();
    let end = offset.saturating_add(limit).min(total);
    let page = probes[offset..end].to_vec();
    value["probes"] = json!(page);
    value["offset"] = json!(offset);
    value["probeCount"] = json!(total);
    value["nextOffset"] = if end < total { json!(end) } else { Value::Null };
    Ok(value)
}

pub fn resolve_chunks(
    input: &Value,
    load: &mut impl FnMut(&str) -> Result<Vec<u8>>,
) -> Result<Value> {
    let (geometry, value) = assembled_plan(&input["geometry"], load)?;
    if input["planHash"] != value["planHash"] {
        return Err("marble_geometry_plan_mismatch");
    }
    let count = input["measurementCount"]
        .as_u64()
        .and_then(|v| usize::try_from(v).ok())
        .filter(|v| *v <= value["probes"].as_array().map_or(0, Vec::len))
        .ok_or("marble_geometry_invalid_proof")?;
    let measurements = read_chunks(&input["measurementChunks"], count, "measurements", load)?;
    // The legacy pure helper validates all actual measurements and unknowns.
    let raw_plan = plan(&geometry)?;
    let mut resolved = resolve(
        &json!({"geometry":geometry,"planHash":raw_plan["planHash"],"measurements":measurements}),
    )?;
    resolved["geometryHash"] = value["geometryHash"].clone();
    resolved["planHash"] = value["planHash"].clone();
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paged_owned_chunks_preserve_all_candidates_and_reject_incomplete_facts() {
        let g = geometry();
        let mut blobs = HashMap::<String, Vec<u8>>::new();
        let mut store = |value: Value| {
            let bytes = crate::canonical_json::to_vec(&value).unwrap();
            let sha = format!("{:x}", Sha256::digest(&bytes));
            blobs.insert(sha.clone(), bytes);
            sha
        };
        let first = store(json!({"offset":0,"triangles":[g["triangles"][0]]}));
        let second = store(json!({"offset":1,"triangles":[g["triangles"][1]]}));
        let samples: Vec<Value> = g["positions"]
            .as_array()
            .unwrap()
            .iter()
            .enumerate()
            .map(|(i, p)| json!({"index":i,"position":p}))
            .collect();
        let manifest = json!({"sourcePointCount":4,"samples":samples,"sourceCoordinates":"glTF",
            "triangleCount":2,"triangleChunks":[first,second]});
        let mut load = |sha: &str| {
            blobs
                .get(sha)
                .cloned()
                .ok_or("marble_geometry_invalid_proof")
        };
        let page = plan_page(
            &json!({"geometry":manifest,"offset":0,"limit":1}),
            &mut load,
        )
        .unwrap();
        assert_eq!(page["probeCount"], 2);
        assert_eq!(page["nextOffset"], 1);
        let page2 = plan_page(
            &json!({"geometry":manifest,"offset":1,"limit":1,"planHash":page["planHash"]}),
            &mut load,
        )
        .unwrap();
        assert_eq!(page2["probes"][0]["key"], "triangle:1");
        let mut reordered = manifest.clone();
        reordered["triangleChunks"] = json!([second, first]);
        assert_eq!(
            plan_page(
                &json!({"geometry":reordered,"offset":0,"limit":1}),
                &mut load
            ),
            Err("marble_geometry_invalid_proof")
        );
        let mut missing = manifest.clone();
        missing["triangleChunks"] = json!([first]);
        assert_eq!(
            plan_page(&json!({"geometry":missing,"offset":0,"limit":1}), &mut load),
            Err("marble_geometry_incomplete_proof")
        );
        let mut wrong_index = manifest.clone();
        wrong_index["samples"][1]["index"] = json!(0);
        assert_eq!(
            plan_page(
                &json!({"geometry":wrong_index,"offset":0,"limit":1}),
                &mut load
            ),
            Err("marble_geometry_invalid_proof")
        );
        let fact =
            json!({"offset":0,"measurements":[row(&page["probes"][0],json!(0),json!(true))]});
        let bytes = crate::canonical_json::to_vec(&fact).unwrap();
        let sha = format!("{:x}", Sha256::digest(&bytes));
        blobs.insert(sha.clone(), bytes);
        let mut load = |key: &str| {
            blobs
                .get(key)
                .cloned()
                .ok_or("marble_geometry_invalid_proof")
        };
        let resolved=resolve_chunks(&json!({"geometry":manifest,"planHash":page["planHash"],"measurementCount":1,"measurementChunks":[sha]}),&mut load).unwrap();
        assert_eq!(resolved["selectedProbeKey"], "triangle:0");
        assert_eq!(resolved["planHash"], page["planHash"]);
        blobs.insert(first.clone(), b"changed".to_vec());
        let mut load = |key: &str| {
            blobs
                .get(key)
                .cloned()
                .ok_or("marble_geometry_invalid_proof")
        };
        assert_eq!(
            plan_page(
                &json!({"geometry":manifest,"offset":0,"limit":1}),
                &mut load
            ),
            Err("marble_geometry_invalid_proof")
        );
    }

    #[test]
    fn maximum_spz_sampling_is_exact_and_bounded_without_native_policy() {
        let p = sample_plan(8_600_000).unwrap();
        assert_eq!(p["sampleStride"], 215);
        assert_eq!(p["indices"].as_array().unwrap().len(), 40_000);
        assert_eq!(p["indices"][39_999], 8_599_785);
        assert_eq!(sample_plan(0), Err("marble_geometry_invalid_input"));
        assert_eq!(sample_plan(8_600_001), Err("marble_geometry_invalid_input"));
    }
    fn geometry() -> Value {
        json!({"sourceCoordinates":"glTF","positions":[[-2,0,-2],[2,0,2],[-2,3,2],[2,3,-2]],
            "triangles":[[[-3,0,-3],[3,0,-3],[0,0,6]],[[-3,0,3],[3,0,3],[0,0,-6]]]})
    }
    fn row(probe: &Value, ground: Value, occupancy: Value) -> Value {
        json!({"key":probe["key"],"position":probe["position"],"groundHeight":ground,"canOccupy":occupancy})
    }
    fn input(g: Value, rows: Vec<Value>) -> Value {
        let p = plan(&g).unwrap();
        json!({"geometry":g,"planHash":p["planHash"],"measurements":rows})
    }
    #[test]
    fn exact_framing_centroid_order_and_initial_package_parameters() {
        let g = geometry();
        let p = plan(&g).unwrap();
        assert_eq!(p["sampleStride"], 1);
        assert_eq!(p["sampleCount"], 4);
        assert_eq!(p["framing"]["uniformScale"].as_f64(), Some(1.0));
        assert_eq!(point(&p["framing"]["origin"]).unwrap(), [0.0; 3]);
        assert_eq!(p["probes"][0]["key"], "triangle:0");
        assert_eq!(p["probes"][1]["key"], "triangle:1");
        let resolved = resolve(&input(
            g,
            vec![row(&p["probes"][0], json!(0.0), json!(true))],
        ))
        .unwrap();
        assert_eq!(resolved["selectedProbeKey"], "triangle:0");
        assert_eq!(resolved["spawn"]["position"]["y"].as_f64(), Some(0.0));
        assert_eq!(
            resolved["camera"]["transform"]["position"]["y"].as_f64(),
            Some(1.5)
        );
        assert_eq!(resolved["waypoint"]["id"], "wp.spawn");
        assert_eq!(resolved["camera"]["fieldOfViewDegrees"], 60);
    }
    #[test]
    fn ground_threshold_is_strict_and_occupancy_is_real_leaf_evidence() {
        let g = geometry();
        let p = plan(&g).unwrap();
        for ground in [0.049, -0.049] {
            assert!(resolve(&input(
                g.clone(),
                vec![row(&p["probes"][0], json!(ground), json!(true))]
            ))
            .is_ok());
        }
        for ground in [0.05, 0.051, -0.05] {
            let r = resolve(&input(
                g.clone(),
                vec![
                    row(&p["probes"][0], json!(ground), Value::Null),
                    row(&p["probes"][1], Value::Null, Value::Null),
                ],
            ));
            assert_eq!(r, Err("marble_geometry_no_spawn"));
        }
        let r = resolve(&input(
            g.clone(),
            vec![
                row(&p["probes"][0], json!(0), json!(false)),
                row(&p["probes"][1], json!(0), json!(true)),
            ],
        ))
        .unwrap();
        assert_eq!(r["selectedProbeKey"], "triangle:1");
        assert_eq!(
            resolve(&input(g, vec![row(&p["probes"][0], json!(0), Value::Null)])),
            Err("marble_geometry_incomplete_proof")
        );
    }
    #[test]
    fn missing_prior_changed_position_duplicates_or_geometry_cannot_select() {
        let g = geometry();
        let p = plan(&g).unwrap();
        let r = row(&p["probes"][0], json!(0), json!(true));
        assert_eq!(
            resolve(&input(
                g.clone(),
                vec![row(&p["probes"][1], json!(0), json!(true))]
            )),
            Err("marble_geometry_incomplete_proof")
        );
        assert_eq!(
            resolve(&input(g.clone(), vec![r.clone(), r.clone()])),
            Err("marble_geometry_invalid_proof")
        );
        let mut moved = r;
        moved["position"] = json!([0, 0, 1]);
        assert_eq!(
            resolve(&input(g.clone(), vec![moved])),
            Err("marble_geometry_invalid_proof")
        );
        let mut changed = input(g, vec![]);
        changed["geometry"]["positions"][0][0] = json!(-1);
        assert_eq!(resolve(&changed), Err("marble_geometry_plan_mismatch"));
    }
    #[test]
    fn sample_stride_trim_scale_degenerate_and_source_axis_preserve_rules() {
        let mut g = geometry();
        g["positions"] = json!((0..80_000)
            .map(|n| [n as f32, 0.0, 0.0])
            .collect::<Vec<_>>());
        let p = plan(&g).unwrap();
        assert_eq!(p["sampleStride"], 2);
        assert_eq!(p["sampleCount"], 40_000);
        assert_eq!(p["framing"]["minimum"][0].as_f64(), Some(1600.0));
        assert_eq!(p["framing"]["maximum"][0].as_f64(), Some(78398.0));
        assert_eq!(p["framing"]["uniformScale"].as_f64(), Some(0.05_f32 as f64));
        g["positions"] = json!([[1, 2, 3], [1, 2, 3]]);
        g["sourceCoordinates"] = json!("worldLabsOpenCV");
        let p = plan(&g).unwrap();
        assert_eq!(p["framing"]["uniformScale"].as_f64(), Some(1.0));
        assert_eq!(point(&p["framing"]["normalizedMinimum"]).unwrap(), [0.0; 3]);
        assert_eq!(
            point(&p["framing"]["runtimeMinimum"]).unwrap(),
            [1.0, 2.0, 3.0]
        );
        assert_eq!(
            point(&p["framing"]["runtimeMaximum"]).unwrap(),
            [1.0, 2.0, 3.0]
        );
        assert_eq!(
            point(&p["probes"][0]["position"]).unwrap(),
            [-1.0, -2.0, -3.0]
        );
        g["positions"] = json!([[0, 0, 0], [0.001, 0, 0]]);
        assert_eq!(
            plan(&g).unwrap()["framing"]["uniformScale"].as_f64(),
            Some(20.0)
        );
    }
}
