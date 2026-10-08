//! Deterministic activity catalog rules; playback and movement stay with the host.
use crate::model::Result;
use serde_json::{json, Value};
use std::collections::HashSet;

const PHASES: [&str; 6] = ["approach", "enter", "loop", "exit", "interrupt", "failed"];

fn canonical(action: &str) -> Option<&str> {
    match action {
        "idle" | "walk" | "turn" | "sit" | "gaze" | "listenMusic" | "interact" => Some(action),
        "listen-to-music" | "listen_music" => Some("listenMusic"),
        _ => None,
    }
}

fn array<'a>(input: &'a Value, key: &str) -> Result<&'a Vec<Value>> {
    input[key].as_array().ok_or("activity_invalid_input")
}

fn id(value: &Value) -> Result<&str> {
    value["id"].as_str().ok_or("activity_invalid_input")
}

fn validate(definitions: &[Value]) -> Result<()> {
    let mut ids = HashSet::new();
    for definition in definitions {
        if !ids.insert(id(definition)?) {
            return Err("activity_duplicate_id");
        }
        let activity = &definition["activity"];
        let action = activity["type"].as_str().ok_or("activity_invalid_input")?;
        // Codable activities accept only canonical spellings, unlike manifest anchors.
        if canonical(action) != Some(action) {
            return Err("activity_unsupported_action");
        }
        let target_key = match action {
            "walk" => Some("destinationID"),
            "sit" | "listenMusic" | "interact" => Some("anchorID"),
            "gaze" => Some("targetID"),
            _ => None,
        };
        if let Some(key) = target_key {
            if !activity[key].is_string() {
                return Err("activity_invalid_input");
            }
        }
        if action == "turn" && !activity["targetYaw"].is_number() {
            return Err("activity_invalid_input");
        }
        let mut phases = HashSet::new();
        for phase in array(definition, "phases")? {
            let name = phase["phase"].as_str().ok_or("activity_invalid_input")?;
            if !PHASES.contains(&name) {
                return Err("activity_invalid_input");
            }
            if !phases.insert(name) {
                return Err("activity_duplicate_phase");
            }
            for key in ["requiredAnchorIDs", "motionIDs", "propIDs"] {
                if let Some(value) = phase.get(key).filter(|v| !v.is_null()) {
                    if !value
                        .as_array()
                        .is_some_and(|a| a.iter().all(Value::is_string))
                    {
                        return Err("activity_invalid_input");
                    }
                }
            }
        }
        if PHASES.iter().any(|p| !phases.contains(p)) {
            return Err("activity_missing_phase");
        }
    }
    Ok(())
}

fn merge(input: &Value) -> Result<Value> {
    let authored = array(input, "authoredDefinitions")?;
    let dynamic = array(input, "dynamicDefinitions")?;
    validate(authored)?;
    validate(dynamic)?;
    let replacements: HashSet<_> = dynamic.iter().map(id).collect::<Result<_>>()?;
    let definitions: Vec<_> = authored
        .iter()
        .filter(|v| !replacements.contains(id(v).unwrap()))
        .chain(dynamic.iter())
        .cloned()
        .collect();
    validate(&definitions)?;
    Ok(json!({"definitions":definitions}))
}

