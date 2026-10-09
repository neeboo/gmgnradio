//! 「物品」 — the Unity overlay's inventory surface, now the product component
//! [`ResidentPropEditorPane`] driven by the facts the Unity host already
//! publishes, with the component's commands translated back into the ops the
//! Unity host already dispatches.
//!
//! Why an adapter file instead of a second surface:
//!
//! - **One inventory, one queue.** The list is a pure function of
//!   `unityInventory` / `unityWorldAuthority` / `wish` / `inventoryMutation` /
//!   `unityUICommandResult` (the same keys `lib.rs` retains); every command
//!   leaves through the single shared `UiCommandQueue` the Unity player polls.
//! - **The component owns the look.** `ResidentPropEditorPane` paints the panel,
//!   the rows, the kit delete dialog and the tokens. This file owns the
//!   projection in and the translation out, nothing else.
//! - **One list owns everything that is in the room.** 音乐播放器 / 许愿机 are
//!   the world's own built-in devices (`builtinDevices.templates`), and they are
//!   objects: they get the same rows, the same groups and the same status words
//!   as every generated prop. The one thing that differs is what the world
//!   authority accepts for them — placement through `ui.device.place`
//!   (`world_device.rs::can_place`) and nothing else, because every
//!   `world.prop.command` arm starts at `world_prop::reduce` →
//!   `generated(&before)?` → `world_prop_basic_object`
//!   (`services/gmgn-taskd/src/world_prop.rs:1884` → `:130-134`). So a device row
//!   carries no 删除 (and no 收回/挂点/尺寸 in the selected pane) instead of an
//!   entry that would fail after the click.
//! - **Local state stays local.** The scope (我的物件 / 房间里), the 已结束 fold,
//!   the selected row and the hold point are this click's UI state. They never
//!   travel as invented host commands — only as a re-projection.
use crate::{UiCommandQueue, enqueue_ui_command};
use gmgn_gpui_ui::stage_panels::ResidentPropEditorPane;
use gmgn_gpui_ui::ui_tokens::{self as tokens, props as prop_metrics, scene as s};
use gpui_kit::*;
use serde_json::{Value, json};
use std::{cell::RefCell, rc::Rc};

/// `ResidentOwnershipProjection.visibleRowBudget` — rows shown before 「还有 N 件」.
const ROW_BUDGET: usize = 6;
/// The product's hold-point vocabulary (`PropAttachmentPoint.allCases` +
/// `PropAttachmentSlots.displayName`); the ids are the Rust `slot` names
/// (`world_prop.rs` `"hold"` validates `f.avatar.slots`).
const HOLD_POINTS: [(&str, &str); 3] = [("rightHand", "右手"), ("back", "背后"), ("waist", "腰间")];
/// One rotation click is the original `左转/右转 15°` (`pi / 12`).
const ROTATE_RADIANS: f32 = std::f32::consts::PI / 12.;
const QUEUE_FULL: &str = "操作队列已满，请稍后再试";

/// The panel state the component cannot know: it is decided by this click only.
#[derive(Clone, Debug, PartialEq)]
pub struct LocalState {
    /// 「房间里」 = `showsPlacedOnly`.
    pub placed_only: bool,
    /// 「已结束」 folded. The original defaults to folded, never hidden.
    pub ended_folded: bool,
    /// The row whose controls are on screen.
    pub selected: Option<String>,
    /// The hold point the picker last chose.
    pub hold_point: String,
}
impl Default for LocalState {
    fn default() -> Self {
        Self {
            placed_only: false,
            ended_folded: true,
            selected: None,
            hold_point: "rightHand".into(),
        }
    }
}

/// One ownership row, before it becomes the component's JSON.
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub id: String,
    pub object_id: String,
    pub job_id: Option<String>,
    pub name: String,
    pub state: &'static str,
    pub status: String,
    pub actions: Vec<&'static str>,
    pub group: &'static str,
    /// Set exactly for a row that came from `builtinDevices.templates`: the id
    /// the host's own `ui.device.place` addresses. `None` for every generated
    /// prop and wish row.
    pub device: Option<String>,
}

fn group_of(state: &str) -> &'static str {
    match state {
        "awaitingClaim" | "failed" | "generating" => "needsYou",
        "inInventory" => "inInventory",
        "placed" => "inRoom",
        _ => "ended",
    }
}
fn group_title(group: &str) -> &'static str {
    match group {
        "needsYou" => "待你处理",
        "inInventory" => "在库里",
        "inRoom" => "在房间里",
        _ => "已结束",
    }
}
fn section_title(group: &str, count: usize) -> String {
    format!("{} ({count})", group_title(group))
}

fn text(value: &Value) -> Option<&str> {
    value.as_str().filter(|v| !v.is_empty())
}

/// The product names of the world's own devices. The classifier is the
/// renderer, exactly the one `UnityBuiltinDevicesBridge.snapshot(package:)`
/// published them under (`apps/macos/UnityHost/UnityBuiltinDevicesBridge.swift:17`
/// keeps `builtin.jukebox` / `builtin.wish_machine`); a template with any other
/// renderer is not a basic device and never becomes a row.
fn device_name(renderer: Option<&str>) -> Option<&'static str> {
    match renderer {
        Some("builtin.jukebox") => Some("音乐播放器"),
        Some("builtin.wish_machine") => Some("许愿机"),
        _ => None,
    }
}

/// The `builtinDevices.templates` snapshot, kept to the real devices. Each entry
/// is the authored procedural declaration
/// (`UnityBuiltinDevicesBridge.snapshot(package:)`,
/// `UnityMediaHost.swift:1492 "builtinDevices": ["templates": deviceTemplates]`)
/// whose id is the Rust catalog's own (`services/gmgn-taskd/src/world_device.rs:96-102`
/// `("prop.jukebox","builtin.jukebox") | ("wish_machine.device","builtin.wish_machine")`)
/// and whose committed object id is the template id itself
/// (`world_device.rs` `next["objectStates"][&pointer.template_id] = object`).
pub fn device_templates(snapshot: &Value) -> Vec<&Value> {
    snapshot["builtinDevices"]["templates"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|template| {
            text(&template["id"]).is_some() && device_name(template["renderer"].as_str()).is_some()
        })
        .collect()
}

/// Whether `id` is one of the world's own built-in devices. This is the only
/// test the adapter uses to pick the device command face, so the decision comes
/// from the host's own catalog and never from an id prefix.
pub fn is_builtin_device(snapshot: &Value, id: &str) -> bool {
    device_templates(snapshot)
        .iter()
        .any(|template| template["id"].as_str() == Some(id))
}

/// Whether a device is in the room: the world state records it under its own
/// template id with `isEnabled` (`world_device.rs::can_place` reads the same
/// field). A device has no tombstone path — `delete` is refused for it — so it
/// can never appear under 已结束.
fn device_placed(snapshot: &Value, id: &str) -> bool {
    snapshot["unityWorldAuthority"]["state"]["objectStates"][id]["isEnabled"].as_bool() == Some(true)
}

/// 基础设备 rows: the same shape, the same groups and the same status words as a
/// generated prop. `place` is the device's real capability and the row's
/// selectability marker; 删除 is deliberately absent (no entry to click).
fn device_rows(snapshot: &Value) -> Vec<Row> {
    device_templates(snapshot)
        .into_iter()
        .filter_map(|template| {
            let id = text(&template["id"])?;
            let name = device_name(template["renderer"].as_str())
                .map(str::to_owned)
                .unwrap_or_else(|| id.to_owned());
            let placed = device_placed(snapshot, id);
            let state = if placed { "placed" } else { "inInventory" };
            Some(Row {
                id: format!("device:{id}"),
                object_id: id.to_owned(),
                job_id: None,
                name,
                state,
                status: if placed { "已摆放" } else { "在库里（没摆）" }.into(),
                actions: vec!["place"],
                group: group_of(state),
                device: Some(id.to_owned()),
            })
        })
        .collect()
}

