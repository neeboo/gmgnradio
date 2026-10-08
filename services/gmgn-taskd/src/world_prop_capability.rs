//! Closed authored prop capabilities. Names/meshes never imply executable use.
use crate::model::Result;
use serde_json::{json, Value};
pub const METADATA_KEY: &str = "gmgn.prop-capability.v1";
pub const SUPPORTED: &[&str] = &["coffee.brew"];
pub const INTERACTION_REACH: f32 = 0.6;
pub const WAYPOINT_DISCOVERY_DISTANCE: f32 = 2.5;
fn object_id(prop: &Value) -> Result<&str> {
    prop["objectID"]
        .as_str()
        .filter(|s| !s.is_empty() && s.chars().count() <= 256)
        .ok_or("prop_capability_invalid_object")
}
fn template(id: &str) -> Result<()> {
    if SUPPORTED.contains(&id) {
        Ok(())
    } else {
        Err("prop_capability_unsupported_template")
    }
}
pub fn proposal(prop: &Value, template_id: &str) -> Result<Value> {
    let object = object_id(prop)?;
    template(template_id)?;
    Ok(json!({"objectID":object,"templateID":template_id}))
}
pub fn activity_id(object_id: &str, template_id: &str) -> Result<String> {
    template(template_id)?;
    if object_id.is_empty() || object_id.chars().count() > 256 {
        return Err("prop_capability_invalid_object");
    }
    Ok(format!("{template_id}@{object_id}"))
}
/// Same Codable LifeActivityDefinition shape consumed by activity_catalog_build.
/// No enter duration: only a matching native playback receipt may complete it.
pub fn definition(prop: &Value, template_id: &str) -> Result<Value> {
    let object = object_id(prop)?;
    let id = activity_id(object, template_id)?;
    let phases=["approach","enter","loop","exit","interrupt","failed"].map(|phase|{
        let mut p=json!({"phase":phase,"requiredAnchorIDs":if phase=="approach"{json!([object])}else{json!([])},"motionIDs":match phase{"approach"=>json!(["gmgn.motion.bones.walk-loop-pmx","gmgn.motion.bones.walk-loop-vrm"]),"enter"=>json!(["gmgn.motion.bones.arpg.interact-button-mid-vrm","gmgn.motion.bones.arpg.interact-button-mid-pmx"]),_=>json!([])},"propIDs":[]});
        if phase=="loop"||phase=="exit"{p["durationSeconds"]=json!(0);}p
    });
    Ok(
        json!({"id":id,"displayName":"冲泡一杯咖啡","activity":{"type":"interact","anchorID":object},"phases":phases,"interruptible":true,"cooldownSeconds":45}),
    )
}
/// Bindings are proposals only; reducer owns actual standing/navigation proof.
pub fn usage_binding(prop: &Value, template_id: &str) -> Result<(String, Value)> {
    Ok((
        activity_id(object_id(prop)?, template_id)?,
        proposal(prop, template_id)?,
    ))
}
/// Enabled, truly standable waypoints only; equal distance uses the real ID.
pub fn operation_anchor_candidates(
    center: [f32; 3],
    waypoints: &[Value],
    mut can_stand: impl FnMut([f32; 3]) -> bool,
) -> Vec<Value> {
    let mut candidates = Vec::new();
    for waypoint in waypoints {
        if waypoint["enabled"] != true {
            continue;
        }
        let Some(id) = waypoint["id"].as_str() else {
            continue;
        };
        let p = &waypoint["position"];
        let (Some(x), Some(y), Some(z)) = (p["x"].as_f64(), p["y"].as_f64(), p["z"].as_f64())
        else {
            continue;
        };
        let position = [x as f32, y as f32, z as f32];
        if position.iter().any(|v| !v.is_finite()) {
            continue;
        }
        let distance =
            ((position[0] - center[0]).powi(2) + (position[2] - center[2]).powi(2)).sqrt();
        if distance > 0. && distance <= WAYPOINT_DISCOVERY_DISTANCE && can_stand(position) {
            candidates.push((distance, id.to_owned(), waypoint.clone()));
        }
    }
    candidates.sort_by(|a, b| a.0.total_cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    candidates.into_iter().map(|(_, _, v)| v).collect()
}
pub fn footprint_edge_distance(point: [f32; 3], center: [f32; 3], yaw: f32, half: [f32; 3]) -> f32 {
    let dx = point[0] - center[0];
    let dz = point[2] - center[2];
    let distance = (dx * dx + dz * dz).sqrt();
    let (local_x, local_z) = (
        yaw.cos() * dx + yaw.sin() * dz,
        -yaw.sin() * dx + yaw.cos() * dz,
    );
    let boundary_x = if local_x.abs() > 1e-6 {
        half[0] * distance / local_x.abs()
    } else {
        f32::INFINITY
    };
    let boundary_z = if local_z.abs() > 1e-6 {
        half[2] * distance / local_z.abs()
    } else {
        f32::INFINITY
    };
    distance - boundary_x.min(boundary_z)
}
/// Ground/capsule collision remains an injected real resolver; first blocked
/// step fails rather than assuming that the machine can be used from afar.
pub fn final_approach_point(
    waypoint: [f32; 3],
    center: [f32; 3],
    yaw: f32,
    half: [f32; 3],
    mut resolve: impl FnMut([f32; 3]) -> Option<[f32; 3]>,
) -> Option<[f32; 3]> {
    if waypoint
        .iter()
        .chain(center.iter())
        .chain(half.iter())
        .any(|v| !v.is_finite())
        || !yaw.is_finite()
    {
        return None;
    }
    let dx = center[0] - waypoint[0];
    let dz = center[2] - waypoint[2];
    let distance = (dx * dx + dz * dz).sqrt();
    if distance <= 0. {
        return None;
    }
    let mut travelled = 0.;
    while travelled < 2_f32.min(distance) {
        travelled = (travelled + 0.05_f32).min(distance);
        let grounded = resolve([
            waypoint[0] + dx / distance * travelled,
            waypoint[1],
            waypoint[2] + dz / distance * travelled,
        ])?;
        let edge = footprint_edge_distance(grounded, center, yaw, half);
        if !edge.is_finite() || edge <= 0. {
            return None;
        }
        if edge <= INTERACTION_REACH {
            return Some(grounded);
        }
    }
    None
}

fn point(value: &Value) -> Result<[f32; 3]> {
    let mut result = [0.; 3];
    for (i, key) in ["x", "y", "z"].iter().enumerate() {
        result[i] = value[key]
            .as_f64()
            .filter(|v| v.is_finite() && v.abs() <= 10000.)
            .ok_or("prop_capability_invalid_geometry")? as f32;
    }
    Ok(result)
}
fn position(p: [f32; 3]) -> Value {
    json!({"x":p[0],"y":p[1],"z":p[2]})
}
fn required<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("prop_capability_invalid_input")
}
struct OperationPlan {
    output: Value,
    center: [f32; 3],
    yaw: f32,
    half: [f32; 3],
    minimum: f32,
}
fn operation_plan(connection: &rusqlite::Connection, input: &Value) -> Result<OperationPlan> {
    let world = required(input, "worldID")?;
    let object = required(input, "objectID")?;
    required(input, "hostSessionID")?;
    let kind = required(input, "kind")?;
    if !["capability", "objectDestination"].contains(&kind) {
        return Err("prop_capability_invalid_input");
    }
    let state =
        crate::world::materialize(connection, world)?.ok_or("prop_capability_world_missing")?;
    if state["layoutRevision"].as_u64() != input["expectedLayoutRevision"].as_u64()
        || input["expectedLayoutRevision"].as_u64().is_none()
    {
        return Err("prop_capability_stale_layout");
    }
    let item = &state["objectStates"][object];
    if item["isEnabled"] != true {
        return Err("prop_capability_object_unavailable");
    }
    let generated: Value = serde_json::from_str(
        item["metadata"][crate::world::GENERATED_PROP_KEY]
            .as_str()
            .ok_or("prop_capability_invalid_object")?,
    )
    .map_err(|_| "prop_capability_invalid_object")?;
    if object_id(&generated)? != object {
        return Err("prop_capability_invalid_object");
    }
    let center = point(&item["transform"]["position"])?;
    let q = &item["transform"]["rotation"];
    let y = q["y"]
        .as_f64()
        .filter(|n| n.is_finite())
        .ok_or("prop_capability_invalid_geometry")? as f32;
    let w = q["w"]
        .as_f64()
        .filter(|n| n.is_finite())
        .ok_or("prop_capability_invalid_geometry")? as f32;
    let yaw = (2. * w * y).atan2(1. - 2. * y * y);
    let dimensions = if generated["sizeLocked"] == true
        || generated.get("sizeIntent").is_some_and(|v| !v.is_null())
    {
        &generated["size"]
    } else {
        generated
            .pointer("/authoritativeSize/dimensions")
            .unwrap_or(&generated["size"])
    };
    let size = point(dimensions)?;
    let scale = point(&item["transform"]["scale"])?;
    if size.iter().any(|n| *n <= 0. || *n > 100.)
        || scale.iter().any(|n| n.abs() <= 0. || n.abs() > 100.)
    {
        return Err("prop_capability_invalid_geometry");
    }
    let half = [
        size[0] * scale[0].abs() / 2.,
        size[1] * scale[1].abs() / 2.,
        size[2] * scale[2].abs() / 2.,
    ];
    let radius = input["capsuleRadius"]
        .as_f64()
        .filter(|n| n.is_finite() && *n > 0. && *n <= 10.)
        .ok_or("prop_capability_invalid_geometry")? as f32;
    let minimum = if kind == "objectDestination" {
        radius + 0.05
    } else {
        0.
    };
    let definition = if kind == "capability" {
        let capability: Value = serde_json::from_str(
            item["metadata"][METADATA_KEY]
                .as_str()
                .ok_or("prop_capability_unsupported_template")?,
        )
        .map_err(|_| "prop_capability_unsupported_template")?;
        if capability["objectID"] != object {
            return Err("prop_capability_invalid_object");
        }
        let template_id = required(&capability, "templateID")?;
        json!({"definition":definition(&generated,template_id)?,"usageBinding":usage_binding(&generated,template_id)?.1})
    } else {
        json!({})
    };
    let waypoints = input["waypoints"]
        .as_array()
        .filter(|v| v.len() <= 64)
        .ok_or("prop_capability_capacity")?;
    let mut ids = std::collections::BTreeSet::new();
    for waypoint in waypoints {
        if !ids.insert(required(waypoint, "id")?) || !waypoint["enabled"].is_boolean() {
            return Err("prop_capability_invalid_input");
        }
        point(&waypoint["position"])?;
    }
    // Rust alone chooses order, search radius and all intermediate positions.
    let candidates = operation_anchor_candidates(center, waypoints, |_| true);
    let mut probes = Vec::new();
    for waypoint in &candidates {
        let p = point(&waypoint["position"])?;
        let id = required(waypoint, "id")?;
        probes.push(json!({"key":format!("{id}:origin"),"waypointID":id,"position":position(p),"from":Value::Null}));
        let dx = center[0] - p[0];
        let dz = center[2] - p[2];
        let distance = (dx * dx + dz * dz).sqrt();
        let mut travelled = 0.;
        let mut step = 0;
        while travelled < 2_f32.min(distance) {
            travelled = (travelled + 0.05_f32).min(distance);
            step += 1;
            probes.push(json!({"key":format!("{id}:{step}"),"waypointID":id,"position":position([p[0]+dx/distance*travelled,p[1],p[2]+dz/distance*travelled]),"from":position(p)}));
        }
    }
    let source = json!({"worldID":world,"hostSessionID":input["hostSessionID"],"objectID":object,
        "kind":kind,"layoutRevision":state["layoutRevision"],"item":item,"waypoints":waypoints,"capsuleRadius":radius});
    use sha2::{Digest, Sha256};
    let geometry = format!(
        "{:x}",
        Sha256::digest(
            crate::canonical_json::to_string(&source)
                .map_err(|_| "prop_capability_invalid_input")?
                .as_bytes()
        )
    );
    let mut output = definition;
    output["geometryID"] = json!(geometry);
    output["layoutRevision"] = state["layoutRevision"].clone();
    output["probes"] = json!(probes);
    output["candidates"] = json!(candidates);
    Ok(OperationPlan {
        output,
        center,
        yaw,
        half,
        minimum,
    })
}
/// Authenticated native read-only proposal/proof exchange. Never a model tool,
/// never a world mutation, and every resolution re-reads the actual SQLite object.
pub fn request(connection: &rusqlite::Connection, method: &str, input: Value) -> Result<Value> {
    let plan = operation_plan(connection, &input)?;
    if method == "world_prop_capability_plan" {
        return Ok(plan.output);
    }
    if method != "world_prop_capability_resolve" {
        return Err("unknown_method");
    }
    if input["geometryID"] != plan.output["geometryID"] {
        return Err("prop_capability_stale_geometry");
    }
    let probes = plan.output["probes"].as_array().unwrap();
    let facts = input["physics"]
        .as_array()
        .filter(|v| v.len() == probes.len())
        .ok_or("prop_capability_invalid_physics")?;
    let mut measured = std::collections::BTreeMap::new();
    for (probe, fact) in probes.iter().zip(facts) {
        if fact["key"] != probe["key"]
            || point(&fact["position"])? != point(&probe["position"])?
            || !fact["canTraverse"].is_boolean()
        {
            return Err("prop_capability_invalid_physics");
        }
        if !fact["grounded"].is_null() {
            let grounded = point(&fact["grounded"])?;
            let sampled = point(&probe["position"])?;
            if grounded[0] != sampled[0] || grounded[2] != sampled[2] {
                return Err("prop_capability_invalid_physics");
            }
        }
        measured.insert(probe["key"].as_str().unwrap(), fact);
    }
    let mut target = Value::Null;
    for waypoint in plan.output["candidates"].as_array().unwrap() {
        let id = waypoint["id"].as_str().unwrap();
        let origin = point(&waypoint["position"])?;
        if measured[format!("{id}:origin").as_str()]["grounded"].is_null() {
            continue;
        }
        let edge = footprint_edge_distance(origin, plan.center, plan.yaw, plan.half);
        if edge <= INTERACTION_REACH {
            if edge >= plan.minimum {
                target = json!({"waypointID":id,"approachPoint":Value::Null,"standPoint":position(origin)});
                break;
            }
            continue;
        }
        for probe in probes
            .iter()
            .filter(|p| p["waypointID"] == id && !p["from"].is_null())
        {
            let fact = measured[probe["key"].as_str().unwrap()];
            if fact["grounded"].is_null() {
                break;
            }
            let grounded = point(&fact["grounded"])?;
            let edge = footprint_edge_distance(grounded, plan.center, plan.yaw, plan.half);
            if !edge.is_finite() || edge <= 0. {
                break;
            }
            if edge <= INTERACTION_REACH {
                if edge >= plan.minimum && fact["canTraverse"] == true {
                    target = json!({"waypointID":id,"approachPoint":position(grounded),"standPoint":position(grounded)});
                }
                break;
            }
        }
        if !target.is_null() {
            break;
        }
    }
    if !target.is_null() {
        let p = point(&target["standPoint"])?;
        target["targetYaw"] = json!((plan.center[0] - p[0]).atan2(plan.center[2] - p[2]));
    }
    let mut output = plan.output;
    output.as_object_mut().unwrap().remove("probes");
    output.as_object_mut().unwrap().remove("candidates");
    output["target"] = target;
    Ok(output)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn actual_world() -> rusqlite::Connection {
        use sha2::{Digest, Sha256};
        let mut c = rusqlite::Connection::open_in_memory().unwrap();
        crate::world::schema(&c).unwrap();
        let prop = json!({"objectID":"machine","size":{"x":0.4,"y":0.7,"z":0.4}});
        let state = json!({"worldID":"capability-fixture","revision":0,"layoutRevision":7,
            "objectStates":{"machine":{"isEnabled":true,"transform":{"position":position([0.;3]),
                "rotation":{"x":0,"y":0,"z":0,"w":1},"scale":position([1.;3])},
                "metadata":{crate::world::GENERATED_PROP_KEY:prop.to_string(),METADATA_KEY:
                    json!({"objectID":"machine","templateID":"coffee.brew"}).to_string()}}}});
        let bytes = state.to_string();
        let tx = c.transaction().unwrap();
        crate::world::import(
            &tx,
            &crate::world::ImportRequest {
                world_id: "capability-fixture".into(),
                request_id: "fixture-import".into(),
                producer: Some("private-test".into()),
                package_id: "fixture".into(),
                package_version: "1".into(),
                state_sha256: format!("{:x}", Sha256::digest(bytes.as_bytes())),
                state_json: bytes,
            },
        )
        .unwrap();
        tx.commit().unwrap();
        c
    }
    fn raw(kind: &str) -> Value {
        json!({"worldID":"capability-fixture","hostSessionID":"actual-host","objectID":"machine",
            "expectedLayoutRevision":7,"kind":kind,"capsuleRadius":0.2,
            "waypoints":[{"id":"far","position":position([1.,0.,0.]),"enabled":true,"arrivalRadius":0.05}]})
    }
    fn physics(plan: &Value, blocked: bool) -> Value {
        json!(plan["probes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| json!({"key":p["key"],"position":p["position"],
            "grounded":if blocked {Value::Null}else{p["position"].clone()},"canTraverse":!blocked}))
            .collect::<Vec<_>>())
    }
    #[test]
    fn actual_sql_capability_definition_and_near_target_not_native_candidate() {
        let c = actual_world();
        let mut input = raw("capability");
        input["nativeCandidate"] = json!({"standPoint":position([99.,0.,0.])});
        let plan = request(&c, "world_prop_capability_plan", input.clone()).unwrap();
        assert_eq!(plan["definition"]["id"], "coffee.brew@machine");
        assert_eq!(
            plan["usageBinding"],
            json!({"objectID":"machine","templateID":"coffee.brew"})
        );
        input["geometryID"] = plan["geometryID"].clone();
        input["physics"] = physics(&plan, false);
        let receipt = request(&c, "world_prop_capability_resolve", input).unwrap();
        let p = point(&receipt["target"]["standPoint"]).unwrap();
        assert!(footprint_edge_distance(p, [0.; 3], 0., [0.2, 0.35, 0.2]) <= INTERACTION_REACH);
        assert_eq!(receipt["target"]["waypointID"], "far");
        assert_eq!(
            crate::world::materialize(&c, "capability-fixture")
                .unwrap()
                .unwrap()["revision"],
            0
        );
    }
    #[test]
    fn raw_physics_false_no_remote_use_and_clearance_is_rust_owned() {
        let c = actual_world();
        let mut input = raw("capability");
        let plan = request(&c, "world_prop_capability_plan", input.clone()).unwrap();
        input["geometryID"] = plan["geometryID"].clone();
        input["physics"] = physics(&plan, true);
        assert!(request(&c, "world_prop_capability_resolve", input).unwrap()["target"].is_null());
        let mut near = raw("objectDestination");
        near["waypoints"][0]["position"] = position([0.4, 0., 0.]);
        let plan = request(&c, "world_prop_capability_plan", near.clone()).unwrap();
        near["geometryID"] = plan["geometryID"].clone();
        near["physics"] = physics(&plan, false);
        assert!(request(&c, "world_prop_capability_resolve", near).unwrap()["target"].is_null());
    }
    #[test]
    fn wrong_identity_layout_or_raw_physics_cannot_confirm() {
        let c = actual_world();
        let mut input = raw("capability");
        let plan = request(&c, "world_prop_capability_plan", input.clone()).unwrap();
        input["geometryID"] = plan["geometryID"].clone();
        input["physics"] = physics(&plan, false);
        let mut wrong = input.clone();
        wrong["hostSessionID"] = json!("different-host");
        assert_eq!(
            request(&c, "world_prop_capability_resolve", wrong).unwrap_err(),
            "prop_capability_stale_geometry"
        );
        let mut wrong = input.clone();
        wrong["expectedLayoutRevision"] = json!(6);
        assert_eq!(
            request(&c, "world_prop_capability_resolve", wrong).unwrap_err(),
            "prop_capability_stale_layout"
        );
        let mut shifted = input.clone();
        shifted["physics"][0]["grounded"] = position([99., 0., 0.]);
        assert_eq!(
            request(&c, "world_prop_capability_resolve", shifted).unwrap_err(),
            "prop_capability_invalid_physics"
        );
        input["physics"][0]["position"] = position([99., 0., 0.]);
        assert_eq!(
            request(&c, "world_prop_capability_resolve", input).unwrap_err(),
            "prop_capability_invalid_physics"
        );
    }
    #[test]
    fn candidates_require_real_standing_and_deterministic_ties() {
        let make = |id: &str, x: f32, enabled: bool| json!({"id":id,"position":{"x":x,"y":0,"z":0},"enabled":enabled});
        let candidates = operation_anchor_candidates(
            [0.; 3],
            &[
                make("tie-b", 1., true),
                make("tie-a", -1., true),
                make("inside", 0.2, true),
                make("disabled", 0.5, false),
                make("far", 3., true),
            ],
            |p| p[0].abs() > 0.3,
        );
        assert_eq!(
            candidates
                .iter()
                .map(|v| v["id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["tie-a", "tie-b"]
        );
    }
    #[test]
    fn only_explicit_supported_binding_no_name_inference() {
        let prop = json!({"objectID":"machine","displayName":"咖啡机"});
        assert_eq!(
            proposal(&prop, "coffee.brew").unwrap(),
            json!({"objectID":"machine","templateID":"coffee.brew"})
        );
        assert!(proposal(&prop, "latte.art").is_err());
        assert!(proposal(&json!({"displayName":"咖啡机"}), "coffee.brew").is_err());
    }
    #[test]
    fn receipt_driven_definition_catalog_contract() {
        let prop = json!({"objectID":"machine"});
        let d = definition(&prop, "coffee.brew").unwrap();
        assert_eq!(d["id"], "coffee.brew@machine");
        assert_eq!(d["phases"][0]["requiredAnchorIDs"], json!(["machine"]));
        assert!(d["phases"][1].get("durationSeconds").is_none());
        assert_eq!(d["phases"][2]["durationSeconds"], 0);
        assert_eq!(d["phases"].as_array().unwrap().len(), 6);
        let built = crate::activity::request(
            "activity_catalog_build",
            json!({"authoredDefinitions":[d],"dynamicDefinitions":[]}),
        )
        .unwrap();
        assert!(built.is_object());
        let (key, binding) = usage_binding(&prop, "coffee.brew").unwrap();
        assert_eq!(key, "coffee.brew@machine");
        assert_eq!(binding, proposal(&prop, "coffee.brew").unwrap());
    }
    #[test]
    fn final_approach_requires_actual_grounded_capsule_resolution() {
        let center = [-2.7, 0.52, -5.];
        let half = [0.29150167 / 2., 0.35 / 2., 0.4719286 / 2.];
        let result = final_approach_point([-3.5, 0., -5.], center, 0., half, |p| {
            (p[0] <= -3.35).then_some(p)
        })
        .unwrap();
        assert!((result[0] + 3.4).abs() < 0.00001);
        assert!(footprint_edge_distance(result, center, 0., half) <= INTERACTION_REACH);
        assert!(final_approach_point([-3.5, 0., -5.], center, 0., half, |_| None).is_none());
    }
}