fn manifest(input: &Value) -> Result<Value> {
    let anchors = array(input, "activities")?;
    let authored = array(input, "activityDefinitions")?;
    if !authored.is_empty() {
        let anchors_ids: HashSet<_> = anchors.iter().map(id).collect::<Result<_>>()?;
        let definitions_ids: HashSet<_> = authored.iter().map(id).collect::<Result<_>>()?;
        if anchors_ids.difference(&definitions_ids).next().is_some() {
            return Err("activity_missing_definition");
        }
        if definitions_ids.difference(&anchors_ids).next().is_some() {
            return Err("activity_orphan_definition");
        }
        validate(authored)?;
        for anchor in anchors {
            let action = canonical(anchor["action"].as_str().ok_or("activity_invalid_input")?)
                .ok_or("activity_unsupported_action")?;
            let definition = authored
                .iter()
                .find(|v| id(v).ok() == id(anchor).ok())
                .unwrap();
            if definition["activity"]["type"] != action {
                return Err("activity_action_mismatch");
            }
        }
        return Ok(json!({"definitions":authored}));
    }
    let mut definitions = Vec::new();
    for anchor in anchors {
        let identity = id(anchor)?;
        let action = canonical(anchor["action"].as_str().ok_or("activity_invalid_input")?)
            .ok_or("activity_unsupported_action")?;
        let waypoint = anchor["entryWaypointID"]
            .as_str()
            .ok_or("activity_function_point_requires_definition")?;
        let rotation = anchor
            .pointer("/transform/rotation")
            .ok_or("activity_function_point_requires_definition")?;
        let mut activity = json!({"type": action});
        match action {
            "idle" => {}
            "walk" => activity["destinationID"] = json!(waypoint),
            "sit" | "listenMusic" => activity["anchorID"] = json!(identity),
            "gaze" => activity["targetID"] = json!(identity),
            "turn" => {
                let coordinate = |axis: &str| {
                    rotation[axis]
                        .as_f64()
                        .map(|v| v as f32)
                        .ok_or("activity_invalid_input")
                };
                let (x, y, z, w) = (
                    coordinate("x")?,
                    coordinate("y")?,
                    coordinate("z")?,
                    coordinate("w")?,
                );
                activity["targetYaw"] =
                    json!((2.0 * (w * y + x * z)).atan2(1.0 - 2.0 * (y * y + z * z)));
            }
            _ => return Err("activity_unsupported_action"),
        }
        let approaches = matches!(action, "walk" | "sit" | "gaze" | "listenMusic");
        let motions: Vec<_> = anchor
            .get("motionID")
            .filter(|v| !v.is_null())
            .cloned()
            .into_iter()
            .collect();
        let phases: Vec<_> = PHASES.iter().map(|phase| json!({"phase":phase,
            "requiredAnchorIDs":if *phase=="approach" && approaches {json!([identity])} else {json!([])},
            "motionIDs":if *phase=="loop" {json!(motions)} else {json!([])},
            "propIDs":if *phase=="loop" {anchor.get("propIDs").cloned().unwrap_or(json!([]))} else {json!([])}})).collect();
        definitions.push(json!({"id":identity,"activity":activity,"phases":phases,
            "interruptible":anchor.get("interruptible").cloned().unwrap_or(json!(true)),"cooldownSeconds":0}));
    }
    validate(&definitions)?;
    Ok(json!({"definitions":definitions}))
}

pub fn request(method: &str, input: Value) -> Result<Value> {
    match method {
        "activity_catalog_build" => merge(&input),
        "activity_manifest_build" => manifest(&input),
        "activity_seat_definition" => seat_definition(&input),
        _ => Err("unknown_method"),
    }
}