/// The whole list: world objects, tombstones and wish jobs, one row each.
///
/// A world object always wins over its wish job (the object is the ownership
/// authority), so a job whose object is present is never repeated.
pub fn rows(snapshot: &Value) -> Vec<Row> {
    let state = &snapshot["unityWorldAuthority"]["state"];
    let held_id = text(&state["heldProp"]["objectID"]);
    let mut out = Vec::new();
    let mut present: Vec<String> = Vec::new();
    for item in snapshot["unityInventory"].as_array().into_iter().flatten() {
        let Some(object_id) = text(&item["objectID"]) else {
            continue;
        };
        present.push(object_id.to_owned());
        let name = text(&item["name"]).unwrap_or(object_id).to_owned();
        let held = item["held"].as_bool() == Some(true) || held_id == Some(object_id);
        let placed = item["placed"].as_bool() == Some(true);
        let ready = item["modelReady"].as_bool() == Some(true);
        let (state, status, actions): (&'static str, String, Vec<&'static str>) = if held {
            ("placed", "在居民手里".into(), vec!["withdraw", "delete"])
        } else if placed {
            ("placed", "已摆放".into(), vec!["withdraw", "delete"])
        } else if ready {
            (
                "inInventory",
                "在库里（没摆）".into(),
                vec!["place", "delete"],
            )
        } else {
            // The old adapter disabled 摆放 until the model was loaded; the row
            // is not selectable, so no control promises a placement it cannot do.
            (
                "inInventory",
                "在库里（没摆）· 模型尚未载入".into(),
                vec!["delete"],
            )
        };
        out.push(Row {
            id: format!("object:{object_id}"),
            object_id: object_id.to_owned(),
            job_id: None,
            name,
            state,
            status,
            actions,
            group: group_of(state),
            device: None,
        });
    }
    // 基础设备 come next, before the tombstones: same list, same groups, same
    // status words — they are the room's own objects, not a second surface.
    // (A device is never a tombstone: `delete` is refused for it.)
    out.extend(device_rows(snapshot));
    // Deleted objects leave `objectStates` and become tombstones; that is the
    // only place 「已结束」 can still name them.
    for (id, tombstone) in state["propTombstones"].as_object().into_iter().flatten() {
        if present.iter().any(|p| p == id) {
            continue;
        }
        let name = text(&tombstone["displayName"]).unwrap_or(id).to_owned();
        out.push(Row {
            id: format!("ended:{id}"),
            object_id: id.clone(),
            job_id: None,
            name,
            state: "ended",
            status: "已删除".into(),
            actions: Vec::new(),
            group: "ended",
            device: None,
        });
    }
    // Newest wish first (the array is append-ordered), and only jobs whose object
    // is not in the world — otherwise the world row already speaks for it.
    for entry in snapshot["wish"]["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .rev()
    {
        let Some(wish_id) = text(&entry["wishID"]) else {
            continue;
        };
        let object_id = entry["objectID"].as_str().unwrap_or("").to_owned();
        if !object_id.is_empty() && present.iter().any(|p| p == &object_id) {
            continue;
        }
        let claimable = entry["claimAvailable"].as_bool() == Some(true);
        let (state, status, actions): (&'static str, &str, Vec<&'static str>) =
            match entry["stage"].as_str().unwrap_or("") {
                "claimed" => (
                    "failed",
                    "已领取，入库尚未保存",
                    vec!["retryInventoryRegistration"],
                ),
                // `claim_when_arrived` (让居民去取) has no Unity host op, so an
                // unreachable tray shows the row without inventing a channel.
                "ready" => (
                    "awaitingClaim",
                    "未领取",
                    if claimable { vec!["claim"] } else { Vec::new() },
                ),
                "failed" => ("failed", "生成失败", vec!["retry"]),
                "submissionUncertain" => ("generating", "提交结果待确认", vec!["retry"]),
                "submitting" => ("generating", "正在提交后台", Vec::new()),
                "generated" | "generating" => ("generating", "生成中", Vec::new()),
                "cancelled" => ("ended", "已取消", Vec::new()),
                "interrupted" => ("ended", "任务已中断", Vec::new()),
                _ => continue,
            };
        out.push(Row {
            id: format!("wish:{wish_id}"),
            object_id,
            job_id: Some(wish_id.to_owned()),
            name: text(&entry["name"]).unwrap_or(wish_id).to_owned(),
            state,
            status: status.to_owned(),
            actions,
            group: group_of(state),
            device: None,
        });
    }
    out
}

fn row_json(row: &Row) -> Value {
    json!({
        "id": row.id,
        "objectID": row.object_id,
        "jobID": row.job_id,
        "name": row.name,
        "state": row.state,
        "statusText": row.status,
        "actions": row.actions,
        // Null for every generated prop / wish row; the component's device
        // branch is driven by this and by `selected.deviceTemplateID` only.
        "deviceTemplateID": row.device,
    })
}

/// The component's snapshot, derived from the Unity host's facts only.
pub fn project(snapshot: &Value, local: &LocalState) -> Value {
    let state = &snapshot["unityWorldAuthority"]["state"];
    let mut all = rows(snapshot);
    if local.placed_only {
        all.retain(|row| row.group == "inRoom");
    }
    let row_count = all.len();
    let mut sections = Vec::new();
    let mut remaining = 0usize;
    let mut budget = ROW_BUDGET;
    for group in ["needsYou", "inInventory", "inRoom"] {
        let in_group: Vec<&Row> = all.iter().filter(|row| row.group == group).collect();
        if in_group.is_empty() {
            continue;
        }
        let shown: Vec<&Row> = in_group.iter().copied().take(budget).collect();
        if shown.is_empty() {
            remaining += in_group.len();
            continue;
        }
        budget -= shown.len();
        remaining += in_group.len() - shown.len();
        sections.push(json!({
            "group": group,
            "title": section_title(group, in_group.len()),
            "isFolded": false,
            "rows": shown.iter().map(|row| row_json(row)).collect::<Vec<_>>(),
        }));
    }
    let ended: Vec<&Row> = all.iter().filter(|row| row.group == "ended").collect();
    if !ended.is_empty() {
        if local.ended_folded || budget == 0 {
            // A folded group states its count and occupies no row budget.
            sections.push(json!({
                "group": "ended",
                "title": section_title("ended", ended.len()),
                "isFolded": true,
                "rows": [],
            }));
        } else {
            let shown: Vec<&Row> = ended.iter().copied().take(budget).collect();
            remaining += ended.len() - shown.len();
            sections.push(json!({
                "group": "ended",
                "title": section_title("ended", ended.len()),
                "isFolded": false,
                "rows": shown.iter().map(|row| row_json(row)).collect::<Vec<_>>(),
            }));
        }
    }
    let selected = local
        .selected
        .as_deref()
        .and_then(|id| selected_json(snapshot, local, id))
        .unwrap_or(Value::Null);
    let mut projection = json!({
        "placedOnly": local.placed_only,
        // The wish bridge is the only thing that knows a host operation is in
        // flight; `inventoryMutation` carries no pending flag.
        "isSaving": snapshot["wish"]["pending"].as_bool() == Some(true),
        "canUndo": state["layoutUndo"].is_object(),
        "rowCount": row_count,
        "remainingCount": remaining,
        "holdPoints": HOLD_POINTS.iter().map(|(id, name)| json!({"id": id, "name": name})).collect::<Vec<_>>(),
        "sections": sections,
        "selected": selected,
        // The Unity host publishes no wall faces / legend for this surface;
        // saying nothing is better than the standalone fallback's claim about a
        // room this layer never measured.
        "wallPlacementText": "",
        "notice": notice(snapshot),
    });
    // `unityInventory` absent is the old adapter's "waiting for the space" state;
    // with no rows yet the component would otherwise say "nothing has been wished
    // for", which is a different claim.
    if snapshot["unityInventory"].is_null() {
        projection["emptyMessage"] = json!("等待空间物品载入状态");
    }
    projection
}

fn selected_json(snapshot: &Value, local: &LocalState, id: &str) -> Option<Value> {
    // A built-in device is selectable exactly like a generated prop: the same
    // row click, the same status read from the world state. What it must not
    // claim is a generated asset's control set (收回 / 挂点 / 尺寸 / 删除) —
    // `deviceTemplateID` is what makes the component draw the device's one real
    // operation instead, and it is the id the host's `ui.device.place` takes.
    if is_builtin_device(snapshot, id) {
        let name = device_templates(snapshot)
            .into_iter()
            .find(|template| template["id"].as_str() == Some(id))
            .and_then(|template| device_name(template["renderer"].as_str()))
            .map(str::to_owned)
            .unwrap_or_else(|| id.to_owned());
        let placed = device_placed(snapshot, id);
        return Some(json!({
            "objectID": id,
            "name": name,
            // A device can never be in a resident's hand: every `hold` arm goes
            // through the generated-prop reducer (`world_prop.rs:1884`).
            "held": false,
            // 摆放 is the only op, and it is available whether the device is
            // already placed (the host's device placement relocates it) or not.
            "enabled": placed,
            "deviceTemplateID": id,
            "holdPoint": local.hold_point,
        }));
    }
    let item = snapshot["unityInventory"]
        .as_array()?
        .iter()
        .find(|item| item["objectID"].as_str() == Some(id))?;
    let state = &snapshot["unityWorldAuthority"]["state"];
    let held = item["held"].as_bool() == Some(true) || state["heldProp"]["objectID"].as_str() == Some(id);
    let ready = item["modelReady"].as_bool() == Some(true);
    Some(json!({
        "objectID": id,
        "name": text(&item["name"]).unwrap_or(id),
        "held": held,
        "enabled": item["placed"].as_bool() == Some(true),
        "holdPoint": local.hold_point,
        // 拿着看 enters placement; a model that is not loaded cannot.
        "holdUnavailableReason": if !held && !ready { json!("模型正在载入，物品已保留") } else { Value::Null },
    }))
}

/// The one notice the panel shows, read from the receipts the host publishes.
pub fn notice(snapshot: &Value) -> String {
    let mutation = &snapshot["inventoryMutation"];
    if mutation["status"] == "failed" {
        return text(&mutation["message"])
            .unwrap_or("删除失败，请查看空间状态")
            .to_owned();
    }
    let receipt = &snapshot["unityUICommandResult"];
    if matches!(
        receipt["op"].as_str(),
        Some("ui.inventory.place" | "ui.device.place")
    ) {
        match receipt["status"].as_str() {
            Some("rejected") => {
                return "当前无法开始摆放，请等待模型与场景准备完成后重试。".into();
            }
            Some("started") => return "已进入摆放预览；请在场景中确认位置。".into(),
            _ => {}
        }
    }
    let wish = &snapshot["wish"];
    match wish["status"].as_str() {
        Some("failed") => text(&wish["message"]).unwrap_or("操作未完成，请重试。").to_owned(),
        Some("completed") => match wish["operation"].as_str() {
            Some("wish.claim") => "已领取，入库完成后会出现在「我的物件」里。".into(),
            Some("wish.retry") => "已重新提交生成。".into(),
            Some("wish.inventory.retry") => "正在补做入库。".into(),
            Some("wish.status") => String::new(),
            _ => String::new(),
        },
        _ => String::new(),
    }
}

fn request_id(sequence: &mut u64) -> String {
    *sequence += 1;
    format!("gpui-prop-{sequence}")
}

/// The object the command addresses: its own payload, else the selected row.
fn target(command: &Value, local: &LocalState) -> Option<String> {
    text(&command["objectID"])
        .map(str::to_owned)
        .or_else(|| local.selected.clone())
}

fn world_id(snapshot: &Value) -> Option<&str> {
    text(&snapshot["unityWorldAuthority"]["state"]["worldID"])
}

/// `world.prop.command` ({UnityWorldBridge.swift:187} accepted vocabulary),
/// carrying the same revisions the Unity player sends.
fn prop_command(snapshot: &Value, request: String, command: Value) -> Option<Value> {
    let world = world_id(snapshot)?;
    let revision = snapshot["unityWorldAuthority"]["recordRevision"].as_u64()?;
    let layout = snapshot["unityWorldAuthority"]["state"]["layoutRevision"].as_u64()?;
    Some(json!({
        "op": "world.prop.command",
        "worldID": world,
        "requestID": request,
        "expectedRevision": revision,
        "expectedLayoutRevision": layout,
        "command": command,
    }))
}

/// The held prop's persisted grip calibration (`gmgn.prop-grip.v1`).
fn grip(snapshot: &Value, object_id: &str) -> Option<Value> {
    let raw = snapshot["unityWorldAuthority"]["state"]["objectStates"][object_id]["metadata"]
        ["gmgn.prop-grip.v1"]
        .as_str()?;
    serde_json::from_str(raw).ok()
}

fn vec3(value: &Value) -> Option<[f32; 3]> {
    let items = value.as_array()?;
    let mut out = [0f32; 3];
    for (index, slot) in out.iter_mut().enumerate() {
        *slot = items.get(index)?.as_f64()? as f32;
        if !slot.is_finite() {
            return None;
        }
    }
    Some(out)
}

fn quat(value: &Value) -> Option<[f32; 4]> {
    let items = value.as_array()?;
    let mut out = [0f32; 4];
    for (index, slot) in out.iter_mut().enumerate() {
        *slot = items.get(index)?.as_f64()? as f32;
        if !slot.is_finite() {
            return None;
        }
    }
    Some(out)
}

/// The component's command → the Unity host's op. `None` means the command was
/// local state (already applied to `local`) or has no existing host op.
pub fn translate(
    command: &Value,
    snapshot: &Value,
    local: &mut LocalState,
    sequence: &mut u64,
) -> Option<Value> {
    let op = command["op"].as_str()?;
    // The scope, the fold and the selection are this click's UI state: they are
    // the same for a generated prop, a wish job and a built-in device, and they
    // never become host commands. They are decided before the device guard so a
    // selected device can still be deselected, folded or scoped.
    match op {
        "stage.props.filter" => {
            local.placed_only = command["placedOnly"].as_bool() == Some(true);
            return None;
        }
        "stage.props.fold" => {
            local.ended_folded = command["folded"].as_bool() == Some(true);
            return None;
        }
        "stage.props.select" => {
            local.selected = text(&command["objectID"]).map(str::to_owned);
            return None;
        }
        _ => {}
    }
    // 基础设备的命令面只有一条真实路径。The world authority takes exactly
    // `ui.device.place` for a device (`world_device.rs::can_place` accepts a
    // device whose only metadata is `gmgn.builtin-device.v1`, and
    // `WorldInteractionController.BeginDevicePlacement` serves both a first
    // placement and a relocation), while every `world.prop.command` arm —
    // delete, withdraw, hold, adjustGrip, resize, place — runs
    // `world_prop::reduce`, whose first act is `generated(&before)?` →
    // `world_prop_basic_object` (`services/gmgn-taskd/src/world_prop.rs:1884`
    // → `:130-134`). So an unsupported op for a device is refused *here*, before
    // any command exists, instead of becoming a click that fails.
    if let Some(device) = target(command, local).filter(|id| is_builtin_device(snapshot, id)) {
        return match op {
            // 摆放 / 重新摆放 — the host's own device placement.
            "stage.props.hold" if command["point"].is_null() => {
                device_place_command(&json!({"id": device}))
            }
            // Read/refresh and the panel's × are not object mutations and stay
            // available for a device exactly as they are for anything else.
            "stage.props.load" => Some(json!({"op": "wish.status", "requestID": request_id(sequence)})),
            "stage.props.close" => Some(json!({"op": "ui.overlay.panel", "expanded": false})),
            // Everything else here (delete / withdraw / hold point / resize /
            // nudge / rotate / return) would be refused by name.
            _ => None,
        };
    }
    match op {
        // Read/refresh the wish projection through the bridge that owns it.
        "stage.props.load" => Some(json!({"op": "wish.status", "requestID": request_id(sequence)})),
        "stage.props.claim" | "stage.props.retry" | "stage.props.retryInventoryRegistration" => {
            let wish = match command["op"].as_str()? {
                "stage.props.claim" => "wish.claim",
                "stage.props.retry" => "wish.retry",
                _ => "wish.inventory.retry",
            };
            let wish_id = text(&command["jobID"])?;
            Some(json!({"op": wish, "requestID": request_id(sequence), "wishID": wish_id}))
        }
        // Permanent delete: the existing world-session mutation and its payload.
        "stage.props.delete" => {
            let id = target(command, local)?;
            let world = world_id(snapshot)?;
            let layout = snapshot["unityWorldAuthority"]["state"]["layoutRevision"].as_u64()?;
            Some(json!({
                "op": "inventory.delete",
                "worldID": world,
                "objectID": id,
                "layoutRevision": layout,
            }))
        }
        "stage.props.withdraw" => {
            let id = target(command, local)?;
            prop_command(snapshot, request_id(sequence), json!({"op": "withdraw", "objectID": id}))
        }
        "stage.props.hold" => match text(&command["point"]) {
            // A hold point: the existing `hold` command, same slot vocabulary.
            Some(point) => {
                local.hold_point = point.to_owned();
                let id = target(command, local)?;
                prop_command(
                    snapshot,
                    request_id(sequence),
                    json!({"op": "hold", "objectID": id, "slot": point}),
                )
            }
            // 拿着看 is the placement entry the old adapter exposed.
            None => {
                let id = target(command, local)?;
                Some(json!({"op": "ui.inventory.place", "objectID": id}))
            }
        },
        "stage.props.return" => {
            let id = target(command, local)?;
            prop_command(snapshot, request_id(sequence), json!({"op": "returnHeld", "objectID": id}))
        }
        "stage.props.nudge" => {
            let id = target(command, local)?;
            let current = grip(snapshot, &id)?;
            let offset = vec3(&current["localOffset"])?;
            let rotation = quat(&current["localRotation"])?;
            let y = command["y"].as_f64()? as f32;
            let z = command["z"].as_f64()? as f32;
            if !y.is_finite() || !z.is_finite() {
                return None;
            }
            prop_command(
                snapshot,
                request_id(sequence),
                json!({
                    "op": "adjustGrip",
                    "objectID": id,
                    "offset": [offset[0], offset[1] + y, offset[2] + z],
                    "rotation": rotation,
                }),
            )
        }
        "stage.props.rotate" => {
            let id = target(command, local)?;
            let direction = command["direction"].as_f64()? as f32;
            if !matches!(direction, -1.0 | 1.0) {
                return None;
            }
            let current = grip(snapshot, &id)?;
            let offset = vec3(&current["localOffset"])?;
            let q = quat(&current["localRotation"])?;
            // Same yaw derivation as the original `rotateHeld`.
            let yaw = (2. * (q[3] * q[1] + q[0] * q[2])).atan2(1. - 2. * (q[1] * q[1] + q[2] * q[2]))
                + direction * ROTATE_RADIANS;
            prop_command(
                snapshot,
                request_id(sequence),
                json!({
                    "op": "adjustGrip",
                    "objectID": id,
                    "offset": offset,
                    "rotation": [0., (yaw / 2.).sin(), 0., (yaw / 2.).cos()],
                }),
            )
        }
        "stage.props.undo" => prop_command(snapshot, request_id(sequence), json!({"op": "undo"})),
        // Manual size: the Rust reducer's own `resize` arm
        // (`services/gmgn-taskd/src/world_prop.rs` `apply_command`), which the
        // Unity world bridge now forwards (`UnityWorldBridge.submitProp`).
        // `targetLongestEdge` is the UI slider's value and is validated against
        // the same 0.02…3 m the component's own slider exposes
        // (`world_prop.rs` `validate_command`,
        // `ui_tokens::props::SIZE_MIN/SIZE_MAX`).
        "stage.props.resize" => {
            let id = target(command, local)?;
            let value = command["value"].as_f64()?;
            if !value.is_finite()
                || !(prop_metrics::SIZE_MIN as f64..=prop_metrics::SIZE_MAX as f64).contains(&value)
            {
                return None;
            }
            prop_command(
                snapshot,
                request_id(sequence),
                json!({"op": "resize", "objectID": id, "targetLongestEdge": value}),
            )
        }
        // The panel's × is not an object mutation: it asks the overlay to
        // collapse the 物品 panel. That is exactly the shell's own toggle
        // (`ShellPane::set_panel`, `ui.overlay.panel {expanded:false}`), the op
        // the Unity probe already turns into `gmgn_overlay_set_panel_expanded`
        // (`GPUIChat2Probe.Update`), so the native hit region and the GPUI
        // panel state change together instead of the click being dropped.
        "stage.props.close" => Some(json!({"op": "ui.overlay.panel", "expanded": false})),
        // `askResidentToFetch` has no Unity host op (claim is the agent's
        // lease), so it is not invented here. `toggle` / `escape` are not
        // emitted by the component.
        _ => None,
    }
}

/// The built-in device placement the old adapter exposed, kept verbatim.
pub fn device_place_command(template: &Value) -> Option<Value> {
    let id = text(&template["id"])?;
    Some(json!({"op": "ui.device.place", "templateID": id}))
}

pub struct InventoryPane {
    editor: Entity<ResidentPropEditorPane>,
    commands: UiCommandQueue,
    /// A projection that still needs a `Window`; the deferred pass takes it, the
    /// render fallback takes it when the window was busy.
    pending: Rc<RefCell<Option<Value>>>,
    snapshot: Value,
    local: LocalState,
    sequence: u64,
    notice: String,
    _observation: Subscription,
}

impl InventoryPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>, commands: UiCommandQueue) -> Self {
        let editor = cx.new(|cx| ResidentPropEditorPane::new(window, cx));
        // The component pushes a command and then notifies; that notify is the
        // only signal a click happened, so the queue is drained from it.
        let observation = cx.observe(&editor, |this, _, cx| this.collect(cx));
        Self {
            editor,
            commands,
            pending: Rc::new(RefCell::new(None)),
            snapshot: Value::Null,
            local: LocalState::default(),
            sequence: 0,
            notice: String::new(),
            _observation: observation,
        }
    }

    pub fn update_snapshot(&mut self, snapshot: &Value, cx: &mut Context<Self>) {
        self.snapshot = snapshot.clone();
        self.notice = notice(snapshot);
        // A selection survives while the host still publishes the object: a
        // generated prop from `unityInventory`, or one of the world's own
        // devices. A device is never in `unityInventory`
        // (`WorldRuntimeBridge.PublishInventory` lists only objects carrying
        // `gmgn.generated-prop.v1`, and a device carries
        // `gmgn.builtin-device.v1`), so without this a selected 音乐播放器 would
        // be dropped on the next snapshot.
        let selection_alive = self.local.selected.as_deref().is_none_or(|id| {
            is_builtin_device(snapshot, id)
                || snapshot["unityInventory"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|item| item["objectID"].as_str() == Some(id))
        });
        if !selection_alive {
            self.local.selected = None;
        }
        self.publish(cx);
        self.collect(cx);
        cx.notify();
    }

    /// Hand the projection to the component. `with_window` resolves the window
    /// seeded at creation, so a closed panel still keeps its facts current.
    fn publish(&mut self, cx: &mut Context<Self>) {
        let mut projection = project(&self.snapshot, &self.local);
        // A local problem (a full queue) outranks the host's last receipt until
        // the next snapshot replaces it.
        if !self.notice.is_empty() {
            projection["notice"] = json!(self.notice);
        }
        *self.pending.borrow_mut() = Some(projection.clone());
        let editor = self.editor.clone();
        let pending = self.pending.clone();
        cx.defer(move |cx| {
            let Some(projection) = pending.borrow_mut().take() else {
                return;
            };
            let fallback = projection.clone();
            let applied = cx
                .with_window(editor.entity_id(), |window, cx| {
                    editor.update(cx, |pane, cx| pane.update_snapshot(projection, window, cx));
                })
                .is_some();
            if !applied {
                *pending.borrow_mut() = Some(fallback);
            }
        });
    }

    fn apply_pending(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(projection) = self.pending.borrow_mut().take() {
            self.editor
                .update(cx, |pane, cx| pane.update_snapshot(projection, window, cx));
        }
    }

    /// Drain the component's commands into the one shared transport queue.
    fn collect(&mut self, cx: &mut Context<Self>) {
        let incoming = self.editor.update(cx, |pane, _| pane.take_commands());
        if incoming.is_empty() {
            return;
        }
        let before = self.local.clone();
        // The panel's × is the overlay shell's own panel toggle. The shell owns
        // that state, and we are inside the shell's render, so the update is
        // deferred instead of called here. The command is still left in the
        // queue on purpose: the Unity probe answers `ui.overlay.panel` locally
        // (`GPUIChat2Probe.Update` → `gmgn_overlay_set_panel_expanded`), so
        // the native hit region and the GPUI panel collapse in the same tick.
        let mut closed_panel = false;
        for command in incoming {
            if command["op"].as_str() == Some("stage.props.close") {
                closed_panel = true;
            }
            if let Some(op) = translate(&command, &self.snapshot, &mut self.local, &mut self.sequence)
            {
                if !enqueue_ui_command(&self.commands, op) {
                    self.notice = QUEUE_FULL.into();
                }
            }
        }
        if closed_panel {
            cx.defer(|cx| crate::close_overlay_panel(cx));
        }
        // A local state change (scope, fold, selection, hold point) is only
        // visible after the component gets the re-projection.
        if self.local != before {
            self.publish(cx);
        }
    }
}

