//! Pure Float32 counterpart of WorldPropOrientation/SizePolicy/ArchiveRebase.
//! Triangles are decoded from the verified artifact by the caller. This module
//! does not authorize ownership, synthesize meshes, or access the database.
use crate::model::{self, Result};
use serde_json::{json, Value};
pub type V = [f32; 3];
pub type Triangle = [V; 3];
pub type Q = [f32; 4];
const IDENTITY: Q = [0., 0., 0., 1.];
pub const MIN_EXTENT: f32 = 0.02;
pub const MAX_EXTENT: f32 = 3.;
pub const ASPECT_LIMIT: f32 = 4.;
// Swift Float.pi rounds downward; Rust's standard constant has different bits.
const SWIFT_PI: f32 = 3.1415925;
#[derive(Clone, Debug)]
pub struct Orientation {
    pub rotation: Q,
    pub source: &'static str,
    pub notice: Option<String>,
}
#[derive(Clone, Debug)]
pub struct Resolution {
    pub size: V,
    pub scales: V,
    pub basis: &'static str,
    pub aspect: f32,
    pub reason: Option<String>,
}
fn positive(v: V) -> bool {
    v.into_iter().all(|x| x.is_finite() && x > 0.)
}
fn longest(v: V) -> f32 {
    v[0].max(v[1].max(v[2]))
}
pub fn vector(v: &Value) -> Result<V> {
    let mut r = [0.; 3];
    for (i, k) in ["x", "y", "z"].into_iter().enumerate() {
        r[i] = v[k].as_f64().ok_or("world_prop_invalid_measurement")? as f32;
    }
    if !positive(r) {
        return Err("world_prop_invalid_measurement");
    }
    Ok(r)
}
fn wire(v: V) -> Value {
    json!({"x":v[0],"y":v[1],"z":v[2]})
}
fn quaternion(q: Q) -> Value {
    json!({"x":q[0],"y":q[1],"z":q[2],"w":q[3]})
}
fn read_q(v: &Value) -> Result<Q> {
    let mut q = [0.; 4];
    for (i, k) in ["x", "y", "z", "w"].into_iter().enumerate() {
        q[i] = v[k].as_f64().ok_or("world_prop_invalid_orientation")? as f32;
    }
    if !q.into_iter().all(f32::is_finite)
        || (q.into_iter().map(|x| x * x).sum::<f32>() - 1.).abs() > 0.001
    {
        return Err("world_prop_invalid_orientation");
    }
    Ok(q)
}
pub fn is_identity(q: Q) -> bool {
    q.into_iter().all(f32::is_finite)
        && q.into_iter().map(|x| x * x).sum::<f32>() > 0.000001
        && q[..3].iter().all(|x| x.abs() < 0.0001)
        && q[3].abs() > 0.9999
}
pub fn axis_angle(axis: V, angle: f32) -> Q {
    let l = axis.into_iter().map(|x| x * x).sum::<f32>();
    if !l.is_finite() || l <= 0.0000001 || !angle.is_finite() {
        return IDENTITY;
    }
    let inv = 1. / l.sqrt();
    let s = (angle / 2.).sin();
    [
        axis[0] * inv * s,
        axis[1] * inv * s,
        axis[2] * inv * s,
        (angle / 2.).cos(),
    ]
}
/// Apply lhs first, rhs second (rhs * lhs).
pub fn multiply(a: Q, b: Q) -> Q {
    [
        b[3] * a[0] + b[0] * a[3] + b[1] * a[2] - b[2] * a[1],
        b[3] * a[1] - b[0] * a[2] + b[1] * a[3] + b[2] * a[0],
        b[3] * a[2] + b[0] * a[1] - b[1] * a[0] + b[2] * a[3],
        b[3] * a[3] - b[0] * a[0] - b[1] * a[1] - b[2] * a[2],
    ]
}
fn cross(a: V, b: V) -> V {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
pub fn rotate(v: V, q: Q) -> V {
    let l = q.into_iter().map(|x| x * x).sum::<f32>();
    if !q.into_iter().all(f32::is_finite) || l <= 0.000001 {
        return v;
    }
    let inv = 1. / l.sqrt();
    let u = [q[0] * inv, q[1] * inv, q[2] * inv];
    let w = q[3] * inv;
    let uv = cross(u, v);
    let uuv = cross(u, uv);
    std::array::from_fn(|i| v[i] + 2. * (uv[i] * w + uuv[i]))
}
pub fn resolve_orientation(extent: V, up: Option<&str>, forward: Option<&str>) -> Orientation {
    let unresolved = |notice: String| Orientation {
        rotation: IDENTITY,
        source: "unresolved",
        notice: Some(notice),
    };
    if !positive(extent) || extent.into_iter().any(|x| x > 100.) {
        return unresolved("网格尺寸无效，朝向保留原样。".into());
    }
    if let (Some(up), Some(f)) = (up, forward) {
        if ["+Y", "-Y"].contains(&up) && ["+X", "-X", "+Z", "-Z"].contains(&f) {
            let upright = if up == "+Y" {
                IDENTITY
            } else {
                axis_angle([1., 0., 0.], SWIFT_PI)
            };
            let fv = match f {
                "+X" => [1., 0., 0.],
                "-X" => [-1., 0., 0.],
                "+Z" => [0., 0., 1.],
                _ => [0., 0., -1.],
            };
            let fv = rotate(fv, upright);
            let yaw = fv[2].atan2(fv[0]) - SWIFT_PI / 2.;
            let rotation = multiply(upright, axis_angle([0., 1., 0.], yaw));
            let notice = if is_identity(rotation) {
                format!("工作流声明 up_axis={up}、forward_axis={f}，网格本来就是立着的。")
            } else {
                format!("已按工作流声明的 up_axis={up}、forward_axis={f} 摆正。")
            };
            return Orientation {
                rotation,
                source: "workflow-declared",
                notice: Some(notice),
            };
        }
    }
    let horizontal = extent[0].max(extent[2]);
    if extent[1] >= horizontal {
        return Orientation {
            rotation: IDENTITY,
            source: "already-upright",
            notice: None,
        };
    }
    let aspect = horizontal / extent[1];
    if aspect <= ASPECT_LIMIT {
        return unresolved(format!("朝向无法确定（最长水平边 {:.2} m / 高度 {:.2} m = {:.2} ≤ {:.0}，不像躺着生成），保留原始朝向。",horizontal,extent[1],aspect,ASPECT_LIMIT));
    }
    let (axis, rotation) = if extent[0] >= extent[2] {
        ("X", axis_angle([0., 0., 1.], SWIFT_PI / 2.))
    } else {
        ("Z", axis_angle([1., 0., 0.], -SWIFT_PI / 2.))
    };
    Orientation{rotation,source:"inferred-principal-axis",notice:Some(format!("网格最长边在 {axis} 轴（{horizontal:.2} m）、高度只有 {:.2} m（比值 {aspect:.2} > {ASPECT_LIMIT:.0}）⇒ 判定为躺着生成，已摆正；绕竖轴的朝向无法从网格判定。",extent[1]))}
}
pub fn oriented_extent(extent: V, rotation: Q) -> V {
    if is_identity(rotation) {
        return extent;
    }
    let mut low = [f32::MAX; 3];
    let mut high = [-f32::MAX; 3];
    for x in [-extent[0] / 2., extent[0] / 2.] {
        for y in [-extent[1] / 2., extent[1] / 2.] {
            for z in [-extent[2] / 2., extent[2] / 2.] {
                let v = rotate([x, y, z], rotation);
                for i in 0..3 {
                    low[i] = low[i].min(v[i]);
                    high[i] = high[i].max(v[i]);
                }
            }
        }
    }
    std::array::from_fn(|i| high[i] - low[i])
}
pub fn mesh_extent(triangles: &[Triangle]) -> Result<V> {
    if triangles.is_empty() {
        return Err("world_prop_invalid_measurement");
    }
    let mut low = [f32::INFINITY; 3];
    let mut high = [f32::NEG_INFINITY; 3];
    for triangle in triangles {
        for v in triangle {
            for i in 0..3 {
                if !v[i].is_finite() {
                    return Err("world_prop_invalid_measurement");
                }
                low[i] = low[i].min(v[i]);
                high[i] = high[i].max(v[i]);
            }
        }
    }
    let extent = std::array::from_fn(|i| high[i] - low[i]);
    if !positive(extent) {
        return Err("world_prop_invalid_measurement");
    }
    Ok(extent)
}
pub fn axis_size(extent: V, axis: Option<&str>, meters: f32) -> Result<Resolution> {
    if !positive(extent) || !meters.is_finite() || meters <= 0. || meters > 100. {
        return Err("world_prop_invalid_size");
    }
    let max = longest(extent);
    let aspect = max / extent[1];
    if !aspect.is_finite() || aspect <= 0. {
        return Err("world_prop_invalid_size");
    }
    let mut basis = match axis {
        Some("height") => "height",
        Some("longest") => "longestEdge",
        None => {
            if aspect > ASPECT_LIMIT {
                "longestEdge"
            } else {
                "height"
            }
        }
        _ => return Err("invalid_size_intent"),
    };
    let mut scale = meters / if basis == "height" { extent[1] } else { max };
    let rendered = max * scale;
    let mut reason = None;
    if rendered.is_finite() && rendered > MAX_EXTENT {
        scale = MAX_EXTENT / max;
        basis = "clampedMaximum";
        reason=Some(format!("这件物件太长了：按请求尺寸它的最长边会是 {rendered:.2} 米，超过上限 {MAX_EXTENT:.2} 米（房间只有 7 × 8 × 3.2 米），已经缩到最长边 {MAX_EXTENT:.2} 米。"));
    } else if !rendered.is_finite() || rendered < MIN_EXTENT {
        scale = MIN_EXTENT / max;
        basis = "clampedMinimum";
        reason=Some(format!("这件物件太小了：按请求尺寸它的最长边只有 {rendered:.2} 米，低于下限 {MIN_EXTENT:.2} 米（再小在房间里看不见），已经放大到最长边 {MIN_EXTENT:.2} 米。"));
    }
    let size = extent.map(|v| v * scale);
    if !positive(size) || !scale.is_finite() {
        return Err("world_prop_invalid_size");
    }
    Ok(Resolution {
        size,
        scales: [scale; 3],
        basis,
        aspect,
        reason,
    })
}
pub fn dimensions_size(extent: V, mm: V) -> Result<Resolution> {
    if !positive(extent)
        || mm
            .into_iter()
            .any(|v| !v.is_finite() || !(10. ..=3000.).contains(&v))
    {
        return Err("invalid_size_intent");
    }
    let size = mm.map(|v| v / 1000.);
    let max = longest(size);
    if !(MIN_EXTENT..=MAX_EXTENT).contains(&max) {
        return Err("world_prop_dimensions_unrealizable");
    }
    let scales = std::array::from_fn(|i| size[i] / extent[i]);
    if !positive(scales) {
        return Err("world_prop_dimensions_unrealizable");
    }
    // Distortion never substitutes a primitive or rejects explicit dimensions.
    Ok(Resolution {
        size,
        scales,
        basis: "dimensions",
        aspect: longest(extent) / extent[1],
        reason: Some(format!(
            "三轴尺寸逐轴兑现：{} × {} × {} 毫米。",
            mm[0], mm[1], mm[2]
        )),
    })
}
pub fn uniform_factor(current: V, submitted: V) -> Option<f32> {
    if !positive(current) || !positive(submitted) {
        return None;
    }
    let f: V = std::array::from_fn(|i| submitted[i] / current[i]);
    if !f.into_iter().all(f32::is_finite)
        || (f[0] - f[1]).abs() > 0.001 * f[1].abs().max(1.)
        || (f[1] - f[2]).abs() > 0.001 * f[2].abs().max(1.)
    {
        return None;
    }
    Some(f[1])
}
pub fn recorded_baseline(
    raw: V,
    orientation: Option<Q>,
    axis: Option<&str>,
    meters: f32,
) -> Result<V> {
    axis_size(
        orientation.map(|q| oriented_extent(raw, q)).unwrap_or(raw),
        axis,
        meters,
    )
    .map(|r| r.size)
}
pub fn dimension_distortion(extent: V, mm: V) -> Result<f32> {
    let scales = dimensions_size(extent, mm)?.scales;
    let ratio = longest(scales) / scales[0].min(scales[1].min(scales[2]));
    if !ratio.is_finite() {
        return Err("world_prop_dimensions_unrealizable");
    }
    Ok(ratio)
}
pub fn derive(triangles: &[Triangle], wish: &Value, provider_result: &Value) -> Result<Value> {
    let raw = mesh_extent(triangles)?;
    let declared = model::authoritative_size(provider_result)?;
    let orientation = resolve_orientation(
        raw,
        declared.as_ref().map(|v| v.up_axis.as_str()),
        declared.as_ref().map(|v| v.forward_axis.as_str()),
    );
    let extent = oriented_extent(raw, orientation.rotation);
    let height = wish["heightMeters"]
        .as_f64()
        .ok_or("world_prop_invalid_size")? as f32;
    let intent = &wish["sizeIntent"];
    let dimensions = intent["mode"] == "dimensions";
    let mut output = json!({});
    let resolved = if !intent.is_null() {
        // Shared contract parser rejects mixed/unknown shapes and invalid provenance.
        let parsed: model::SizeIntent =
            serde_json::from_value(intent.clone()).map_err(|_| "invalid_size_intent")?;
        parsed.validate()?;
        let source = serde_json::to_value(parsed.source()).map_err(|_| "invalid_size_intent")?;
        if let Some(mm) = parsed.millimeters() {
            let mm = mm.map(|x| x as f32);
            output["sizeIntent"] =
                json!({"axis":"longest","meters":longest(mm)/1000.,"source":source});
            dimensions_size(extent, mm)?
        } else {
            let axis = match parsed.axis().ok_or("invalid_size_intent")? {
                model::SizeIntentAxis::Height => "height",
                model::SizeIntentAxis::Longest => "longest",
            };
            let meters = intent["meters"].as_f64().ok_or("invalid_size_intent")? as f32;
            output["sizeIntent"] = json!({"axis":axis,"meters":meters,"source":source});
            axis_size(extent, Some(axis), meters)?
        }
    } else {
        axis_size(extent, None, height)?
    };
    output["size"] = wire(resolved.size);
    output["sourceHeight"] = json!(extent[1]);
    if !is_identity(orientation.rotation) || orientation.source == "unresolved" {
        output["orientation"] = json!({"rotation":quaternion(orientation.rotation),"source":orientation.source,"notice":orientation.notice});
    }
    if !dimensions {
        if let Some(a) = declared {
            output["authoritativeSize"] = json!({"dimensions":wire(a.dimensions.map(|x|x as f32)),"units":a.units,"upAxis":a.up_axis,"forwardAxis":a.forward_axis});
        }
    }
    if let Some(c) = model::collision_descriptor(provider_result)? {
        if !c.url.starts_with("/v1/jobs/")
            || !c.url.ends_with("/collider.glb")
            || c.url.contains("..")
            || c.url.len() > 256
        {
            return Err("invalid_collision_descriptor");
        }
        output["collision"] = json!({"url":c.url,"format":c.format,"sha256":c.sha256.to_lowercase(),"bytes":c.bytes,"triangles":c.triangles});
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn mesh(v: V) -> Vec<Triangle> {
        vec![
            [[0., 0., 0.], [v[0], 0., v[2]], [0., v[1], 0.]],
            [[v[0], v[1], v[2]], [0., 0., 0.], [0., v[1], v[2]]],
        ]
    }
    fn near(a: f32, b: f32) {
        assert!((a - b).abs() < 0.00001, "{a} != {b}");
    }
    fn sword() -> V {
        [1.005432367324829, 0.1334928721189499, 0.05656638368964195]
    }
    fn wish() -> Value {
        json!({"heightMeters":1.1})
    }
    fn identity() -> Value {
        json!({"objectID":"sword","sourceWishID":"wish","assetID":"sha256:a","displayName":"白色长剑"})
    }
    fn prop(measured: &Value) -> Value {
        let mut p = identity();
        for (k, v) in measured.as_object().unwrap() {
            p[k] = v.clone();
        }
        p
    }
    #[test]
    fn sword_xyz_stands_up_then_scales_once() {
        let out = derive(&mesh(sword()), &wish(), &json!({})).unwrap();
        let size = vector(&out["size"]).unwrap();
        near(size[1], 1.1);
        assert!(size[1] > size[0]);
        assert_eq!(out["orientation"]["source"], "inferred-principal-axis");
        let q = read_q(&out["orientation"]["rotation"]).unwrap();
        // Golden values from the actual compiled WorldRuntime pure policy.
        assert_eq!(q, [0., 0., 0.70710677, 0.7071068]);
        assert_eq!(size, [0.14604884, 1.1, 0.061886825]);
        assert_eq!(out["sourceHeight"].as_f64().unwrap() as f32, 1.0054325);
        assert_eq!(rebase_fingerprint(&prop(&out)).unwrap(), "13307684c1c89630");
        let tip = rotate([1., 0., 0.], q);
        near(tip[0], 0.);
        near(tip[1], 1.);
        near(tip[2], 0.);
        near(out["sourceHeight"].as_f64().unwrap() as f32, sword()[0]);
    }
    #[test]
    fn declared_all_axes_map_up_y_and_front_positive_z() {
        for up in ["+Y", "-Y"] {
            for f in ["+X", "-X", "+Z", "-Z"] {
                let o = resolve_orientation([0.4, 1., 0.5], Some(up), Some(f));
                assert_eq!(o.source, "workflow-declared");
                let uv = if up == "+Y" {
                    [0., 1., 0.]
                } else {
                    [0., -1., 0.]
                };
                let fv = match f {
                    "+X" => [1., 0., 0.],
                    "-X" => [-1., 0., 0.],
                    "+Z" => [0., 0., 1.],
                    _ => [0., 0., -1.],
                };
                let u = rotate(uv, o.rotation);
                let forward = rotate(fv, o.rotation);
                for i in 0..3 {
                    near(u[i], [0., 1., 0.][i]);
                    near(forward[i], [0., 0., 1.][i]);
                }
            }
        }
    }
    #[test]
    fn lying_z_and_horizontal_ties_follow_old_principal_axis_rule() {
        near(
            rotate(
                [0., 0., 1.],
                resolve_orientation([0.2, 0.1, 1.], None, None).rotation,
            )[1],
            1.,
        );
        near(
            rotate(
                [1., 0., 0.],
                resolve_orientation([1., 0.1, 1.], None, None).rotation,
            )[1],
            1.,
        );
        assert_eq!(
            resolve_orientation([1., 0.25, 1.], None, None).source,
            "unresolved"
        );
        assert_eq!(
            resolve_orientation([0.2, 1., 0.3], None, None).source,
            "already-upright"
        );
        assert_eq!(
            resolve_orientation(sword(), Some("+X"), Some("+Z")).source,
            "inferred-principal-axis"
        );
    }
    #[test]
    fn quaternion_arithmetic_and_eight_corner_bounds_preserve_xyz() {
        let a = axis_angle([0., 0., 1.], std::f32::consts::FRAC_PI_2);
        let b = axis_angle([0., 1., 0.], 0.7);
        let v = [0.2, 0.3, 0.8];
        let one = rotate(v, multiply(a, b));
        let two = rotate(rotate(v, a), b);
        for i in 0..3 {
            near(one[i], two[i]);
        }
        let extent = oriented_extent(
            [2., 1., 3.],
            axis_angle([0., 1., 0.], std::f32::consts::FRAC_PI_4),
        );
        near(extent[0], 5. / 2f32.sqrt());
        near(extent[2], 5. / 2f32.sqrt());
        near(extent[1], 1.);
        assert_eq!(oriented_extent(sword(), IDENTITY), sword());
        assert!(is_identity([0., 0., 0., -1.]));
    }
    #[test]
    fn automatic_and_axis_intent_keep_uniform_scale_and_threshold() {
        let a = axis_size(sword(), None, 1.1).unwrap();
        near(longest(a.size), 1.1);
        assert_eq!(a.basis, "longestEdge");
        assert_eq!(a.scales, [a.scales[0]; 3]);
        let machine = [0.62, 0.46, 0.51];
        assert_eq!(
            axis_size(machine, None, 0.35).unwrap().size,
            axis_size(machine, Some("height"), 0.35).unwrap().size
        );
        assert_eq!(
            axis_size([1., 0.25, 0.5], None, 0.5).unwrap().basis,
            "height"
        );
        let high = axis_size(sword(), Some("height"), 1.1).unwrap();
        assert_eq!(high.basis, "clampedMaximum");
        near(longest(high.size), 3.);
        assert!(high.reason.unwrap().contains("太长了"));
        let low = axis_size(sword(), Some("longest"), 0.001).unwrap();
        assert_eq!(low.basis, "clampedMinimum");
        near(longest(low.size), 0.02);
    }
    #[test]
    fn dimensions_millimeters_each_axis_exact_even_large_distortion() {
        let mm = [1443., 862., 302.];
        let source = [1.008, 0.629, 1.008];
        let result = dimensions_size(source, mm).unwrap();
        assert_eq!(result.size, mm.map(|v| v / 1000.));
        assert_ne!(result.scales[0], result.scales[2]);
        assert_eq!(result.basis, "dimensions");
        assert!(dimension_distortion(source, mm).unwrap() > 4.);
        assert!(dimensions_size(source, [10., 10., 10.]).is_err());
        assert!(dimensions_size(source, [10., 20., 10.]).is_ok());
        assert!(dimensions_size(source, [3001., 862., 302.]).is_err());
    }
    #[test]
    fn derive_dimensions_projects_intent_and_omits_provider_size() {
        let w = json!({"heightMeters":0.862,"sizeIntent":{"mode":"dimensions","millimeters":{"x":1443,"y":862,"z":302},"source":"user"}});
        let r = json!({"authoritative_size":{"dimensions":[1.443,0.862,0.302],"units":"m","up_axis":"+Y","forward_axis":"+Z"}});
        let out = derive(&mesh([1.008, 0.629, 1.008]), &w, &r).unwrap();
        assert_eq!(vector(&out["size"]).unwrap(), [1.443, 0.862, 0.302]);
        assert!(out.get("authoritativeSize").is_none());
        assert_eq!(out["sizeIntent"]["axis"], "longest");
        assert_eq!(out["sizeIntent"]["source"], "user");
        assert!(out.get("primitive").is_none());
    }
    #[test]
    fn provider_metadata_and_nil_fields_do_not_silently_change_shape() {
        let base = derive(&mesh([0.4, 1., 0.5]), &wish(), &json!({})).unwrap();
        assert!(base.get("orientation").is_none());
        assert!(base.get("collision").is_none());
        assert!(base.get("sizeIntent").is_none());
        assert!(derive(
            &mesh(sword()),
            &wish(),
            &json!({"collision_format":"glb-hull"})
        )
        .is_err());
        assert!(derive(&mesh(sword()),&wish(),&json!({"authoritative_size":{"dimensions":[1,1,1],"units":"m","up_axis":"+X","forward_axis":"+Z"}})).is_err());
        let r = json!({"collision_url":"/v1/jobs/one/collider.glb","collision_format":"glb-hull","collision_sha256":"A".repeat(64),"collision_bytes":12,"collision_triangles":2});
        assert_eq!(
            derive(&mesh(sword()), &wish(), &r).unwrap()["collision"]["sha256"],
            "a".repeat(64)
        );
    }
    #[test]
    fn recorded_baseline_stays_in_archives_own_coordinate_frame() {
        let raw = sword();
        let old = recorded_baseline(raw, None, None, 1.1).unwrap();
        let q = resolve_orientation(raw, None, None).rotation;
        let modern = recorded_baseline(raw, Some(q), None, 1.1).unwrap();
        assert_ne!(old, modern);
        assert_eq!(old, axis_size(raw, None, 1.1).unwrap().size);
        assert_eq!(
            modern,
            axis_size(oriented_extent(raw, q), None, 1.1).unwrap().size
        );
    }
    #[test]
    fn manual_resize_preserves_audit_orientation_and_proxy() {
        let mut p = prop(&derive(&mesh(sword()), &wish(), &json!({})).unwrap());
        p["sizeIntent"] = json!({"axis":"longest","meters":1.1,"source":"user"});
        p["collision"] = json!({"fixture":"proxy"});
        p["primitive"] = json!({"old":true});
        p["authoritativeSize"] = json!({"dimensions":{"x":9,"y":9,"z":9}});
        let out = manual_resize(&p, 1.6).unwrap();
        near(longest(vector(&out["size"]).unwrap()), 1.6);
        assert_eq!(out["sizeLocked"], true);
        for key in ["sizeIntent", "orientation", "collision", "sourceHeight"] {
            assert_eq!(out[key], p[key]);
        }
        assert!(out.get("primitive").is_none());
        assert!(out.get("authoritativeSize").is_none());
        assert_eq!(
            manual_resize(&p, 0.001).unwrap_err(),
            "world_prop_size_too_small"
        );
        assert_eq!(
            manual_resize(&p, 3.1).unwrap_err(),
            "world_prop_size_too_large"
        );
    }
    #[test]
    fn rebase_old_sword_derived_only_idempotent_and_refuses_other_mesh() {
        let triangles = mesh(sword());
        let modern = prop(&derive(&triangles, &wish(), &json!({})).unwrap());
        let mut old = identity();
        old["size"] = wire(axis_size(sword(), None, 1.1).unwrap().size);
        old["sourceHeight"] = json!(sword()[1]);
        old["collision"] = json!({"keep":"exact"});
        let result = rebase(&old, &modern, &triangles, 1.1, "rebase.job").unwrap();
        assert_eq!(result["verdict"], "rebase");
        let healed = &result["prop"];
        assert_eq!(healed["collision"], old["collision"]);
        assert_eq!(healed["orientation"], modern["orientation"]);
        assert_eq!(healed["size"], modern["size"]);
        assert_eq!(
            rebase(healed, &modern, &triangles, 1.1, "rebase.job").unwrap()["verdict"],
            "unchanged"
        );
        old["size"] = wire([0.7, 0.8, 0.9]);
        assert_eq!(
            rebase(&old, &modern, &triangles, 1.1, "r").unwrap_err(),
            "world_prop_rebase_shape_mismatch"
        );
        old["assetID"] = json!("other");
        assert_eq!(
            rebase(&old, &modern, &triangles, 1.1, "r").unwrap_err(),
            "world_prop_ownership_mismatch"
        );
    }
    #[test]
    fn invalid_measurements_intents_and_nonuniform_factors_fail_closed() {
        assert!(mesh_extent(&[]).is_err());
        assert!(mesh_extent(&mesh([0., 1., 1.])).is_err());
        assert!(mesh_extent(&mesh([f32::NAN, 1., 1.])).is_err());
        assert!(axis_size([1., 1., 1.], Some("width"), 1.).is_err());
        assert!(axis_size([1., 1., 1.], None, f32::NAN).is_err());
        assert!(uniform_factor([1., 2., 3.], [2., 4., 7.]).is_none());
        assert_eq!(uniform_factor([1., 2., 3.], [2., 4., 6.]), Some(2.));
        assert!(derive(&mesh(sword()),&json!({"heightMeters":1.1,"sizeIntent":{"axis":"longest","meters":1.1,"source":"invented"}}),&json!({})).is_err());
    }
}
pub fn effective_size(prop: &Value) -> Result<V> {
    if prop["sizeLocked"] == true || !prop["sizeIntent"].is_null() {
        return vector(&prop["size"]);
    }
    if !prop["authoritativeSize"].is_null() {
        return vector(&prop["authoritativeSize"]["dimensions"]);
    }
    vector(&prop["size"])
}
pub fn manual_resize(prop: &Value, target_longest: f32) -> Result<Value> {
    let current = effective_size(prop)?;
    if !target_longest.is_finite() || target_longest <= 0. {
        return Err("world_prop_invalid_size");
    }
    if target_longest < MIN_EXTENT {
        return Err("world_prop_size_too_small");
    }
    if target_longest > MAX_EXTENT {
        return Err("world_prop_size_too_large");
    }
    let factor = target_longest / longest(current);
    if !factor.is_finite() || factor <= 0. {
        return Err("world_prop_invalid_size");
    }
    let mut output = prop.clone();
    let object = output.as_object_mut().ok_or("world_prop_invalid_input")?;
    object.insert("size".into(), wire(current.map(|v| v * factor)));
    object.insert("sizeLocked".into(), json!(true));
    object.remove("authoritativeSize");
    object.remove("primitive");
    Ok(output)
}
pub fn rebase(
    stored: &Value,
    derived: &Value,
    triangles: &[Triangle],
    requested_height: f32,
    request_prefix: &str,
) -> Result<Value> {
    for key in ["objectID", "sourceWishID", "assetID", "displayName"] {
        if stored[key] != derived[key] {
            return Err("world_prop_ownership_mismatch");
        }
    }
    let old = vector(&stored["size"])?;
    let new = vector(&derived["size"])?;
    if old == new
        || stored["sizeLocked"] == true
        || derived["sizeLocked"] == true
        || !stored["sizeIntent"].is_null()
        || !derived["sizeIntent"].is_null()
    {
        return Ok(json!({"verdict":"unchanged"}));
    }
    if old.into_iter().chain(new).any(|v| v > 100.) {
        return Err("world_prop_invalid_size");
    }
    let raw = mesh_extent(triangles)?;
    let q = if derived["orientation"].is_null() {
        IDENTITY
    } else {
        read_q(&derived["orientation"]["rotation"])?
    };
    let oriented = oriented_extent(raw, q);
    if uniform_factor(raw, old).is_none() && uniform_factor(oriented, old).is_none() {
        return Err("world_prop_rebase_shape_mismatch");
    }
    let mut healed = stored.clone();
    let obj = healed.as_object_mut().ok_or("world_prop_invalid_input")?;
    let mut changes = Vec::new();
    for key in ["size", "sourceHeight", "orientation"] {
        if stored[key] != derived[key] {
            changes.push(json!({"field":key,"from":stored[key],"to":derived[key]}));
        }
        if let Some(value) = derived.get(key) {
            obj.insert(key.into(), value.clone());
        } else {
            obj.remove(key);
        }
    }
    let source = healed["sourceHeight"]
        .as_f64()
        .ok_or("world_prop_invalid_measurement")? as f32;
    if !source.is_finite() || source <= 0. || source > 100. || !(new[1] / source).is_finite() {
        return Err("world_prop_invalid_measurement");
    }
    let hash = rebase_fingerprint(&healed)?;
    Ok(
        json!({"verdict":"rebase","prop":healed,"record":{"objectID":stored["objectID"],"displayName":stored["displayName"],"requestID":format!("{request_prefix}.{hash}"),"changes":changes,"explanation":format!("同一份已核验网格，原始尺寸 {:?}、摆正后 {:?}，请求高度 {requested_height:.2} 米；保留用户字段，仅对齐派生尺寸、高度基准与朝向。",raw,oriented)}}),
    )
}

// Keep the legacy content-addressed receipt suffix: derived values at six
// decimals, raw Float32 quaternion spelling, then FNV-1a (not a security hash).
fn swift_float(v: f32) -> String {
    let s = format!("{v:?}");
    if let Some((mantissa, exponent)) = s.split_once('e') {
        if let Ok(exponent) = exponent.parse::<i32>() {
            return format!("{mantissa}e{exponent:+03}");
        }
    }
    s
}
pub fn rebase_fingerprint(prop: &Value) -> Result<String> {
    let size = vector(&prop["size"])?;
    let source = prop["sourceHeight"]
        .as_f64()
        .ok_or("world_prop_invalid_measurement")? as f32;
    let orientation = if prop["orientation"].is_null() {
        "none".to_owned()
    } else {
        let q = read_q(&prop["orientation"]["rotation"])?;
        format!(
            "{}:{},{},{},{}",
            prop["orientation"]["source"]
                .as_str()
                .ok_or("world_prop_invalid_orientation")?,
            swift_float(q[0]),
            swift_float(q[1]),
            swift_float(q[2]),
            swift_float(q[3])
        )
    };
    let canonical = format!(
        "{}|{}|{:.6}|{:.6}|{:.6}|{:.6}|{}|{}",
        prop["objectID"]
            .as_str()
            .ok_or("world_prop_invalid_input")?,
        prop["assetID"].as_str().ok_or("world_prop_invalid_input")?,
        size[0],
        size[1],
        size[2],
        source,
        prop["sizeLocked"] == true,
        orientation
    );
    let mut hash = 0xcbf29ce484222325u64;
    for byte in canonical.bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    Ok(format!("{hash:x}"))
}