fn seat_definition(input: &Value) -> Result<Value> {
    let identity = input["activityID"]
        .as_str()
        .ok_or("activity_invalid_input")?;
    let object = input["objectID"].as_str().ok_or("activity_invalid_input")?;
    let name = input
        .get("displayName")
        .and_then(Value::as_str)
        .unwrap_or(object);
    let phases: Vec<_> = PHASES.iter().map(|phase| {
        let mut contract = json!({"phase":phase,
            "requiredAnchorIDs":if *phase=="approach" {json!([identity])} else {json!([])},
            "motionIDs":match *phase {
                "approach"=>json!(["gmgn.motion.bones.walk-loop-pmx","gmgn.motion.bones.walk-loop-vrm"]),
                "loop"=>json!(["gmgn.motion.bones.chair-sit-loop-pmx","gmgn.motion.bones.chair-sit-loop-vrm"]),
                _=>json!([])},
            "propIDs":if *phase=="loop" {json!([object])} else {json!([])}});
        if matches!(*phase,"enter"|"exit") { contract["durationSeconds"]=json!(0.2); }
        contract
    }).collect();
    Ok(
        json!({"definition":{"id":identity,"displayName":format!("坐到{name}上休息"),
        "activity":{"type":"sit","anchorID":identity},"phases":phases,
        "interruptible":true,"cooldownSeconds":0}}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn definition(identity: &str) -> Value {
        json!({"id":identity,"activity":{"type":"idle"},"phases":PHASES.map(|p|json!({"phase":p}))})
    }
    #[test]
    fn duplicate_ids_and_phases_are_rejected() {
        assert_eq!(
            validate(&[definition("same"), definition("same")]),
            Err("activity_duplicate_id")
        );
        let mut d = definition("one");
        d["phases"][5] = json!({"phase":"loop"});
        assert_eq!(validate(&[d]), Err("activity_duplicate_phase"));
    }
    #[test]
    fn every_missing_phase_is_rejected() {
        for index in 0..6 {
            let mut d = definition("one");
            d["phases"].as_array_mut().unwrap().remove(index);
            assert_eq!(validate(&[d]), Err("activity_missing_phase"));
        }
    }
    #[test]
    fn device_override_keeps_dynamic_seat_and_authored_order() {
        let mut device = definition("music.listen");
        device["displayName"] = json!("dynamic device");
        let seat = definition("prop.seat.sofa-id");
        let result = merge(
            &json!({"authoredDefinitions":[definition("home.idle"),definition("music.listen")],
            "dynamicDefinitions":[device.clone(),seat.clone()]}),
        )
        .unwrap();
        assert_eq!(
            result["definitions"],
            json!([definition("home.idle"), device, seat])
        );
    }
    #[test]
    fn dynamic_duplicates_are_not_silently_overwritten() {
        assert_eq!(
            merge(
                &json!({"authoredDefinitions":[],"dynamicDefinitions":[definition("seat"),definition("seat")]})
            ),
            Err("activity_duplicate_id")
        );
    }
    fn anchor(action: &str) -> Value {
        json!({"id":"device","action":action,"entryWaypointID":"entry",
        "transform":{"rotation":{"x":0,"y":0,"z":0,"w":1}},"motionID":"motion-existing-id","propIDs":["prop"]})
    }
    #[test]
    fn legacy_actions_and_loop_motion_mapping_match_swift() {
        for action in [
            "idle",
            "walk",
            "turn",
            "sit",
            "gaze",
            "listenMusic",
            "listen-to-music",
            "listen_music",
        ] {
            let result =
                manifest(&json!({"activities":[anchor(action)],"activityDefinitions":[]})).unwrap();
            let d = &result["definitions"][0];
            assert_eq!(d["activity"]["type"], canonical(action).unwrap());
            assert_eq!(d["phases"][2]["motionIDs"], json!(["motion-existing-id"]));
            assert_eq!(d["phases"][2]["propIDs"], json!(["prop"]));
            assert_eq!(d["phases"][1]["motionIDs"], json!([]));
        }
        assert_eq!(
            manifest(&json!({"activities":[anchor("interact")],"activityDefinitions":[]})),
            Err("activity_unsupported_action")
        );
    }
    #[test]
    fn modern_manifest_checks_identity_and_action() {
        let mut d = definition("device");
        assert_eq!(
            manifest(&json!({"activities":[anchor("sit")],"activityDefinitions":[d.clone()]})),
            Err("activity_action_mismatch")
        );
        d["activity"] = json!({"type":"sit","anchorID":"device"});
        assert!(
            manifest(&json!({"activities":[anchor("sit")],"activityDefinitions":[d.clone()]}))
                .is_ok()
        );
        assert_eq!(
            manifest(
                &json!({"activities":[anchor("sit")],"activityDefinitions":[definition("other")]})
            ),
            Err("activity_missing_definition")
        );
        assert_eq!(
            manifest(&json!({"activities":[],"activityDefinitions":[d]})),
            Err("activity_orphan_definition")
        );
    }
    #[test]
    fn legacy_function_points_require_explicit_definition() {
        assert_eq!(
            manifest(
                &json!({"activities":[{"id":"device","action":"sit"}],"activityDefinitions":[]})
            ),
            Err("activity_function_point_requires_definition")
        );
    }
    #[test]
    fn seat_identity_motions_and_timing_match_existing_contract() {
        let r = seat_definition(
            &json!({"activityID":"prop.seat.sofa-id","objectID":"sofa-id","displayName":"沙发"}),
        )
        .unwrap();
        let d = &r["definition"];
        assert_eq!(d["id"], "prop.seat.sofa-id");
        assert_eq!(d["activity"]["anchorID"], d["id"]);
        assert_eq!(d["displayName"], "坐到沙发上休息");
        assert_eq!(
            d["phases"][0]["motionIDs"],
            json!([
                "gmgn.motion.bones.walk-loop-pmx",
                "gmgn.motion.bones.walk-loop-vrm"
            ])
        );
        assert_eq!(
            d["phases"][2]["motionIDs"],
            json!([
                "gmgn.motion.bones.chair-sit-loop-pmx",
                "gmgn.motion.bones.chair-sit-loop-vrm"
            ])
        );
        assert_eq!(d["phases"][1]["durationSeconds"], 0.2);
        assert_eq!(d["phases"][3]["durationSeconds"], 0.2);
        assert!(d["phases"][2].get("durationSeconds").is_none());
        assert_eq!(d["phases"][2]["propIDs"], json!(["sofa-id"]));
        validate(&[d.clone()]).unwrap();
    }
}
