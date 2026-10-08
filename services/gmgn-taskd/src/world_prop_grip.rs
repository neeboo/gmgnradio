//! Pure mesh-section grip proposals; never mutates persisted user calibration.
use crate::model::Result;
use serde_json::{json, Value};
type V = [f32; 3];
type Q = [f32; 4];
const ID: Q = [0., 0., 0., 1.];
pub const RECOMMENDED_CLEARANCE_METERS: f32 = 0.06;
pub const MAXIMUM_MOUNT_DISTANCE_METERS: f32 = 0.35;
fn add(a: V, b: V) -> V {
    std::array::from_fn(|i| a[i] + b[i])
}
fn sub(a: V, b: V) -> V {
    std::array::from_fn(|i| a[i] - b[i])
}
fn scale(a: V, s: f32) -> V {
    a.map(|v| v * s)
}
fn dot(a: V, b: V) -> f32 {
    (0..3).map(|i| a[i] * b[i]).sum()
}
fn cross(a: V, b: V) -> V {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn unit(a: V) -> Option<V> {
    let len = dot(a, a).sqrt();
    (len.is_finite() && len > 0.000001).then(|| scale(a, 1. / len))
}
fn product(a: Q, b: Q) -> Q {
    let v = add(
        add(
            scale([b[0], b[1], b[2]], a[3]),
            scale([a[0], a[1], a[2]], b[3]),
        ),
        cross([a[0], a[1], a[2]], [b[0], b[1], b[2]]),
    );
    [
        v[0],
        v[1],
        v[2],
        a[3] * b[3] - dot([a[0], a[1], a[2]], [b[0], b[1], b[2]]),
    ]
}
fn rotate(v: V, q: Q) -> V {
    let u = [q[0], q[1], q[2]];
    add(v, scale(cross(u, add(cross(u, v), scale(v, q[3]))), 2.))
}
fn angle(axis: V, value: f32) -> Q {
    let Some(u) = unit(axis) else { return ID };
    let s = (value / 2.).sin();
    [u[0] * s, u[1] * s, u[2] * s, (value / 2.).cos()]
}
fn align(from: V, to: V) -> Q {
    let (Some(a), Some(b)) = (unit(from), unit(to)) else {
        return ID;
    };
    let cosine = dot(a, b);
    if cosine >= 1. - 0.000001 {
        return ID;
    }
    if cosine <= -1. + 0.000001 {
        return angle(
            cross(
                a,
                if a[0].abs() < 0.9 {
                    [1., 0., 0.]
                } else {
                    [0., 1., 0.]
                },
            ),
            std::f32::consts::PI,
        );
    }
    angle(cross(a, b), cosine.clamp(-1., 1.).acos())
}
fn frame(primary: V, edge: V, target: V, target_edge: V) -> Option<Q> {
    let (a, e, t, te) = (
        unit(primary)?,
        unit(edge)?,
        unit(target)?,
        unit(target_edge)?,
    );
    if dot(a, e).abs() >= 0.001 || dot(t, te).abs() >= 0.001 {
        return None;
    }
    let first = align(a, t);
    let aligned = rotate(e, first);
    let twist = angle(t, dot(t, cross(aligned, te)).atan2(dot(aligned, te)));
    let q = product(twist, first);
    (dot(rotate(a, q), t) > 0.9999 && dot(rotate(e, q), te) > 0.9999).then_some(q)
}
fn vec(v: &Value) -> Option<V> {
    Some([
        v["x"].as_f64()? as f32,
        v["y"].as_f64()? as f32,
        v["z"].as_f64()? as f32,
    ])
}
fn quat(v: &Value) -> Option<Q> {
    Some([
        v["x"].as_f64()? as f32,
        v["y"].as_f64()? as f32,
        v["z"].as_f64()? as f32,
        v["w"].as_f64()? as f32,
    ])
}
fn vjson(v: V) -> Value {
    json!({"x":v[0],"y":v[1],"z":v[2]})
}
fn qjson(v: Q) -> Value {
    json!({"x":v[0],"y":v[1],"z":v[2],"w":v[3]})
}
fn qvalid(q: Q) -> bool {
    q.iter().all(|v| v.is_finite()) && (q.iter().map(|v| v * v).sum::<f32>() - 1.).abs() <= 0.01
}
fn raw_axis(oriented: usize, q: Q) -> Option<usize> {
    if !qvalid(q) {
        return None;
    }
    let mut result = None;
    let mut best = 0.;
    for axis in 0..3 {
        let mut v = [0.; 3];
        v[axis] = 1.;
        let value = rotate(v, q)[oriented].abs();
        if value > best {
            best = value;
            result = Some(axis)
        }
    }
    (best >= 0.999).then_some(result).flatten()
}
/// Same 40 true triangle-plane sections as Swift; no AABB-only handle guess.
pub fn handle_section(triangles: &[[V; 3]], axis: usize) -> Option<(V, f32)> {
    if axis >= 3 || triangles.is_empty() || triangles.len() > 1_000_000 {
        return None;
    }
    let mut low = triangles[0][0];
    let mut high = low;
    for vertex in triangles.iter().flatten() {
        if vertex.iter().any(|v| !v.is_finite()) {
            return None;
        }
        for i in 0..3 {
            low[i] = low[i].min(vertex[i]);
            high[i] = high[i].max(vertex[i]);
        }
    }
    let extent = sub(high, low);
    if extent.iter().any(|v| *v <= 0.) {
        return None;
    }
    let transverse = (0..3).filter(|i| *i != axis).collect::<Vec<_>>();
    let mut sections = Vec::with_capacity(40);
    for index in 0..40 {
        let plane = low[axis] + extent[axis] * (index as f32 + 0.5) / 40.;
        let mut bounds: Option<(V, V)> = None;
        for tri in triangles {
            for edge in 0..3 {
                let a = tri[edge];
                let b = tri[(edge + 1) % 3];
                let delta = b[axis] - a[axis];
                if delta.abs() <= 0.0000001 {
                    continue;
                }
                let t = (plane - a[axis]) / delta;
                if !(0. ..=1.).contains(&t) {
                    continue;
                }
                let point = add(a, scale(sub(b, a), t));
                match &mut bounds {
                    None => bounds = Some((point, point)),
                    Some((lo, hi)) => {
                        for i in 0..3 {
                            lo[i] = lo[i].min(point[i]);
                            hi[i] = hi[i].max(point[i]);
                        }
                    }
                }
            }
        }
        sections.push(bounds?);
    }
    let width = |i: usize| {
        let (lo, hi) = sections[i];
        (hi[transverse[0]] - lo[transverse[0]]).max(hi[transverse[1]] - lo[transverse[1]])
    };
    let ratio = |i: usize| {
        let (lo, hi) = sections[i];
        (hi[transverse[0]] - lo[transverse[0]]).min(hi[transverse[1]] - lo[transverse[1]])
            / width(i).max(0.000001)
    };
    // Preserve the first widest section when widths compare equal.
    let mut guard = 0;
    for i in 1..40 {
        if width(i) > width(guard) {
            guard = i
        }
    }
    if !(6..34).contains(&guard) {
        return None;
    }
    let mut candidates = Vec::new();
    for direction in [-1, 1] {
        let mut run = Vec::new();
        for distance in 1..40 {
            let index = guard as i32 + direction * distance;
            if !(0..40).contains(&index) {
                break;
            }
            let i = index as usize;
            let round = ratio(i) >= 0.5 && width(i) < width(guard) * 0.5;
            if round {
                run.push(i)
            } else if !run.is_empty() || distance > 3 {
                break;
            }
        }
        if !(4..=13).contains(&run.len()) {
            continue;
        }
        let flat = (0..40)
            .filter(|i| {
                if direction > 0 {
                    *i < (guard as i32 - 2).max(0) as usize
                } else {
                    *i > guard + 2
                }
            })
            .filter(|i| ratio(*i) < 0.4 && width(*i) < width(guard) * 0.8)
            .count();
        if flat < run.len() * 2 || flat < 12 {
            continue;
        }
        let middle = (run[0] + run[run.len() - 1]) / 2;
        let center = scale(add(sections[middle].0, sections[middle].1), 0.5);
        let grip = std::array::from_fn(|i| (center[i] - low[i]) / extent[i]);
        candidates.push((grip, -direction as f32));
    }
    (candidates.len() == 1).then(|| candidates[0])
}
pub fn validate(existing: &Value) -> Result<()> {
    let id = existing["avatarAssetID"]
        .as_str()
        .ok_or("prop_grip_invalid")?;
    if id.is_empty()
        || id.chars().count() > 256
        || !["rightHand", "back", "waist"].contains(&existing["hand"].as_str().unwrap_or(""))
    {
        return Err("prop_grip_invalid");
    }
    let g = vec(&existing["normalizedGrip"]).ok_or("prop_grip_invalid")?;
    let o = vec(&existing["localOffset"]).ok_or("prop_grip_invalid")?;
    let q = quat(&existing["localRotation"]).ok_or("prop_grip_invalid")?;
    if g.iter().any(|v| !v.is_finite() || !(0. ..=1.).contains(v))
        || o.iter().any(|v| !v.is_finite() || v.abs() > 2.)
        || !qvalid(q)
    {
        return Err("prop_grip_invalid");
    }
    Ok(())
}
pub fn calibration(
    prop: &Value,
    avatar_id: &str,
    slot: &str,
    triangles: &[[[f32; 3]; 3]],
) -> Result<Value> {
    if !["rightHand", "back", "waist"].contains(&slot)
        || avatar_id.is_empty()
        || avatar_id.chars().count() > 256
    {
        return Err("prop_grip_invalid");
    }
    let size = if prop["sizeLocked"] == true || !prop["sizeIntent"].is_null() {
        vec(&prop["size"])
    } else {
        vec(&prop["authoritativeSize"]["dimensions"]).or_else(|| vec(&prop["size"]))
    }
    .ok_or("prop_grip_invalid_size")?;
    if size.iter().any(|v| !v.is_finite() || *v <= 0.) {
        return Err("prop_grip_invalid_size");
    }
    let orientation = if prop["orientation"].is_null() {
        ID
    } else {
        quat(&prop["orientation"]["rotation"]).ok_or("prop_grip_invalid_orientation")?
    };
    if !qvalid(orientation) {
        return Err("prop_grip_invalid_orientation");
    }
    let mut ranked = [0, 1, 2];
    ranked.sort_by(|a, b| size[*b].total_cmp(&size[*a]));
    let principal = ranked[0];
    let raw = raw_axis(principal, orientation);
    let mut grip = [0.5, 0.2, 0.5];
    let mut rotation = ID;
    if size[principal] / size[ranked[1]] >= 4. {
        if let Some(raw) = raw {
            if let Some((g, sign)) = handle_section(triangles, raw) {
                grip = g;
                let mut axis = [0.; 3];
                axis[raw] = sign;
                rotation = align(rotate(axis, orientation), [0., 1., 0.]);
            } else if slot == "rightHand" {
                return Err("prop_grip_unknown_handle");
            }
        } else if slot == "rightHand" {
            return Err("prop_grip_invalid_orientation");
        }
    }
    let offset = match slot {
        "back" => [0., 0., 0.15],
        "waist" => [0., -0.02, 0.12],
        _ => [0.; 3],
    };
    if slot != "rightHand" {
        let thickness = size.into_iter().fold(f32::INFINITY, f32::min) / 2.;
        if offset[2] - thickness < 0. || dot(offset, offset).sqrt() > MAXIMUM_MOUNT_DISTANCE_METERS
        {
            return Err("prop_grip_insufficient_clearance");
        }
        grip = [0.5; 3];
        if let Some(raw) = raw {
            let mut axis = [0.; 3];
            axis[raw] = 1.;
            let current = rotate(rotate(axis, orientation), rotation);
            let target = if slot == "back" {
                unit([0.55, 0.835, 0.]).unwrap()
            } else {
                [1., 0., 0.]
            };
            rotation = product(align(current, target), rotation);
        }
    } else if prop["assetID"]
        == "sha256:e9dda009e47ca4c1ace5e8a6e4ccf18645a109556b4f4772e410815c2be05529"
        && avatar_id == "pmx.2b-miss-0414-standard"
    {
        // Source X(glTFast) and Z(persisted coordinates) reflections remain distinct.
        rotation = frame(
            rotate([1., 0., 0.], orientation),
            rotate([0., -1., 0.], orientation),
            [0.3697862, -0.2558435, -0.8931977],
            [0.8843164, 0.3918314, 0.2538750],
        )
        .ok_or("prop_grip_invalid_orientation")?;
    }
    let result = json!({"avatarAssetID":avatar_id,"hand":slot,"normalizedGrip":vjson(grip),"localOffset":vjson(offset),"localRotation":qjson(rotation)});
    validate(&result)?;
    Ok(result)
}
/// Existing user calibration wins unchanged; caller supplies actual persisted state.
pub fn calibration_preserving(
    prop: &Value,
    existing: Option<&Value>,
    avatar_id: &str,
    slot: &str,
    triangles: &[[V; 3]],
) -> Result<Value> {
    if let Some(existing) = existing {
        validate(existing)?;
        if existing["avatarAssetID"] == avatar_id && existing["hand"] == slot {
            return Ok(existing.clone());
        }
    }
    calibration(prop, avatar_id, slot, triangles)
}
pub fn adjust(existing: &Value, offset: [f32; 3], rotation: [f32; 4]) -> Result<Value> {
    validate(existing)?;
    let mut result = existing.clone();
    result["localOffset"] = vjson(offset);
    result["localRotation"] = qjson(rotation);
    validate(&result)?;
    Ok(result)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn box_mesh(min: V, max: V) -> Vec<[V; 3]> {
        let vertices: [V; 8] = std::array::from_fn(|i| {
            std::array::from_fn(|axis| {
                if i & (1 << axis) == 0 {
                    min[axis]
                } else {
                    max[axis]
                }
            })
        });
        [
            [0, 1, 3],
            [0, 3, 2],
            [4, 6, 7],
            [4, 7, 5],
            [0, 4, 5],
            [0, 5, 1],
            [2, 3, 7],
            [2, 7, 6],
            [0, 2, 6],
            [0, 6, 4],
            [1, 5, 7],
            [1, 7, 3],
        ]
        .map(|f| f.map(|i| vertices[i]))
        .to_vec()
    }
    fn sword(axis: usize, mirror: bool) -> Vec<[V; 3]> {
        let mut triangles = box_mesh([0., -0.02, -0.02], [0.225, 0.02, 0.02]);
        triangles.extend(box_mesh([0.225, -0.125, -0.03], [0.275, 0.125, 0.03]));
        triangles.extend(box_mesh([0.275, -0.06, -0.01], [1., 0.06, 0.01]));
        for vertex in triangles.iter_mut().flatten() {
            if mirror {
                vertex[0] = 1. - vertex[0]
            }
            vertex.swap(0, axis);
        }
        triangles
    }
    fn prop(size: V) -> Value {
        json!({"assetID":"fixture","size":vjson(size)})
    }
    #[test]
    fn real_sections_all_xyz_and_mirrored_handle_ends() {
        for axis in 0..3 {
            for mirror in [false, true] {
                let mesh = sword(axis, mirror);
                let (grip, sign) = handle_section(&mesh, axis).unwrap();
                assert_eq!(sign, if mirror { -1. } else { 1. });
                assert!(if mirror {
                    grip[axis] > 0.8
                } else {
                    grip[axis] < 0.2
                });
                let mut size = [0.25, 0.06, 1.];
                size.swap(2, axis);
                let result = calibration(&prop(size), "avatar", "rightHand", &mesh).unwrap();
                let raw = vec(&result["normalizedGrip"]).unwrap();
                assert!((raw[axis] - grip[axis]).abs() < 0.000001);
            }
        }
    }
    #[test]
    fn elongated_aabb_never_invents_handle_and_compact_default_unchanged() {
        let elongated = prop([1., 0.1, 0.1]);
        assert_eq!(
            calibration(&elongated, "avatar", "rightHand", &[]).unwrap_err(),
            "prop_grip_unknown_handle"
        );
        assert!(handle_section(&box_mesh([0.; 3], [1., 0.1, 0.1]), 0).is_none());
        let compact = calibration(&prop([0.2; 3]), "avatar", "rightHand", &[]).unwrap();
        assert_eq!(compact["normalizedGrip"], vjson([0.5, 0.2, 0.5]));
        assert_eq!(compact["localRotation"], qjson(ID));
    }
    #[test]
    fn slots_clearance_offsets_and_existing_user_grip_preserved() {
        for (slot, offset) in [("back", [0., 0., 0.15]), ("waist", [0., -0.02, 0.12])] {
            let p = prop([0.1, 0.2, 0.1]);
            let result = calibration(&p, "avatar", slot, &[]).unwrap();
            assert_eq!(result["normalizedGrip"], vjson([0.5; 3]));
            assert_eq!(result["localOffset"], vjson(offset));
            assert_eq!(
                calibration(&prop([0.4; 3]), "avatar", slot, &[]).unwrap_err(),
                "prop_grip_insufficient_clearance"
            );
        }
        let mut user = calibration(&prop([0.2; 3]), "avatar", "rightHand", &[]).unwrap();
        user["normalizedGrip"] = vjson([0.1, 0.8, 0.3]);
        assert_eq!(
            calibration_preserving(
                &prop([1., 0.1, 0.1]),
                Some(&user),
                "avatar",
                "rightHand",
                &[]
            )
            .unwrap(),
            user
        );
        let adjusted = adjust(&user, [0.1, 0.2, 0.3], ID).unwrap();
        assert_eq!(adjusted["normalizedGrip"], user["normalizedGrip"]);
        assert!(adjust(&user, [2.01, 0., 0.], ID).is_err());
        assert!(adjust(&user, [0.; 3], [0., 0., 0., 2.]).is_err());
    }
    #[test]
    fn verified_asset_avatar_full_frame_preserved() {
        let mut p = prop([1., 0.25, 0.06]);
        p["assetID"] =
            json!("sha256:e9dda009e47ca4c1ace5e8a6e4ccf18645a109556b4f4772e410815c2be05529");
        let grip = calibration(
            &p,
            "pmx.2b-miss-0414-standard",
            "rightHand",
            &sword(0, false),
        )
        .unwrap();
        let q = quat(&grip["localRotation"]).unwrap();
        assert!(
            dot(
                rotate([1., 0., 0.], q),
                unit([0.3697862, -0.2558435, -0.8931977]).unwrap()
            ) > 0.9999
        );
        assert!(
            dot(
                rotate([0., -1., 0.], q),
                unit([0.8843164, 0.3918314, 0.2538750]).unwrap()
            ) > 0.9999
        );
        let other = calibration(&p, "other-avatar", "rightHand", &sword(0, false)).unwrap();
        assert_ne!(other["localRotation"], grip["localRotation"]);
    }
}