impl Render for InventoryPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.apply_pending(window, cx);
        self.collect(cx);
        // One panel, one card: 基础设备 rows live inside the component's list
        // (`device_rows`), so there is no second surface to anchor and nothing
        // for two panels to overlap with. The shell pins this pane to the same
        // bottom-right corner as the transport bar (`shell_ui.rs`
        // `panel_container`), which is the original's
        // `propEditorPanel.trailing/bottom == transportControls.trailing/top`
        // (`StageWindowController.swift:1521-1526`).
        div()
            .flex()
            .flex_col()
            .min_h_0()
            .min_w_0()
            .gap(px(s::PANEL_GAP))
            .font_family(tokens::FONT_FAMILY)
            .text_size(px(tokens::BODY))
            .text_color(rgba(s::TEXT))
            .child(self.editor.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // gpui re-exports a `test` attribute macro and `super::*` shadows the
    // built-in one, so name it explicitly like the rest of this crate does.
    use core::prelude::v1::test;
    use serde_json::json;

    /// The Unity host facts, in the shape `WorldRuntimeBridge.PublishInventory`,
    /// `UnityWorldSessionComposition.snapshot` and `UnityWishMachineBridge.snapshot`
    /// publish them.
    fn production() -> Value {
        json!({
            "unityInventory": [
                {"objectID":"prop-placed","name":"落地灯","modelReady":true,"held":false,"placed":true,"status":"restored"},
                {"objectID":"prop-bag","name":"背包","modelReady":true,"held":false,"placed":false,"status":"inventory"},
                {"objectID":"prop-loading","name":"未载入","modelReady":false,"held":false,"placed":false,"status":"pending"},
                {"objectID":"prop-hand","name":"长剑","modelReady":true,"held":true,"placed":false,"status":"attachment_pending"},
            ],
            "unityWorldAuthority": {
                "recordRevision": 12,
                "state": {
                    "worldID":"world-a",
                    "layoutRevision": 4,
                    "heldProp": {"objectID":"prop-hand","avatarAssetID":"2b","hand":"rightHand"},
                    "layoutUndo": {},
                    "propTombstones": {"prop-gone":{"objectID":"prop-gone","displayName":"旧花瓶"}},
                    "objectStates": {
                        "prop-hand": {"metadata": {"gmgn.prop-grip.v1": "{\"avatarAssetID\":\"2b\",\"hand\":\"rightHand\",\"normalizedGrip\":[0.5,0.5,0.5],\"localOffset\":[0.0,0.0,0.0],\"localRotation\":[0.0,0.0,0.0,1.0]}"}},
                        // Devices are committed into the same `objectStates` under
                        // their template id (`world_device.rs`), with the
                        // `gmgn.builtin-device.v1` declaration and nothing else.
                        "prop.jukebox": {"isEnabled":true,"metadata":{"gmgn.builtin-device.v1":"{\"id\":\"prop.jukebox\"}"}},
                        "wish_machine.device": {"isEnabled":false,"metadata":{"gmgn.builtin-device.v1":"{\"id\":\"wish_machine.device\"}"}},
                        // An object whose id matches one of the non-device
                        // templates: it is an ordinary object, never a device.
                        "prop.not-a-device": {"isEnabled":true,"metadata":{}}
                    }
                }
            },
            "wish": {
                "pending": false,
                "status": "idle",
                "entries": [
                    {"wishID":"w-claim","objectID":"prop-claim","name":"许愿剑","stage":"ready","claimAvailable":true,"inventoryRegistered":false},
                    {"wishID":"w-far","objectID":"prop-far","name":"够不到","stage":"ready","claimAvailable":false,"inventoryRegistered":false},
                    {"wishID":"w-fail","objectID":"prop-fail","name":"失败的","stage":"failed","claimAvailable":false,"inventoryRegistered":false},
                    {"wishID":"w-pending","objectID":"prop-pending","name":"生成中","stage":"generating","claimAvailable":false,"inventoryRegistered":false},
                    {"wishID":"w-lost","objectID":"prop-lost","name":"入库未保存","stage":"claimed","claimAvailable":false,"inventoryRegistered":false},
                    {"wishID":"w-cancelled","objectID":"prop-cancelled","name":"已取消","stage":"cancelled","claimAvailable":false,"inventoryRegistered":false},
                    {"wishID":"w-done","objectID":"prop-placed","name":"落地灯","stage":"claimed","claimAvailable":false,"inventoryRegistered":true}
                ]
            },
            "inventoryMutation": {"generation": 3},
            "unityUICommandResult": {"op":"ui.inventory.place","status":"started"},
            // The real shape `UnityBuiltinDevicesBridge.snapshot(package:)` /
            // `UnityMediaHost.swift:1492` publish: the authored procedural
            // declaration under the Rust catalog's own id, plus one template
            // that is not a device at all (negative control). 音乐播放器 is in
            // the room (the world state records it under its own id), 许愿机 is
            // not — so both device groups are exercised.
            "builtinDevices": {"templates": [
                {"id":"prop.jukebox","renderer":"builtin.jukebox","size":[1,1,1]},
                {"id":"wish_machine.device","renderer":"builtin.wish_machine","size":[1,1,1]},
                {"id":"prop.not-a-device","renderer":"prop.procedural","size":[1,1,1]}
            ]}
        })
    }

    fn local() -> LocalState {
        LocalState::default()
    }

    #[test]
    fn rows_are_grouped_from_the_production_facts_only() {
        let all = rows(&production());
        let find = |id: &str| all.iter().find(|row| row.object_id == id).unwrap();
        assert_eq!(find("prop-placed").group, "inRoom");
        assert_eq!(find("prop-placed").status, "已摆放");
        assert_eq!(find("prop-bag").group, "inInventory");
        assert_eq!(find("prop-bag").actions, vec!["place", "delete"]);
        // A model that is not loaded cannot promise 摆放.
        assert_eq!(find("prop-loading").actions, vec!["delete"]);
        assert_eq!(find("prop-hand").status, "在居民手里");
        assert_eq!(find("prop-gone").state, "ended");
        assert_eq!(find("prop-gone").status, "已删除");
        assert_eq!(find("prop-claim").state, "awaitingClaim");
        assert_eq!(find("prop-far").actions, Vec::<&str>::new());
        assert_eq!(find("prop-fail").actions, vec!["retry"]);
        assert_eq!(find("prop-lost").actions, vec!["retryInventoryRegistration"]);
        assert_eq!(find("prop-cancelled").group, "ended");
        // The claimed job whose object is in the world is never a second row.
        assert_eq!(
            all.iter().filter(|row| row.object_id == "prop-placed").count(),
            1
        );
        assert!(all.iter().all(|row| !row.object_id.is_empty()));
    }

    #[test]
    fn the_room_scope_keeps_only_placed_rows() {
        let mut only_room = local();
        only_room.placed_only = true;
        let projection = project(&production(), &only_room);
        assert_eq!(projection["placedOnly"], true);
        let sections = projection["sections"].as_array().unwrap();
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0]["group"], "inRoom");
        // 房间里 = the placed rows, including one the resident is carrying —
        // and, since it is an object of the room, the placed 音乐播放器.
        assert_eq!(projection["rowCount"], 3);

        let mine = project(&production(), &local());
        assert_eq!(mine["placedOnly"], false);
        assert!(mine["rowCount"].as_u64().unwrap() > 1);
        assert!(
            mine["sections"]
                .as_array()
                .unwrap()
                .iter()
                .any(|section| section["group"] == "needsYou")
        );
        // The component owns the empty sentence (`ownership_scope`), so the
        // adapter never spells a second copy of it.
        assert!(projection.get("emptyMessage").is_none());
        // Until the space publishes an inventory the old adapter's "waiting"
        // state is kept, instead of claiming nothing was ever wished for.
        let mut waiting = production();
        waiting["unityInventory"] = Value::Null;
        assert_eq!(
            project(&waiting, &local())["emptyMessage"],
            "等待空间物品载入状态"
        );
    }

    #[test]
    fn ended_is_folded_with_its_count_and_never_hidden() {
        let folded = project(&production(), &local());
        let ended = folded["sections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|section| section["group"] == "ended")
            .unwrap()
            .clone();
        assert_eq!(ended["isFolded"], true);
        assert_eq!(ended["rows"].as_array().unwrap().len(), 0);
        assert!(ended["title"].as_str().unwrap().starts_with("已结束 ("));
        let mut open = local();
        open.ended_folded = false;
        // Only an ended row, so the row budget cannot fold it back.
        let mut only_ended = production();
        only_ended["unityInventory"] = json!([]);
        only_ended["wish"] = json!({"pending": false, "entries": []});
        let unfolded = project(&only_ended, &open);
        let ended = unfolded["sections"]
            .as_array()
            .unwrap()
            .iter()
            .find(|section| section["group"] == "ended")
            .unwrap();
        assert_eq!(ended["isFolded"], false);
        assert!(!ended["rows"].as_array().unwrap().is_empty());
    }

    #[test]
    fn the_row_budget_becomes_the_remaining_count() {
        let mut snapshot = production();
        snapshot["unityInventory"] = json!((0..9)
            .map(|index| json!({"objectID": format!("prop-{index}"), "name": format!("物件{index}"),
                "modelReady": true, "held": false, "placed": true, "status": "restored"}))
            .collect::<Vec<_>>());
        snapshot["wish"] = json!({"pending": false, "entries": []});
        snapshot["unityWorldAuthority"]["state"]["propTombstones"] = json!({});
        // A world whose package authors no devices contributes no device rows;
        // the budget is the same whichever kind of object fills it.
        snapshot["builtinDevices"] = json!({"templates": []});
        let projection = project(&snapshot, &local());
        let rows = projection["sections"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|section| section["rows"].as_array().cloned().unwrap_or_default())
            .count();
        assert_eq!(rows, ROW_BUDGET);
        assert_eq!(projection["remainingCount"], 3);
        assert_eq!(projection["rowCount"], 9);
    }

    /// 基础设备 = 物品：one list, one row shape, the same group/status words as a
    /// generated prop. The only difference is that 删除 has no entry at all
    /// (the world authority answers `world_prop_basic_object` for it:
    /// `services/gmgn-taskd/src/world_prop.rs:1884` → `:130-134`).
    #[test]
    fn builtin_devices_are_rows_in_the_same_list_without_a_delete_entry() {
        let snapshot = production();
        let all = rows(&snapshot);
        let find = |id: &str| all.iter().find(|row| row.object_id == id);

        let jukebox = find("prop.jukebox").expect("音乐播放器 is a row of this list");
        assert_eq!(jukebox.id, "device:prop.jukebox");
        assert_eq!(jukebox.name, "音乐播放器");
        assert_eq!(jukebox.device.as_deref(), Some("prop.jukebox"));
        // Same state/status/group vocabulary as a placed generated prop.
        assert_eq!(jukebox.state, "placed");
        assert_eq!(jukebox.status, "已摆放");
        assert_eq!(jukebox.group, "inRoom");
        assert_eq!(jukebox.group, find("prop-placed").unwrap().group);
        assert_eq!(jukebox.status, find("prop-placed").unwrap().status);
        // The device's real capability, and never 删除.
        assert_eq!(jukebox.actions, vec!["place"]);
        assert!(!jukebox.actions.contains(&"delete"), "no delete entry");

        let wish = find("wish_machine.device").expect("许愿机 is a row of this list");
        assert_eq!(wish.name, "许愿机");
        assert_eq!(wish.state, "inInventory");
        assert_eq!(wish.status, "在库里（没摆）");
        assert_eq!(wish.group, "inInventory");
        assert_eq!(wish.actions, vec!["place"]);
        assert!(!wish.actions.contains(&"delete"));
        // A device is never 已结束 (删除 is refused, so it has no tombstone path).
        assert!(all
            .iter()
            .filter(|row| row.device.is_some())
            .all(|row| row.group == "inRoom" || row.group == "inInventory"));
        // A template that is not one of the two authored renderers never becomes
        // a device row, even when an object state carries its id.
        assert!(all.iter().all(|row| row.object_id != "prop.not-a-device"));
        assert!(!is_builtin_device(&snapshot, "prop.not-a-device"));
        assert!(is_builtin_device(&snapshot, "prop.jukebox"));

        // One list: the device rows sit in the very same sections as the objects.
        // (The wish backlog would eat the 6-row budget before 在房间里, so this
        // projection keeps the world objects and the devices only.)
        let mut list = snapshot.clone();
        list["wish"] = json!({"pending": false, "entries": []});
        list["unityWorldAuthority"]["state"]["propTombstones"] = json!({});
        let projection = project(&list, &local());
        let sections = projection["sections"].as_array().unwrap();
        let room = sections
            .iter()
            .find(|section| section["group"] == "inRoom")
            .unwrap();
        let room_rows = room["rows"].as_array().unwrap();
        assert!(room_rows.iter().any(|row| row["objectID"] == "prop-placed"));
        assert!(room_rows.iter().any(|row| row["objectID"] == "prop.jukebox"));
        assert!(room_rows
            .iter()
            .any(|row| row["deviceTemplateID"] == "prop.jukebox"));
        assert!(room_rows
            .iter()
            .find(|row| row["objectID"] == "prop-placed")
            .unwrap()
            .get("deviceTemplateID")
            .is_some_and(Value::is_null));
        // No device row anywhere in the projection carries a delete action.
        for section in sections {
            for row in section["rows"].as_array().into_iter().flatten() {
                if row["deviceTemplateID"].is_string() {
                    assert!(
                        !row["actions"].as_array().unwrap().contains(&json!("delete")),
                        "{row} must not offer 删除"
                    );
                }
            }
        }
    }

    /// A world that publishes no devices (or a template without an id) adds no
    /// rows: the list is still exactly the generated props and wish jobs.
    #[test]
    fn a_world_without_builtin_devices_adds_no_device_rows() {
        let with_devices = rows(&production()).len();
        let mut snapshot = production();
        snapshot["builtinDevices"] = json!({"templates": []});
        assert!(rows(&snapshot).iter().all(|row| row.device.is_none()));
        assert_eq!(rows(&snapshot).len(), with_devices - 2);
        // A missing key behaves like an empty list.
        snapshot["builtinDevices"] = Value::Null;
        assert!(rows(&snapshot).iter().all(|row| row.device.is_none()));
        // A template the host cannot address (no id) is not a row.
        snapshot["builtinDevices"] = json!({"templates":[{"renderer":"builtin.jukebox"}]});
        assert!(rows(&snapshot).iter().all(|row| row.device.is_none()));
        assert!(!is_builtin_device(&snapshot, "prop.jukebox"));
    }

    /// Selecting a device is selecting an object: the same selection payload,
    /// the same status read, plus the template id that picks the device command
    /// face. It must not claim a generated asset's controls (no longest edge, no
    /// hold point, no 收回).
    #[test]
    fn a_builtin_device_is_selectable_and_projects_no_generated_asset_controls() {
        let mut state = local();
        state.selected = Some("prop.jukebox".into());
        state.hold_point = "back".into();
        let projection = project(&production(), &state);
        let selected = &projection["selected"];
        assert_eq!(selected["objectID"], "prop.jukebox");
        assert_eq!(selected["name"], "音乐播放器");
        assert_eq!(selected["deviceTemplateID"], "prop.jukebox");
        assert_eq!(selected["held"], false);
        assert_eq!(selected["enabled"], true);
        assert_eq!(selected["holdPoint"], "back");
        assert!(selected.get("longestEdge").is_none());
        assert!(selected["holdUnavailableReason"].is_null());

        // 许愿机 is not placed: the same row still selects, and says so.
        state.selected = Some("wish_machine.device".into());
        let projection = project(&production(), &state);
        assert_eq!(projection["selected"]["name"], "许愿机");
        assert_eq!(projection["selected"]["enabled"], false);
        assert_eq!(projection["selected"]["deviceTemplateID"], "wish_machine.device");

        // A template that is not a device cannot be selected as one.
        state.selected = Some("prop.not-a-device".into());
        let projection = project(&production(), &state);
        assert!(projection["selected"].is_null());
    }

    /// 摆放 / 重新摆放 reaches the host through its own device op
    /// (`ui.device.place`, `GPUIChat2Probe.cs:125-138` →
    /// `WorldInteractionController.BeginDevicePlacement`), for a device that is
    /// already in the room as well as for one that is not. Everything the world
    /// authority refuses for a device is refused here, before a click can fail.
    #[test]
    fn a_builtin_device_places_through_ui_device_place_and_nothing_else() {
        let snapshot = production();
        let mut state = local();
        state.selected = Some("prop.jukebox".into());
        let mut sequence = 0;
        let place = translate(
            &json!({"op":"stage.props.hold"}),
            &snapshot,
            &mut state,
            &mut sequence,
        )
        .expect("the placement entry must reach the device op");
        assert_eq!(place, json!({"op":"ui.device.place","templateID":"prop.jukebox"}));
        assert_eq!(place["templateID"], "prop.jukebox");

        // The same entry for a device that is not in the room yet.
        state.selected = Some("wish_machine.device".into());
        assert_eq!(
            translate(&json!({"op":"stage.props.hold"}), &snapshot, &mut state, &mut sequence)
                .expect("an unplaced device places the same way"),
            json!({"op":"ui.device.place","templateID":"wish_machine.device"})
        );

        // A hold point (挂点) is a generated-prop operation.
        state.selected = Some("prop.jukebox".into());
        assert!(
            translate(
                &json!({"op":"stage.props.hold","point":"waist"}),
                &snapshot,
                &mut state,
                &mut sequence
            )
            .is_none()
        );
        // And so is every other operation the authority answers
        // `world_prop_basic_object` for. None of them may become a command.
        for op in [
            json!({"op":"stage.props.delete"}),
            json!({"op":"stage.props.withdraw"}),
            json!({"op":"stage.props.resize","value":1.2}),
            json!({"op":"stage.props.nudge","y":0.02,"z":0.0}),
            json!({"op":"stage.props.rotate","direction":1}),
            json!({"op":"stage.props.return"}),
        ] {
            assert!(
                translate(&op, &snapshot, &mut state, &mut sequence).is_none(),
                "{op} must not become a host command for a built-in device"
            );
        }
        // The read/refresh and the panel's × are not object mutations.
        assert_eq!(
            translate(&json!({"op":"stage.props.load"}), &snapshot, &mut state, &mut sequence)
                .unwrap()["op"],
            "wish.status"
        );
        assert_eq!(
            translate(&json!({"op":"stage.props.close"}), &snapshot, &mut state, &mut sequence)
                .unwrap(),
            json!({"op":"ui.overlay.panel","expanded":false})
        );
        // Local state keeps working while a device is selected: scope, fold and
        // selection are the same for every kind of object.
        assert!(
            translate(
                &json!({"op":"stage.props.filter","placedOnly":true}),
                &snapshot,
                &mut state,
                &mut sequence
            )
            .is_none()
        );
        assert_eq!(state.placed_only, true);
        assert!(
            translate(
                &json!({"op":"stage.props.fold","group":"ended","folded":false}),
                &snapshot,
                &mut state,
                &mut sequence
            )
            .is_none()
        );
        assert_eq!(state.ended_folded, false);
        assert!(
            translate(
                &json!({"op":"stage.props.select","objectID":"prop-bag"}),
                &snapshot,
                &mut state,
                &mut sequence
            )
            .is_none()
        );
        assert_eq!(state.selected.as_deref(), Some("prop-bag"));
    }

    /// The device placement answer is the receipt the adapter already speaks:
    /// the same two sentences `ui.inventory.place` gets, from the same op.
    #[test]
    fn the_device_placement_receipt_uses_the_existing_placement_notice() {
        let mut snapshot = production();
        snapshot["unityUICommandResult"] = json!({"op":"ui.device.place","status":"started"});
        assert_eq!(notice(&snapshot), "已进入摆放预览；请在场景中确认位置。");
        snapshot["unityUICommandResult"] = json!({"op":"ui.device.place","status":"rejected"});
        assert_eq!(
            notice(&snapshot),
            "当前无法开始摆放，请等待模型与场景准备完成后重试。"
        );
    }

    #[test]
    fn selected_follows_the_world_hold_and_disables_the_claim_of_a_loading_model() {
        let mut state = local();
        state.selected = Some("prop-hand".into());
        state.hold_point = "back".into();
        let projection = project(&production(), &state);
        assert_eq!(projection["selected"]["held"], true);
        assert_eq!(projection["selected"]["holdPoint"], "back");
        assert_eq!(projection["selected"]["holdUnavailableReason"], Value::Null);

        state.selected = Some("prop-bag".into());
        let projection = project(&production(), &state);
        assert_eq!(projection["selected"]["held"], false);
        assert_eq!(projection["selected"]["enabled"], false);
        assert_eq!(projection["holdPoints"][0]["id"], "rightHand");
        assert_eq!(projection["holdPoints"][0]["name"], "右手");
    }

    #[test]
    fn notice_reads_the_receipts_the_host_already_publishes() {
        let mut snapshot = production();
        assert_eq!(notice(&snapshot), "已进入摆放预览；请在场景中确认位置。");
        snapshot["unityUICommandResult"] = json!({"op":"ui.inventory.place","status":"rejected"});
        assert_eq!(notice(&snapshot), "当前无法开始摆放，请等待模型与场景准备完成后重试。");
        snapshot["inventoryMutation"] = json!({"status":"failed","message":"空间忙"});
        assert_eq!(notice(&snapshot), "空间忙");
        snapshot["inventoryMutation"] = json!({"status":"idle"});
        snapshot["unityUICommandResult"] = json!({"op":"","status":"idle"});
        snapshot["wish"] = json!({"status":"failed","message":"没有确认"});
        assert_eq!(notice(&snapshot), "没有确认");
        snapshot["wish"] = json!({"status":"completed","operation":"wish.claim"});
        assert_eq!(notice(&snapshot), "已领取，入库完成后会出现在「我的物件」里。");
    }

    #[test]
    fn claim_retry_and_inventory_retry_use_the_existing_wish_ops() {
        let snapshot = production();
        let mut local = local();
        let mut sequence = 0;
        let claim = translate(
            &json!({"op":"stage.props.claim","objectID":"prop-claim","jobID":"w-claim"}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(claim["op"], "wish.claim");
        assert_eq!(claim["wishID"], "w-claim");
        assert!(claim["requestID"].as_str().unwrap().starts_with("gpui-prop-"));
        let retry = translate(
            &json!({"op":"stage.props.retry","jobID":"w-fail"}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(retry["op"], "wish.retry");
        let inventory = translate(
            &json!({"op":"stage.props.retryInventoryRegistration","jobID":"w-lost"}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(inventory["op"], "wish.inventory.retry");
        // Distinct request ids, so the bridge can tell the replies apart.
        assert_ne!(claim["requestID"], retry["requestID"]);
        // Without the job identity no wish op can be addressed.
        assert!(
            translate(&json!({"op":"stage.props.claim"}), &snapshot, &mut local, &mut sequence)
                .is_none()
        );
        // Load is the existing read/refresh.
        assert_eq!(
            translate(&json!({"op":"stage.props.load"}), &snapshot, &mut local, &mut sequence)
                .unwrap()["op"],
            "wish.status"
        );
    }

    #[test]
    fn delete_and_withdraw_use_the_existing_world_ops_and_payloads() {
        let snapshot = production();
        let mut local = local();
        let mut sequence = 0;
        let delete = translate(
            &json!({"op":"stage.props.delete","objectID":"prop-bag"}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(delete["op"], "inventory.delete");
        assert_eq!(delete["objectID"], "prop-bag");
        assert_eq!(delete["worldID"], "world-a");
        assert_eq!(delete["layoutRevision"], 4);

        let withdraw = translate(
            &json!({"op":"stage.props.withdraw","objectID":"prop-placed"}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(withdraw["op"], "world.prop.command");
        assert_eq!(withdraw["command"]["op"], "withdraw");
        assert_eq!(withdraw["command"]["objectID"], "prop-placed");
        assert_eq!(withdraw["expectedRevision"], 12);
        assert_eq!(withdraw["expectedLayoutRevision"], 4);

        let undo = translate(
            &json!({"op":"stage.props.undo"}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(undo["command"]["op"], "undo");
    }

    /// 拿到手上就是旧的摆放入口，点挂点才是既有的 `hold`。
    #[test]
    fn hold_maps_to_the_placement_entry_and_the_slot_to_the_hold_command() {
        let snapshot = production();
        let mut local = local();
        local.selected = Some("prop-bag".into());
        let mut sequence = 0;
        let place = translate(
            &json!({"op":"stage.props.hold"}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(place["op"], "ui.inventory.place");
        assert_eq!(place["objectID"], "prop-bag");

        let hold = translate(
            &json!({"op":"stage.props.hold","point":"waist"}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(hold["op"], "world.prop.command");
        assert_eq!(hold["command"]["op"], "hold");
        assert_eq!(hold["command"]["slot"], "waist");
        assert_eq!(local.hold_point, "waist");

        let back = translate(
            &json!({"op":"stage.props.return"}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(back["command"]["op"], "returnHeld");
    }

    #[test]
    fn held_nudge_and_rotate_use_the_persisted_grip_calibration() {
        let snapshot = production();
        let mut local = local();
        local.selected = Some("prop-hand".into());
        let mut sequence = 0;
        let nudge = translate(
            &json!({"op":"stage.props.nudge","y":0.02,"z":-0.02}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(nudge["command"]["op"], "adjustGrip");
        let offset = nudge["command"]["offset"].as_array().unwrap();
        assert_eq!(offset[0].as_f64().unwrap(), 0.0);
        assert!((offset[1].as_f64().unwrap() - 0.02).abs() < 1e-6);
        assert!((offset[2].as_f64().unwrap() + 0.02).abs() < 1e-6);
        assert_eq!(nudge["command"]["rotation"], json!([0.0, 0.0, 0.0, 1.0]));

        let rotate = translate(
            &json!({"op":"stage.props.rotate","direction":1}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(rotate["command"]["op"], "adjustGrip");
        let yaw = ROTATE_RADIANS;
        let rotation = rotate["command"]["rotation"].as_array().unwrap();
        assert!((rotation[1].as_f64().unwrap() - (yaw / 2.).sin() as f64).abs() < 1e-6);
        assert!((rotation[3].as_f64().unwrap() - (yaw / 2.).cos() as f64).abs() < 1e-6);
        // A direction the original never emits is refused, not guessed.
        assert!(
            translate(
                &json!({"op":"stage.props.rotate","direction":2}),
                &snapshot,
                &mut local,
                &mut sequence
            )
            .is_none()
        );
    }

    #[test]
    fn local_state_commands_never_become_host_ops() {
        let snapshot = production();
        let mut local = local();
        let mut sequence = 0;
        assert!(
            translate(
                &json!({"op":"stage.props.filter","placedOnly":true}),
                &snapshot,
                &mut local,
                &mut sequence
            )
            .is_none()
        );
        assert_eq!(local.placed_only, true);
        assert!(
            translate(
                &json!({"op":"stage.props.fold","group":"ended","folded":false}),
                &snapshot,
                &mut local,
                &mut sequence
            )
            .is_none()
        );
        assert_eq!(local.ended_folded, false);
        assert!(
            translate(
                &json!({"op":"stage.props.select","objectID":"prop-bag"}),
                &snapshot,
                &mut local,
                &mut sequence
            )
            .is_none()
        );
        assert_eq!(local.selected.as_deref(), Some("prop-bag"));
        assert_eq!(sequence, 0);
    }

    /// Ops the Unity host does not accept are refused instead of invented.
    /// `resize` and `close` are no longer in this list: `resize` is the Rust
    /// reducer's own op (see `size_commands_use_the_reducer_and_the_shell`),
    /// and `close` is the shell's `ui.overlay.panel`.
    #[test]
    fn unsupported_component_commands_are_refused_not_invented() {
        let snapshot = production();
        let mut local = local();
        local.selected = Some("prop-bag".into());
        let mut sequence = 0;
        for op in [
            json!({"op":"stage.props.askResidentToFetch","jobID":"w-far"}),
            json!({"op":"stage.props.toggle"}),
            json!({"op":"stage.props.escape"}),
            json!({"op":"stage.props.invented"}),
        ] {
            assert!(
                translate(&op, &snapshot, &mut local, &mut sequence).is_none(),
                "{op} must not become a host op"
            );
        }
        assert_eq!(sequence, 0);
    }

    /// The size slider and the panel's × are wired, not dropped: the slider
    /// emits the reducer's `resize` (with the value the Rust side validates
    /// against the same 0.02…3 m domain), and the × is the shell's existing
    /// panel toggle.
    #[test]
    fn size_commands_use_the_reducer_and_the_shell() {
        let snapshot = production();
        let mut local = local();
        local.selected = Some("prop-bag".into());
        let mut sequence = 0;
        let resize = translate(
            &json!({"op":"stage.props.resize","value":1.2}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .expect("the size slider must reach the reducer");
        assert_eq!(resize["op"], "world.prop.command");
        assert_eq!(resize["command"]["op"], "resize");
        assert_eq!(resize["command"]["objectID"], "prop-bag");
        assert_eq!(resize["command"]["targetLongestEdge"], 1.2);
        // The component's own slider domain, refused locally so the host never
        // sees a value its validator rejects.
        for rejected in [0.001, 10.] {
            assert!(
                translate(
                    &json!({"op":"stage.props.resize","value":rejected}),
                    &snapshot,
                    &mut local,
                    &mut sequence,
                )
                .is_none(),
                "resize {rejected} is outside the reducer's domain and must not be sent"
            );
        }
        let close = translate(
            &json!({"op":"stage.props.close"}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .expect("the panel × must reach the shell");
        assert_eq!(close, json!({"op":"ui.overlay.panel","expanded":false}));
    }

    #[test]
    fn device_placement_keeps_the_old_op_and_payload() {
        let command = device_place_command(&json!({"id":"builtin-jukebox","renderer":"builtin.jukebox"})).unwrap();
        assert_eq!(command["op"], "ui.device.place");
        assert_eq!(command["templateID"], "builtin-jukebox");
        assert!(device_place_command(&json!({"renderer":"builtin.jukebox"})).is_none());
    }

    /// Nothing in this adapter is drawn outside the panel it is given.
    #[test]
    fn the_panel_still_projects_the_production_revisions_for_delete() {
        let mut snapshot = production();
        snapshot["unityWorldAuthority"]["state"]["layoutRevision"] = json!(9);
        let mut local = local();
        let mut sequence = 0;
        let delete = translate(
            &json!({"op":"stage.props.delete","objectID":"prop-bag"}),
            &snapshot,
            &mut local,
            &mut sequence,
        )
        .unwrap();
        assert_eq!(delete["layoutRevision"], 9);
        // Without a world revision the delete is not sent at all.
        snapshot["unityWorldAuthority"] = json!({});
        assert!(
            translate(
                &json!({"op":"stage.props.delete","objectID":"prop-bag"}),
                &snapshot,
                &mut local,
                &mut sequence
            )
            .is_none()
        );
    }
}
