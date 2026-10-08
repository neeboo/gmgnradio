//! Read-only authored approach decisions. Host measures physics, never selects an entry.
use crate::model::Result;
use serde_json::{json, Value};
type Point = [f32; 3];
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("activity_approach_invalid_input")
}
fn point(v: &Value) -> Result<Point> {
    let mut p = [0.; 3];
    for (i, k) in ["x", "y", "z"].iter().enumerate() {
        let component = if let Some(a) = v.as_array() {
            a.get(i).ok_or("activity_approach_invalid_geometry")?
        } else {
            &v[*k]
        };
        p[i] = component
            .as_f64()
            .filter(|n| n.is_finite() && n.abs() <= 100000.)
            .ok_or("activity_approach_invalid_geometry")? as f32;
    }
    Ok(p)
}
fn vector(p: Point) -> Value {
    json!({"x":p[0],"y":p[1],"z":p[2]})
}
fn normalize(y: f32) -> f32 {
    let mut y = y % (2. * std::f32::consts::PI);
    if y > std::f32::consts::PI {
        y -= 2. * std::f32::consts::PI;
    }
    if y <= -std::f32::consts::PI {
        y += 2. * std::f32::consts::PI;
    }
    y
}
fn number(v: &Value) -> Result<f32> {
    v.as_f64()
        .filter(|n| n.is_finite() && n.abs() <= 100000.)
        .map(|n| n as f32)
        .ok_or("activity_approach_invalid_geometry")
}
fn declaration(item: &Value, key: &str) -> Result<Value> {
    if key == "gmgn.prop-seat.v1" && item["metadata"].get(key).is_none() {
        let generated = declaration(item, crate::world::GENERATED_PROP_KEY)?;
        return reviewed_seat_calibration(generated["assetID"].as_str().unwrap_or(""))
            .ok_or("activity_approach_binding_missing");
    }
    let raw = item["metadata"][key]
        .as_str()
        .filter(|s| s.len() <= 65536)
        .ok_or("activity_approach_binding_missing")?;
    serde_json::from_str(raw).map_err(|_| "activity_approach_invalid_binding")
}
/// Immutable measured mesh fact. Registration and approach share this one table.
pub fn reviewed_seat_calibration(asset_id: &str) -> Option<Value> {
    if asset_id != "sha256:0eb955793605cbfe0680616f98991369f85fd46c317d1b51a877949b3fb36303" {
        return None;
    }
    Some(
        json!({"assetID":asset_id,"contactPoint":{"x":-0.000149548054_f32,"y":0.286568887_f32,"z":-0.160351936_f32},
        "approachPoint":{"x":-0.000149548054_f32,"y":0,"z":-0.450351936_f32},"facingYaw":std::f32::consts::PI,
        "sourceSize":{"x":1.006890178_f32,"y":0.511452764_f32,"z":0.568691671_f32}}),
    )
}
fn seat_projection(item: &Value, input: &Value, approach: Point, facing: f32) -> Result<Value> {
    let seat = declaration(item, "gmgn.prop-seat.v1")?;
    let generated = declaration(item, crate::world::GENERATED_PROP_KEY)?;
    let source = point(&seat["sourceSize"])?;
    let size = if generated["sizeLocked"] == true
        || generated.get("sizeIntent").is_some_and(|v| !v.is_null())
    {
        &generated["size"]
    } else {
        generated
            .pointer("/authoritativeSize/dimensions")
            .unwrap_or(&generated["size"])
    };
    let size = point(size)?;
    let contact = point(&seat["contactPoint"])?;
    let base = point(&item["transform"]["position"])?;
    let yaw = facing - number(&seat["facingYaw"])?;
    let local: Point = std::array::from_fn(|i| contact[i] * size[i] / source[i]);
    Ok(
        json!({"objectID":input["objectID"],"contactPoint":vector([base[0]+yaw.cos()*local[0]+yaw.sin()*local[2],base[1]+local[1],base[2]-yaw.sin()*local[0]+yaw.cos()*local[2]]),
        "approachPoint":vector(approach),"facingYaw":facing}),
    )
}
/// Derive from persisted declaration and pose; caller-provided anchor positions are never read.
fn anchor(item: &Value, input: &Value) -> Result<(Point, f32)> {
    let object = text(input, "objectID")?;
    let base = point(&item["transform"]["position"])?;
    let q = &item["transform"]["rotation"];
    let (x, y, z, w) = (
        number(&q["x"])?,
        number(&q["y"])?,
        number(&q["z"])?,
        number(&q["w"])?,
    );
    let yaw = normalize((2. * (w * y + x * z)).atan2(1. - 2. * (y * y + z * z)));
    let transform = |p: Point| {
        [
            base[0] + yaw.cos() * p[0] + yaw.sin() * p[2],
            base[1] + p[1],
            base[2] - yaw.sin() * p[0] + yaw.cos() * p[2],
        ]
    };
    match text(input, "kind")? {
        "functionPoint" => {
            let d = declaration(item, "gmgn.prop-function-points.v1")?;
            if d["objectID"] != object {
                return Err("activity_approach_invalid_binding");
            }
            let points = d["functionPoints"]
                .as_array()
                .filter(|p| p.len() <= 16)
                .ok_or("activity_approach_invalid_binding")?;
            let role = text(input, "role")?;
            let matches: Vec<_> = points.iter().filter(|p| p["role"] == role).collect();
            if matches.len() != 1 {
                return Err("activity_approach_invalid_binding");
            }
            let p = matches[0];
            if p.get("kind").is_some_and(|k| k != "standingSpot")
                || p["activityID"] != input["activityID"]
            {
                return Err("activity_approach_invalid_binding");
            }
            let local = point(&p["position"])?;
            let facing = if !p["yaw"].is_null() {
                normalize(yaw + number(&p["yaw"])?)
            } else {
                let target = points
                    .iter()
                    .find(|p| p["kind"] == "interaction")
                    .map(|p| point(&p["position"]))
                    .transpose()?
                    .unwrap_or([0.; 3]);
                let (dx, dz) = (target[0] - local[0], target[2] - local[2]);
                normalize(
                    yaw + if dx * dx + dz * dz > 1e-8 {
                        (-dx).atan2(-dz)
                    } else {
                        0.
                    },
                )
            };
            Ok((transform(local), facing))
        }
        "seat" => {
            let seat = declaration(item, "gmgn.prop-seat.v1")?;
            let generated = declaration(item, crate::world::GENERATED_PROP_KEY)?;
            if generated["objectID"] != object
                || seat["assetID"] != generated["assetID"]
                || x.abs() >= 0.001
                || z.abs() >= 0.001
            {
                return Err("activity_approach_invalid_binding");
            }
            let orientation = &generated["orientation"]["rotation"];
            if !orientation.is_null() && *orientation != json!({"x":0,"y":0,"z":0,"w":1}) {
                return Err("activity_approach_invalid_binding");
            }
            let source = point(&seat["sourceSize"])?;
            let size = if generated["sizeLocked"] == true
                || generated.get("sizeIntent").is_some_and(|v| !v.is_null())
            {
                &generated["size"]
            } else {
                generated
                    .pointer("/authoritativeSize/dimensions")
                    .unwrap_or(&generated["size"])
            };
            let size = point(size)?;
            if source.iter().chain(size.iter()).any(|n| *n <= 0.) {
                return Err("activity_approach_invalid_binding");
            }
            let p = point(&seat["approachPoint"])?;
            let contact = point(&seat["contactPoint"])?;
            text(&seat, "assetID")?;
            if p[1] != 0.
                || p.iter().chain(contact.iter()).any(|n| n.abs() > 10.)
                || contact[1] <= 0.
                || contact[1] > source[1]
                || contact[0].abs() > source[0] / 2.
                || contact[2].abs() > source[2] / 2.
            {
                return Err("activity_approach_invalid_binding");
            }
            Ok((
                transform(std::array::from_fn(|i| p[i] * size[i] / source[i])),
                yaw + number(&seat["facingYaw"])?,
            ))
        }
        _ => Err("activity_approach_invalid_input"),
    }
}
fn plan(db: &rusqlite::Connection, input: &Value) -> Result<Value> {
    let world = text(input, "worldID")?;
    text(input, "hostSessionID")?;
    let object = text(input, "objectID")?;
    let state = crate::world::materialize(db, world)?.ok_or("activity_approach_world_missing")?;
    if input["expectedLayoutRevision"].as_u64().is_none()
        || input["expectedLayoutRevision"] != state["layoutRevision"]
    {
        return Err("activity_approach_stale_layout");
    }
    let item = &state["objectStates"][object];
    if item["isEnabled"] != true {
        return Err("activity_approach_object_unavailable");
    }
    let (position, yaw) = match anchor(item, input) {
        Ok(value) => value,
        Err(_) if input["kind"] == "seat" => {
            return Ok(
                json!({"geometryID":"unavailable","layoutRevision":state["layoutRevision"],"probes":[],"target":null,"seatProjection":null}),
            )
        }
        Err(error) => return Err(error),
    };
    let seat = if input["kind"] == "seat" {
        seat_projection(item, input, position, yaw)?
    } else {
        Value::Null
    };
    let definition = if input["kind"] == "seat" {
        let generated = declaration(item, crate::world::GENERATED_PROP_KEY)?;
        crate::activity::request("activity_seat_definition",json!({"activityID":format!("prop.seat.{object}"),"objectID":object,"displayName":generated["displayName"]}))?["definition"].clone()
    } else {
        Value::Null
    };
    let waypoints = input["waypoints"]
        .as_array()
        .filter(|w| w.len() <= 512)
        .ok_or("activity_approach_invalid_input")?;
    let mut ids = std::collections::BTreeSet::new();
    let mut probes = vec![json!({"key":"anchor","position":vector(position)})];
    for (i, wp) in waypoints.iter().enumerate() {
        let id = text(wp, "id")?;
        if !ids.insert(id) || !wp["enabled"].is_boolean() {
            return Err("activity_approach_invalid_input");
        }
        let p = point(&wp["position"])?;
        probes.push(json!({"key":format!("stand.{i}"),"position":vector(p)}));
        probes
            .push(json!({"key":format!("edge.{i}"),"position":vector(position),"from":vector(p)}));
    }
    let binding = json!({"worldID":world,"hostSessionID":input["hostSessionID"],"objectID":object,
        "layoutRevision":state["layoutRevision"],"kind":input["kind"],"role":input["role"],
        "activityID":input["activityID"],"position":vector(position),"targetYaw":yaw,"waypoints":waypoints});
    let canonical = crate::canonical_json::to_string(&binding)
        .map_err(|_| "activity_approach_invalid_input")?;
    if canonical.len() > 262144 {
        return Err("activity_approach_input_limit");
    }
    use sha2::{Digest, Sha256};
    let geometry = format!("{:x}", Sha256::digest(canonical.as_bytes()));
    Ok(
        json!({"geometryID":geometry,"layoutRevision":state["layoutRevision"],"position":vector(position),
        "targetYaw":yaw,"waypoints":waypoints,"probes":probes,"seatProjection":seat,"definition":definition}),
    )
}
pub fn request(db: &rusqlite::Connection, method: &str, input: Value) -> Result<Value> {
    if method == "world_activity_approach_places" {
        return places(db, &input);
    }
    let mut p = plan(db, &input)?;
    if method == "world_activity_approach_plan" {
        return Ok(p);
    }
    if method != "world_activity_approach_resolve" {
        return Err("unknown_method");
    }
    if input["geometryID"] != p["geometryID"] {
        return Err("activity_approach_stale_geometry");
    }
    if p["geometryID"] == "unavailable" {
        if input["physics"] != json!([]) {
            return Err("activity_approach_invalid_physics");
        }
        return Ok(p);
    }
    let probes = p["probes"].as_array().unwrap();
    let facts = input["physics"]
        .as_array()
        .filter(|f| f.len() == probes.len())
        .ok_or("activity_approach_invalid_physics")?;
    for (probe, fact) in probes.iter().zip(facts) {
        if probe["key"] != fact["key"]
            || point(&probe["position"])? != point(&fact["position"])?
            || !fact["canTraverse"].is_boolean()
        {
            return Err("activity_approach_invalid_physics");
        }
        if !fact["grounded"].is_null() {
            let (a, b) = (point(&probe["position"])?, point(&fact["grounded"])?);
            if a[0] != b[0] || a[2] != b[2] {
                return Err("activity_approach_invalid_physics");
            }
        }
    }
    let target = if facts[0]["grounded"].is_null() {
        Value::Null
    } else {
        let stand = point(&facts[0]["grounded"])?;
        let center = point(&p["position"])?;
        let wps = p["waypoints"].as_array().unwrap();
        let exact = wps.iter().find(|wp| {
            wp["enabled"] == true
                && point(&wp["position"]).is_ok_and(|v| {
                    (0..3).map(|i| (v[i] - center[i]).powi(2)).sum::<f32>() <= 0.0001
                })
        });
        if let Some(wp) = exact {
            json!({"waypointID":wp["id"],"approachPoint":null,"standPoint":vector(stand),"targetYaw":p["targetYaw"]})
        } else {
            let candidates =
                crate::world_prop_capability::operation_anchor_candidates(center, wps, |pos| {
                    wps.iter().enumerate().any(|(i, wp)| {
                        point(&wp["position"]).ok() == Some(pos)
                            && !facts[1 + 2 * i]["grounded"].is_null()
                    })
                });
            candidates.iter().find(|wp| {
                let i=wps.iter().position(|w| w["id"]==wp["id"]).unwrap();
                !facts[1+2*i]["grounded"].is_null() && facts[2+2*i]["canTraverse"]==true && facts[2+2*i]["grounded"]==facts[0]["grounded"]
            }).map(|wp| json!({"waypointID":wp["id"],"approachPoint":vector(stand),"standPoint":vector(stand),"targetYaw":p["targetYaw"]})).unwrap_or(Value::Null)
        }
    };
    p["target"] = target;
    Ok(p)
}
/// Explicit package bindings survive device movement and metadata projection changes.
/// No coordinate epsilon, naming convention, or caller-selected binding is accepted.
fn places(db: &rusqlite::Connection, input: &Value) -> Result<Value> {
    let world = text(input, "worldID")?;
    let host = text(input, "hostSessionID")?;
    let state = crate::world::materialize(db, world)?.ok_or("activity_approach_world_missing")?;
    if input["expectedLayoutRevision"].as_u64().is_none()
        || input["expectedLayoutRevision"] != state["layoutRevision"]
    {
        return Err("activity_approach_stale_layout");
    }
    let mut result = serde_json::Map::new();
    let exists: i64 = db
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='world_device_catalog'",
            [],
            |r| r.get(0),
        )
        .map_err(|_| "storage_unavailable")?;
    if exists != 0 {
        let mut statement = db
            .prepare("SELECT id,declaration FROM world_device_catalog WHERE world=?1 ORDER BY id")
            .map_err(|_| "storage_unavailable")?;
        let rows = statement
            .query_map([world], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })
            .map_err(|_| "storage_unavailable")?;
        for row in rows {
            let (object, raw) = row.map_err(|_| "storage_unavailable")?;
            let catalog: Value =
                serde_json::from_str(&raw).map_err(|_| "activity_approach_invalid_binding")?;
            let Some(bindings) = catalog.get("placeBindings") else {
                continue;
            };
            let bindings = bindings
                .as_array()
                .filter(|a| a.len() <= 16)
                .ok_or("activity_approach_invalid_binding")?;
            for binding in bindings {
                let place = text(binding, "placeID")?;
                let role = text(binding, "role")?;
                if result.contains_key(place) {
                    return Err("activity_approach_invalid_binding");
                }
                let declared = catalog["functionPoints"]
                    .as_array()
                    .ok_or("activity_approach_invalid_binding")?;
                let points: Vec<_> = declared.iter().filter(|p| p["role"] == role).collect();
                if points.len() != 1 || points[0].get("kind").is_some_and(|k| k != "standingSpot") {
                    return Err("activity_approach_invalid_binding");
                }
                let item = &state["objectStates"][&object];
                let mut record = json!({"objectID":object,"role":role,"anchorID":format!("{object}#{role}"),"activityID":points[0]["activityID"],"position":null,"targetYaw":null});
                if item["isEnabled"] == true {
                    let request = json!({"kind":"functionPoint","objectID":object,"role":role,"activityID":points[0]["activityID"]});
                    let (position, yaw) = anchor(item, &request)?;
                    record["position"] = vector(position);
                    record["targetYaw"] = json!(yaw);
                }
                result.insert(place.into(), record);
            }
        }
    }
    Ok(
        json!({"worldID":world,"hostSessionID":host,"layoutRevision":state["layoutRevision"],"places":result}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (rusqlite::Connection, Value) {
        use sha2::{Digest, Sha256};
        let mut db = rusqlite::Connection::open_in_memory().unwrap();
        crate::world::schema(&db).unwrap();
        let declaration = json!({"objectID":"box","functionPoints":[{"role":"entry","activityID":"use","position":[0,0,0]}]});
        let transform = json!({"position":vector([0.;3]),"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":vector([1.;3])});
        let state = json!({"worldID":"fixture","revision":0,"layoutRevision":7,"worldTime":1000,"lastObservedWallTime":1000,
            "weather":"clear","completedGoals":{},"agentTransform":transform,"objectStates":{"box":{"isEnabled":true,
            "transform":transform,
            "metadata":{"gmgn.prop-function-points.v1":declaration.to_string()}}}});
        let bytes = state.to_string();
        let tx = db.transaction().unwrap();
        crate::world::import(
            &tx,
            &crate::world::ImportRequest {
                world_id: "fixture".into(),
                request_id: "seed".into(),
                producer: Some("private-test".into()),
                package_id: "fixture".into(),
                package_version: "1".into(),
                state_sha256: format!("{:x}", Sha256::digest(bytes.as_bytes())),
                state_json: bytes,
            },
        )
        .unwrap();
        tx.commit().unwrap();
        let input = json!({"worldID":"fixture","hostSessionID":"host","objectID":"box","kind":"functionPoint","role":"entry","activityID":"use","expectedLayoutRevision":7,
            "waypoints":[{"id":"tie-b","enabled":true,"position":vector([1.,0.,0.])},{"id":"tie-a","enabled":true,"position":vector([-1.,0.,0.])}]});
        (db, input)
    }
    fn measured(plan: &Value) -> Value {
        json!(plan["probes"].as_array().unwrap().iter().map(|p|json!({"key":p["key"],"position":p["position"],"grounded":p["position"],"canTraverse":true})).collect::<Vec<_>>())
    }
    #[test]
    fn actual_sql_ties_first_reachable_and_exact_epsilon_preserve_semantics() {
        let (db, mut input) = fixture();
        let p = request(&db, "world_activity_approach_plan", input.clone()).unwrap();
        input["geometryID"] = p["geometryID"].clone();
        input["physics"] = measured(&p);
        assert_eq!(
            request(&db, "world_activity_approach_resolve", input.clone()).unwrap()["target"]
                ["waypointID"],
            "tie-a"
        );
        input["physics"][4]["canTraverse"] = json!(false);
        assert_eq!(
            request(&db, "world_activity_approach_resolve", input.clone()).unwrap()["target"]
                ["waypointID"],
            "tie-b"
        );
        input["physics"][2]["canTraverse"] = json!(false);
        assert!(
            request(&db, "world_activity_approach_resolve", input.clone()).unwrap()["target"]
                .is_null()
        );
        input["waypoints"][0]["position"] = vector([0.009, 0., 0.]);
        let p = request(&db, "world_activity_approach_plan", input.clone()).unwrap();
        input["geometryID"] = p["geometryID"].clone();
        input["physics"] = measured(&p);
        input["physics"][1]["grounded"] = Value::Null;
        input["physics"][2]["canTraverse"] = json!(false);
        let target =
            request(&db, "world_activity_approach_resolve", input).unwrap()["target"].clone();
        assert_eq!(target["waypointID"], "tie-b");
        assert!(target["approachPoint"].is_null());
    }
    #[test]
    fn actual_sql_stale_layout_geometry_and_changed_measurement_rejected_without_write() {
        let (db, mut input) = fixture();
        let before = crate::world::materialize(&db, "fixture").unwrap();
        let p = request(&db, "world_activity_approach_plan", input.clone()).unwrap();
        input["geometryID"] = p["geometryID"].clone();
        input["physics"] = measured(&p);
        input["physics"][0]["grounded"]["x"] = json!(1);
        assert_eq!(
            request(&db, "world_activity_approach_resolve", input.clone()),
            Err("activity_approach_invalid_physics")
        );
        input["physics"] = measured(&p);
        input["hostSessionID"] = json!("new-host");
        assert_eq!(
            request(&db, "world_activity_approach_resolve", input.clone()),
            Err("activity_approach_stale_geometry")
        );
        input["expectedLayoutRevision"] = json!(8);
        assert_eq!(
            request(&db, "world_activity_approach_plan", input),
            Err("activity_approach_stale_layout")
        );
        assert_eq!(before, crate::world::materialize(&db, "fixture").unwrap());
    }
    #[test]
    fn persisted_function_point_rotation_and_facing_ignore_host_anchor() {
        let d = json!({"objectID":"box","functionPoints":[{"role":"entry","kind":"standingSpot","activityID":"use","position":{"x":1,"y":0,"z":0}},{"role":"button","kind":"interaction","position":{"x":0,"y":0,"z":0}}]});
        let item = json!({"transform":{"position":{"x":3,"y":2,"z":4},"rotation":{"x":0,"y":0.70710677,"z":0,"w":0.70710677}},"metadata":{"gmgn.prop-function-points.v1":d.to_string()}});
        let input = json!({"kind":"functionPoint","objectID":"box","role":"entry","activityID":"use","position":{"x":999,"y":0,"z":0}});
        let (p, y) = anchor(&item, &input).unwrap();
        assert!((p[0] - 3.).abs() < 0.00001 && (p[2] - 3.).abs() < 0.00001 && p[1] == 2.);
        assert!((y - std::f32::consts::PI).abs() < 0.00001);
        let mut wrong = input;
        wrong["activityID"] = json!("other");
        assert_eq!(
            anchor(&item, &wrong),
            Err("activity_approach_invalid_binding")
        );
    }
    #[test]
    fn seat_uses_effective_size_without_double_transform_scale() {
        let seat = json!({"assetID":"sofa","sourceSize":{"x":2,"y":1,"z":1},"contactPoint":{"x":0,"y":0.5,"z":0},"approachPoint":{"x":1,"y":0,"z":-1},"facingYaw":0});
        let generated =
            json!({"assetID":"sofa","objectID":"box","sizeLocked":true,"size":{"x":4,"y":1,"z":1}});
        let item = json!({"transform":{"position":{"x":0,"y":0,"z":0},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":10,"y":10,"z":10}},"metadata":{"gmgn.prop-seat.v1":seat.to_string(),(crate::world::GENERATED_PROP_KEY):generated.to_string()}});
        assert_eq!(
            anchor(&item, &json!({"kind":"seat","objectID":"box"}))
                .unwrap()
                .0,
            [2., 0., -1.]
        );
    }
    #[test]
    fn immutable_reviewed_seat_projection_and_metadata_priority() {
        let asset = "sha256:0eb955793605cbfe0680616f98991369f85fd46c317d1b51a877949b3fb36303";
        assert!(reviewed_seat_calibration("sha256:unknown").is_none());
        let reviewed = reviewed_seat_calibration(asset).unwrap();
        let generated = json!({"assetID":asset,"objectID":"box","sizeLocked":true,"size":reviewed["sourceSize"]});
        let mut item = json!({"transform":{"position":vector([1.,2.,3.]),"rotation":{"x":0,"y":0,"z":0,"w":1}},"metadata":{(crate::world::GENERATED_PROP_KEY):generated.to_string()}});
        let input = json!({"kind":"seat","objectID":"box"});
        let (approach, facing) = anchor(&item, &input).unwrap();
        let projection = seat_projection(&item, &input, approach, facing).unwrap();
        assert!((number(&projection["contactPoint"]["y"]).unwrap() - 2.2865689).abs() < 0.000001);
        assert!((facing - std::f32::consts::PI).abs() < 0.000001);
        item["metadata"]["gmgn.prop-seat.v1"] = json!("{}");
        assert!(anchor(&item, &input).is_err()); // malformed explicit calibration never falls through to reviewed fact.
        item["metadata"]
            .as_object_mut()
            .unwrap()
            .remove("gmgn.prop-seat.v1");
        item["transform"]["rotation"]["x"] = json!(0.1);
        assert!(anchor(&item, &input).is_err());
    }
    #[test]
    fn actual_sql_explicit_place_binding_uses_current_pose_and_retains_unavailable_identity() {
        let (mut db, input) = fixture();
        crate::world_device::schema(&db).unwrap();
        let catalog = json!({"id":"box","functionPoints":[{"role":"entry","activityID":"use","position":[0,0,0]}],"placeBindings":[{"placeID":"original-place","role":"entry"}]});
        db.execute(
            "INSERT INTO world_device_catalog VALUES(?1,?2,?3)",
            rusqlite::params!["fixture", "box", catalog.to_string()],
        )
        .unwrap();
        let receipt = request(&db, "world_activity_approach_places", input.clone()).unwrap();
        assert_eq!(receipt["places"]["original-place"]["anchorID"], "box#entry");
        assert_eq!(
            receipt["places"]["original-place"]["position"],
            vector([0.; 3])
        );
        for (enabled, position) in [(true, [4., 0., 3.]), (false, [4., 0., 3.])] {
            let snapshot = crate::world::snapshot(
                &db,
                &crate::world::SnapshotRequest {
                    world_id: "fixture".into(),
                    include_state: Some(true),
                },
            )
            .unwrap();
            let mut state = crate::world::materialize(&db, "fixture").unwrap().unwrap();
            state["objectStates"]["box"]["transform"]["position"] = vector(position);
            state["objectStates"]["box"]["isEnabled"] = json!(enabled);
            let command:crate::world::CommitRequest=serde_json::from_value(json!({"worldID":"fixture","requestID":format!("pose-{enabled}"),"expectedRevision":snapshot["record"]["recordRevision"],"ops":[{"op":"replaceState","state":state}]})).unwrap();
            let tx = db.transaction().unwrap();
            crate::world::commit(&tx, &command).unwrap();
            tx.commit().unwrap();
            let current = request(&db, "world_activity_approach_places", input.clone()).unwrap();
            assert_eq!(current["places"]["original-place"]["anchorID"], "box#entry");
            assert_eq!(
                current["places"]["original-place"]["position"],
                if enabled {
                    vector(position)
                } else {
                    Value::Null
                }
            );
        }
        let mut spoof = input.clone();
        spoof["placeBindings"] = json!([{"placeID":"fake","role":"entry"}]);
        assert!(
            request(&db, "world_activity_approach_places", spoof).unwrap()["places"]
                .get("fake")
                .is_none()
        );
        let mut bad = catalog;
        bad["placeBindings"][0]["role"] = json!("unknown");
        db.execute(
            "UPDATE world_device_catalog SET declaration=?1",
            [bad.to_string()],
        )
        .unwrap();
        assert_eq!(
            request(&db, "world_activity_approach_places", input),
            Err("activity_approach_invalid_binding")
        );
    }
}
