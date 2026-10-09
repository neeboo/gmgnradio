//! Standard product settings, projected through the existing Unity host.
//! No second transport, preference writer, credential store, or optimistic ACK.
use crate::{enqueue_ui_command, UiCommandQueue};
use gmgn_gpui_ui::{settings::AgentSettingsPane, stage_panels::StagePanelsPane};
use gmgn_gpui_ui::{primitives as ui, ui_tokens::{self as tokens, scene as s}};
use gpui_kit::{component::{button::Button, Disableable}, *};
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_PENDING: usize = 32;

/// Ops the Unity settings window translates and forwards itself, in addition to
/// whatever the host advertises in `settings.supportedCommands`. The UI gates
/// each control on this published list (see the call to
/// [`SettingsPane::add_supported_ops`]), so an op listed here is one the window
/// really accepts — never a drawn-but-refused control.
///
/// Every entry has a translation in [`translate_settings_command`] onto an
/// existing production owner:
///
/// | UI op | production entry |
/// |---|---|
/// | `stage.world.enter` | `stage.world.enter` → `space.library.select` transaction (`UnityMediaHost`) |
/// | `stage.scene.activate` | `stage.scene.activate` → `marbleWorlds.activatePreset` (`UnityMediaHost`) |
/// | `stage.avatar.position` | `presence.position` (`UnityCharacterPositionBridge`) |
/// | `stage.avatar.reset` | `presence.position.reset` (same bridge) |
/// | `stage.motion.refresh` | `presence.load` (`UnityPresenceSettingsBridge`) |
/// | `stage.motion.activate` | `presence.motion` (`UnityPresenceSettingsBridge`) |
/// | `stage.activity.run` | `stage.activity.run` → `startActivityMeasured` (`UnityMediaHost`) |
/// | `stage.activity.stop` | `stage.activity.stop` → `stopActivity` (`UnityMediaHost`) |
/// | `settings.open.presence` | local window navigation + `presence.load` (no host op) |
/// | `space.prop.save` | `generation.save` (`UnityGenerationConfigurationBridge`) |
/// | `space.prop.check` | `generation.check` (same bridge) |
/// | `space.prop.cancel` | local edit cancel — never clears a saved credential |
const STAGE_OPS: [&str; 12] = [
    "stage.world.enter",
    "stage.scene.activate",
    "stage.avatar.position",
    "stage.avatar.reset",
    "stage.motion.refresh",
    "stage.motion.activate",
    "stage.activity.run",
    "stage.activity.stop",
    "settings.open.presence",
    "space.prop.save",
    "space.prop.check",
    "space.prop.cancel",
];

/// What the window does with one UI command.
#[derive(Debug, PartialEq)]
enum SettingsRoute {
    /// Forward `command` to the host through the existing settings transport.
    Host(Value),
    /// Local window navigation: open the settings window on 角色管理.
    PresenceSettings,
    /// Local edit cancel: no host command, no credential change.
    LocalEditCancel,
}

/// Translate one UI settings command onto its real production entry.
///
/// A command that cannot be translated on the current snapshot returns the
/// named `code` that the notice shows. Nothing here invents a second world,
/// role, activity or credential store: every field is read from the same
/// envelope the host publishes.
fn translate_settings_command(
    command: &Value,
    snapshot: &Value,
    draft: &mut Option<PositionDraft>,
) -> Result<SettingsRoute, &'static str> {
    let op = command["op"].as_str().ok_or("settings_command_malformed")?;
    let setting = &snapshot["settings"];
    let stage = &setting["stage"];
    match op {
        // UnityHost owns this dispatch; the id must name a world package that
        // actually exists in the published library.
        "stage.world.enter" => {
            let id = command["id"].as_str().filter(|id| !id.is_empty()).ok_or("world_id_required")?;
            let known = setting["spaceLibrary"]["worlds"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|world| world["id"].as_str() == Some(id));
            if !known {
                return Err("world_not_in_library");
            }
            Ok(SettingsRoute::Host(json!({"op": "stage.world.enter", "id": id})))
        }
        "stage.scene.activate" => {
            let id = command["id"].as_str().filter(|id| !id.is_empty()).ok_or("scene_preset_required")?;
            let known = stage["space"]["presets"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|preset| preset["id"].as_str() == Some(id));
            if !known {
                return Err("scene_preset_unknown");
            }
            if stage["space"]["isVisible"].as_bool() != Some(true) {
                return Err("scene_requires_visible_world");
            }
            Ok(SettingsRoute::Host(json!({"op": "stage.scene.activate", "id": id})))
        }
        // `UnityCharacterPositionBridge` validates worldID, requestID and both
        // expected revisions and guards them, so the whole coordinate plus the
        // CAS revisions travel — an axis-only delta is not a position request.
        "stage.avatar.position" => {
            let axis = command["axis"].as_str().ok_or("avatar_axis_required")?;
            let value = command["value"].as_f64().filter(|value| value.is_finite()).ok_or("avatar_value_required")?;
            presence_position_command(axis, value, command, snapshot, draft)
        }
        "stage.avatar.reset" => presence_position_command("", 0., command, snapshot, draft),
        "stage.motion.refresh" => Ok(SettingsRoute::Host(json!({"op": "presence.load"}))),
        "stage.motion.activate" => {
            let id = command["id"].as_str().filter(|id| !id.is_empty()).ok_or("motion_id_required")?;
            let known = setting["presence"]["motions"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|motion| motion["id"].as_str() == Some(id));
            if !known {
                return Err("motion_not_available");
            }
            Ok(SettingsRoute::Host(json!({"op": "presence.motion", "id": id})))
        }
        "stage.activity.run" => {
            let id = command["id"].as_str().filter(|id| !id.is_empty()).ok_or("activity_id_required")?;
            let known = stage["activities"]["items"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|item| item["id"].as_str() == Some(id));
            if !known {
                return Err("activity_not_runnable");
            }
            Ok(SettingsRoute::Host(json!({"op": "stage.activity.run", "id": id})))
        }
        "stage.activity.stop" => Ok(SettingsRoute::Host(json!({"op": "stage.activity.stop"}))),
        "settings.open.presence" => Ok(SettingsRoute::PresenceSettings),
        // The Unity wish-machine form is the `generation.*` surface: the window
        // only draws it when `generation.*` is in the host whitelist, so this
        // arm exists for the product-mode shape of the same two inputs.
        "space.prop.save" => {
            let endpoint = command["endpoint"].as_str().unwrap_or("").trim().to_owned();
            if endpoint.is_empty() {
                return Err("generation_endpoint_required");
            }
            match setting["generation"]["configured"].as_bool() {
                Some(_) => {}
                None => return Err("generation_unavailable"),
            }
            let token = command["apiKey"].as_str().unwrap_or("");
            Ok(SettingsRoute::Host(json!({"op": "generation.save", "endpoint": endpoint, "token": token})))
        }
        "space.prop.check" => {
            if setting["generation"]["configured"].as_bool() != Some(true) {
                return Err("generation_not_configured");
            }
            Ok(SettingsRoute::Host(json!({"op": "generation.check"})))
        }
        // 取消配置 is a local edit cancel by contract: the product host only
        // stops the in-flight check and (optionally) clears its notice. A saved
        // credential is never a draft, so cancelling cannot erase it.
        "space.prop.cancel" => Ok(SettingsRoute::LocalEditCancel),
        _ => Ok(SettingsRoute::Host(command.clone())),
    }
}

/// The last coordinate this window asked for, with the world and layout it was
/// asked against. Three axis sliders each move one axis, so the other two have
/// to come from somewhere that still remembers the edit the host has not
/// confirmed yet — otherwise a quick X-then-Y drag addresses a stale pose.
#[derive(Debug, Clone, PartialEq)]
struct PositionDraft {
    world_id: String,
    layout_revision: u64,
    xyz: [f64; 3],
}

/// One `presence.position` / `presence.position.reset` request built from the
/// host's own `characterPosition` projection (`UnityCharacterPositionBridge`).
/// `axis` empty means the bridge's spawn reset.
fn presence_position_command(
    axis: &str,
    value: f64,
    command: &Value,
    snapshot: &Value,
    draft: &mut Option<PositionDraft>,
) -> Result<SettingsRoute, &'static str> {
    let setting = &snapshot["settings"];
    let character = &setting["characterPosition"];
    let world_id = character["worldID"].as_str().filter(|id| !id.is_empty()).ok_or("character_position_unavailable")?;
    let revision = character["revision"].as_u64().ok_or("character_position_unavailable")?;
    let layout = character["layoutRevision"].as_u64().ok_or("character_position_unavailable")?;
    let base = character["position"]
        .as_array()
        .filter(|position| position.len() == 3)
        .map(|position| position.iter().filter_map(Value::as_f64).collect::<Vec<f64>>())
        .filter(|position| position.len() == 3 && position.iter().all(|value| value.is_finite()))
        .ok_or("character_position_unavailable")?;
    if axis.is_empty() {
        *draft = None;
        return Ok(SettingsRoute::Host(json!({
            "op": "presence.position.reset",
            "worldID": world_id,
            "expectedRevision": revision,
            "expectedLayoutRevision": layout,
            "requestID": position_request_id(world_id, revision),
            "position": base,
        })));
    }
    let index = match axis {
        "X" => 0usize,
        "Y" => 1,
        "Z" => 2,
        _ => return Err("avatar_axis_unknown"),
    };
    // A draft only survives while it still describes the same world and the
    // same authority layout; the CAS revisions themselves always come from the
    // live snapshot.
    let carried = draft
        .as_ref()
        .filter(|draft| draft.world_id == world_id && draft.layout_revision == layout)
        .map(|draft| draft.xyz);
    let mut xyz = carried.unwrap_or([base[0], base[1], base[2]]);
    xyz[index] = value;
    if !xyz.iter().all(|value| value.is_finite()) {
        return Err("avatar_value_required");
    }
    *draft = Some(PositionDraft { world_id: world_id.to_owned(), layout_revision: layout, xyz });
    Ok(SettingsRoute::Host(json!({
        "op": "presence.position",
        "worldID": world_id,
        "expectedRevision": revision,
        "expectedLayoutRevision": layout,
        "requestID": position_request_id(world_id, revision),
        "position": xyz,
    })))
}

/// The bridge requires a bounded, non-empty `requestID`; it also rejects a
/// replay of the same id, so each request gets its own.
fn position_request_id(world_id: &str, revision: u64) -> String {
    let sequence = POSITION_SEQUENCE.with(|sequence| {
        let mut sequence = sequence.borrow_mut();
        *sequence = sequence.wrapping_add(1);
        *sequence
    });
    format!("gpui-settings-position:{world_id}:{revision}:{sequence}")
}

thread_local! {
    static POSITION_SEQUENCE: std::cell::RefCell<u64> = const { std::cell::RefCell::new(0) };
    /// Set while the settings window is asked to land on 角色管理.
    static PENDING_PRESENCE_PAGE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Read-and-clear the "open on 角色管理" request. `lib.rs` calls this when the
/// settings window is (re)created, so the navigation follows the real window
/// instead of a snapshot value the panes do not own.
pub(crate) fn take_pending_presence_page() -> bool {
    PENDING_PRESENCE_PAGE.with(|pending| pending.replace(false))
}

/// The published whitelist: the host's `settings.supportedCommands` plus the
/// stage ops this window translates. The settings window refuses anything that
/// is not in the list it publishes (see [`SettingsPane::dispatch`]), so the UI
/// can treat it as the truth and draw every listed control.
fn settings_supported_ops(host: &[String]) -> Vec<String> {
    let mut out = host.to_vec();
    for op in STAGE_OPS {
        if !out.iter().any(|candidate| candidate == op) {
            out.push(op.to_owned());
        }
    }
    out
}

pub struct SettingsPane {
    controls: Entity<AgentSettingsPane>,
    stage: Entity<StagePanelsPane>,
    commands: UiCommandQueue,
    waiting: VecDeque<Value>,
    pending: Option<String>,
    instance: String,
    sequence: u64,
    supported: Vec<String>,
    loaded: bool,
    notice: String,
    last_envelope: Value,
    /// The full Unity settingsSnapshot envelope, kept so the adapter can build
    /// a real `presence.position` (CAS revisions + full coordinate) or resolve a
    /// world/motion/activity id against the host's own catalogs.
    snapshot: Value,
    /// The unconfirmed coordinate edit, cleared by a reset (see
    /// [`PositionDraft`]).
    draft_position: Option<PositionDraft>,
}

impl SettingsPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>, commands: UiCommandQueue) -> Self {
        let stage = cx.new(|cx| StagePanelsPane::new(window, cx));
        let controls = cx.new(|cx| AgentSettingsPane::new(window, cx));
        controls.update(cx, |view, cx| {
            view.set_unity_external(true, cx);
            view.set_stage_pane(stage.clone(), cx);
        });
        Self {
            controls,
            stage,
            commands,
            waiting: VecDeque::new(),
            pending: None,
            instance: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_nanos().to_string())
                .unwrap_or_default(),
            sequence: 0,
            supported: Vec::new(),
            loaded: false,
            notice: String::new(),
            last_envelope: Value::Null,
            snapshot: Value::Null,
            draft_position: None,
        }
    }

    fn collect(&mut self, cx: &mut Context<Self>) {
        let mut incoming = self.controls.update(cx, |view, _| view.take_commands());
        incoming.extend(self.stage.update(cx, |view, _| view.take_commands()));
        for command in incoming {
            if self.waiting.len() >= MAX_PENDING {
                self.notice = "待保存操作已满，请等待当前操作完成后再试。".into();
                continue;
            }
            self.waiting.push_back(command);
        }
    }

    fn dispatch(&mut self) {
        if self.instance.is_empty() {
            self.notice = "无法创建设置请求，请重新打开设置。".into();
            return;
        }
        if !self.loaded || self.pending.is_some() {
            return;
        }
        while let Some(command) = self.waiting.pop_front() {
            let Some(op) = command["op"].as_str() else {
                self.notice = "设置操作格式无效，未提交。".into();
                continue;
            };
            if !self.supported.iter().any(|candidate| candidate == op) {
                self.notice = format!("当前运行时不支持此操作：{op}");
                continue;
            }
            let route = match translate_settings_command(&command, &self.snapshot, &mut self.draft_position) {
                Ok(route) => route,
                Err(code) => {
                    // A refused request is never reported as a save. The code is
                    // the same shape the host's `settingsCommandResult` uses
                    // (`settings_command_rejected`, `…_unavailable`, …).
                    self.notice = format!("设置未提交（{code}），请检查对应项目的状态后重试。");
                    continue;
                }
            };
            let wire = match route {
                SettingsRoute::Host(wire) => Some(wire),
                SettingsRoute::PresenceSettings => {
                    PENDING_PRESENCE_PAGE.with(|pending| pending.set(true));
                    None
                }
                SettingsRoute::LocalEditCancel => None,
            };
            self.sequence = match self.sequence.checked_add(1) {
                Some(next) => next,
                None => {
                    self.notice = "设置会话已结束，请重新打开设置。".into();
                    return;
                }
            };
            let request = format!("gpui-settings:{}:{}", self.instance, self.sequence);
            let Some(wire) = wire else {
                // Local navigation / local edit cancel: nothing is owed to the
                // host, so no receipt is awaited and nothing is replayed.
                self.notice = "已在本机处理，未改动已保存的配置。".into();
                self.pending = None;
                continue;
            };
            if enqueue_ui_command(
                &self.commands,
                json!({"op":"ui.settings.command", "requestID":request, "command":wire}),
            ) {
                self.pending = Some(request);
                self.notice = "正在等待保存确认…".into();
            } else {
                // Keep the user's original draft. No automatic command replay.
                self.notice = "操作队列已满，这次尚未提交，请稍后重试。".into();
            }
            return;
        }
    }

    /// `settings` is the unchanged full Unity settingsSnapshot envelope, not a
    /// locally synthesized candidate. All subpanes use the same main poll.
    /// Returns `true` when a command asked the window to land on 角色管理 and
    /// the caller (`lib.rs`, owner of the real window) must perform it.
    pub fn update_snapshot(
        &mut self,
        snapshot: &Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let envelope = &snapshot["settings"];
        let before=(self.pending.clone(),self.notice.clone(),self.waiting.len());
        let projection=crate::settings_projection(envelope);
        let envelope_changed=self.last_envelope!=projection;
        if envelope_changed && envelope["settings"].is_object() {
            self.last_envelope=projection;
            self.loaded = true;
            self.supported = envelope["supportedCommands"]
                .as_array()
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default();
            // The window accepts the host's own whitelist plus the stage ops it
            // translates itself (`STAGE_OPS`). Publishing exactly that list to
            // both panes is what makes a supported control reappear instead of
            // staying hidden behind `supported_ops`.
            self.supported = settings_supported_ops(&self.supported);
            self.controls.update(cx, |view, cx| {
                view.set_supported_ops(self.supported.clone(), cx);
                view.update_snapshot(envelope["settings"].clone(), window, cx)
            });
            self.stage.update(cx, |view, cx| {
                view.set_supported_ops(self.supported.clone(), cx);
                view.update_snapshot(envelope["stage"].clone(), window, cx)
            });
            self.snapshot = snapshot.clone();
        }
        let receipt = &snapshot["settingsCommandResult"];
        if self
            .pending
            .as_deref()
            .is_some_and(|id| receipt["requestID"].as_str() == Some(id))
        {
            match receipt["status"].as_str() {
                Some("accepted" | "completed") => {
                    self.pending = None;
                    self.notice = "操作已提交，请等待对应项目确认。".into();
                }
                Some("failed") => {
                    self.pending = None;
                    // The host names the rejected reason (`settings_command_rejected`,
                    // `camera_reset_unavailable`, …). Showing it keeps an
                    // ordinary failure distinguishable from "no handler exists
                    // for this op in this runtime" instead of one generic line.
                    let reason = receipt["code"]
                        .as_str()
                        .filter(|code| !code.is_empty())
                        .unwrap_or("settings_command_rejected");
                    self.notice = format!("设置未保存（{reason}），请检查对应项目的错误提示后重试。");
                }
                _ => {} // Accepted/pending/unknown never become success.
            }
        }
        self.collect(cx);
        self.dispatch();
        if envelope_changed || before!=(self.pending.clone(),self.notice.clone(),self.waiting.len()) {cx.notify();}
        take_pending_presence_page()
    }

    /// Land the settings window on 角色管理 (`settings.open.presence`). This is
    /// the `openPresenceSettings()` navigation the original's
    /// 「管理角色与动作…」 performed; the pane's own `select_page` issues the
    /// `presence.load` the page needs, so no second roster is created.
    pub fn select_presence_page(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        self.controls
            .update(cx, |view, cx| view.select_page("presence", cx));
        self.collect(cx);
        cx.notify();
    }

    pub fn dismissed(&mut self, cx: &mut Context<Self>) {
        self.controls.update(cx, |view, cx| view.dismissed(cx));
        self.collect(cx);
        self.dispatch();
    }

    /// Already dispatched commands live in the host transport. Keep this
    /// window alive while later edits still depend on their acknowledgements.
    pub fn can_close(&mut self, cx: &mut Context<Self>) -> bool {
        self.collect(cx);
        self.dispatch();
        if self.waiting.is_empty() {return true;}
        self.notice = "还有设置正在保存，请稍后关闭窗口。".into();
        cx.notify();
        false
    }
}

impl Render for SettingsPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let content = if self.loaded {
            self.controls.clone().into_any_element()
        } else {
            div()
                .flex()
                .flex_col()
                .gap_3()
                .p_4()
                .child("正在读取当前设置…")
                .child("设置确认前不会覆盖现有配置。")
                .into_any_element()
        };
        div()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .flex()
            .flex_col()
            .font_family(tokens::FONT_FAMILY)
            .text_size(px(tokens::BODY))
            .bg(rgba(s::PANEL_BG))
            .text_color(rgba(s::TEXT))
            .child(
                div()
                    .flex_1()
                    .min_h(px(0.))
                    .min_w(px(0.))
                    .overflow_hidden()
                    .child(content),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .py_2()
                    .border_t_1()
                    .border_color(rgba(s::BORDER))
                    .child(div().flex_1().min_w_0().child(ui::notice(self.notice.clone())))
                    .child(
                        Button::new("settings-refresh")
                            .label("重新读取")
                            .disabled(self.pending.is_some())
                            .on_click(cx.listener(|this, _, _, cx| {
                                if this.waiting.len() < MAX_PENDING {
                                    this.waiting.push_back(json!({"op":"settings.load"}));
                                }
                                this.dispatch();
                                cx.notify();
                            })),
                    ),
            )
    }
}

#[cfg(test)]
mod settings_translation_tests {
    use super::*;
    use core::prelude::v1::test;

    /// The host snapshot shape is the Unity envelope: every root the adapter
    /// reads hangs off `settings` (see `lib.rs::settings_projection`).
    fn envelope() -> Value {
        json!({
            "settings": {
                "stage": {
                    "space": {
                        "presets": [{"id": "snow", "name": "雪原"}],
                        "isVisible": true,
                        "isRequested": true,
                        "selectedWorldID": "world.living-pod"
                    },
                    "activities": {
                        "items": [{"id": "life.coffee", "name": "冲泡一杯咖啡"}],
                        "canRun": true
                    }
                },
                "characterPosition": {
                    "worldID": "world.living-pod",
                    "revision": 41,
                    "layoutRevision": 7,
                    "position": [0.5, -1.25, 2.0],
                    "available": true
                },
                "spaceLibrary": {
                    "worlds": [{"id": "world.living-pod", "name": "生活舱"}],
                    "selectedID": "world.living-pod"
                },
                "presence": {
                    "motions": [{"id": "gmgn.motion.wave", "name": "挥手", "compatible": true}]
                },
                "generation": {"configured": true, "checking": false}
            },
            "supportedCommands": ["settings.load"]
        })
    }

    /// Every capability is reached through the published whitelist — the same
    /// gate `SettingsPane::dispatch` applies before it translates anything. A
    /// regression that stops publishing an op has to turn these tests red, not
    /// just the one that asserts the list itself.
    fn route(command: Value) -> Result<SettingsRoute, &'static str> {
        let op = command["op"].as_str().expect("a test command always names its op");
        assert!(
            settings_supported_ops(&["settings.load".to_owned()]).iter().any(|candidate| candidate == op),
            "{op} is not published by the window ⇒ its control would be hidden"
        );
        let mut draft = None;
        translate_settings_command(&command, &envelope(), &mut draft)
    }

    fn wire(command: Value) -> Value {
        match route(command) {
            Ok(SettingsRoute::Host(value)) => value,
            other => panic!("expected a host command, got {other:?}"),
        }
    }

    /// 进入世界: the package id must name a world the library actually lists,
    /// and the request must go out under the op the Unity host dispatches
    /// (`UnityMediaHost.settingsCommand` `case "stage.world.enter"` onto the
    /// `space.library.select` transaction). An unknown id is a named refusal —
    /// never a locally remembered selection.
    #[test]
    fn entering_a_world_uses_a_real_package_id_and_refuses_unknown_ones() {
        assert_eq!(wire(json!({"op": "stage.world.enter", "id": "world.living-pod"})),
            json!({"op": "stage.world.enter", "id": "world.living-pod"}));
        assert_eq!(route(json!({"op": "stage.world.enter", "id": "invented"})), Err("world_not_in_library"));
        assert_eq!(route(json!({"op": "stage.world.enter"})), Err("world_id_required"));
    }

    /// 切换场景: the preset must be one the host publishes, and the world has to
    /// be visible — `marbleWorlds.activatePreset` first calls
    /// `spatialPresentation.confirmVisible()`, so a hidden world can never be a
    /// successful scene switch.
    #[test]
    fn activating_a_scene_requires_a_published_preset_and_a_visible_world() {
        assert_eq!(wire(json!({"op": "stage.scene.activate", "id": "snow"})),
            json!({"op": "stage.scene.activate", "id": "snow"}));
        assert_eq!(route(json!({"op": "stage.scene.activate", "id": "rain"})), Err("scene_preset_unknown"));
        let mut hidden = envelope();
        hidden["settings"]["stage"]["space"]["isVisible"] = json!(false);
        let mut draft = None;
        assert_eq!(translate_settings_command(&json!({"op": "stage.scene.activate", "id": "snow"}), &hidden, &mut draft),
            Err("scene_requires_visible_world"));
    }

    /// 角色 XYZ: the whole coordinate plus the CAS revisions and a fresh
    /// requestID reach `UnityCharacterPositionBridge`, which guards exactly
    /// those five fields. One axis that changes keeps the other two from the
    /// host's own pose, and the next axis reuses the unconfirmed draft.
    #[test]
    fn avatar_position_carries_the_full_coordinate_and_cas_revisions() {
        // One adapter session: the draft has to persist between two axis edits.
        let mut draft = None;
        let envelope = envelope();
        let first = match translate_settings_command(&json!({"op": "stage.avatar.position", "axis": "X", "value": 3.5}), &envelope, &mut draft) {
            Ok(SettingsRoute::Host(value)) => value,
            other => panic!("expected a host command, got {other:?}"),
        };
        assert_eq!(first["op"], "presence.position");
        assert_eq!(first["worldID"], "world.living-pod");
        assert_eq!(first["expectedRevision"], 41);
        assert_eq!(first["expectedLayoutRevision"], 7);
        assert_eq!(first["position"], json!([3.5, -1.25, 2.0]));
        let first_id = first["requestID"].as_str().expect("a bounded requestID").to_owned();
        assert!(first_id.len() <= 256 && !first_id.is_empty());
        // The draft, not the stale snapshot pose, supplies the unconfirmed X.
        let second = match translate_settings_command(&json!({"op": "stage.avatar.position", "axis": "Z", "value": 9.0}), &envelope, &mut draft) {
            Ok(SettingsRoute::Host(value)) => value,
            other => panic!("expected a host command, got {other:?}"),
        };
        assert_eq!(second["position"], json!([3.5, -1.25, 9.0]));
        assert_ne!(second["requestID"], json!(first_id), "each request needs its own id");
    }

    /// 重置: the bridge's own spawn reset (`presence.position.reset`), which
    /// takes the same identity/revision fields and reads the position from the
    /// host rather than the UI.
    #[test]
    fn avatar_reset_is_the_bridge_spawn_reset_not_a_local_pose() {
        let value = wire(json!({"op": "stage.avatar.reset"}));
        assert_eq!(value["op"], "presence.position.reset");
        assert_eq!(value["worldID"], "world.living-pod");
        assert_eq!(value["expectedRevision"], 41);
        assert_eq!(value["expectedLayoutRevision"], 7);
    }

    /// A pose the host cannot describe is refused by name instead of sending a
    /// half request that the bridge would reject.
    #[test]
    fn avatar_position_refuses_when_the_host_has_no_pose() {
        let mut missing = envelope();
        missing["settings"]["characterPosition"] = json!({});
        let mut draft = None;
        assert_eq!(
            translate_settings_command(&json!({"op": "stage.avatar.position", "axis": "Y", "value": 1.0}), &missing, &mut draft),
            Err("character_position_unavailable")
        );
    }

    /// 刷新 / 播放动作: the two production entries are `presence.load` and
    /// `presence.motion`, the same pair `ProductHost.swift:284-290` forwards.
    #[test]
    fn motion_refresh_and_activation_reuse_the_presence_owner() {
        assert_eq!(wire(json!({"op": "stage.motion.refresh"})), json!({"op": "presence.load"}));
        assert_eq!(wire(json!({"op": "stage.motion.activate", "id": "gmgn.motion.wave"})),
            json!({"op": "presence.motion", "id": "gmgn.motion.wave"}));
        assert_eq!(route(json!({"op": "stage.motion.activate", "id": "not-installed"})), Err("motion_not_available"));
    }

    /// 活动起停: the ids come from the same runnable list the host publishes.
    #[test]
    fn activity_start_and_stop_go_to_the_world_session_owner() {
        assert_eq!(wire(json!({"op": "stage.activity.run", "id": "life.coffee"})),
            json!({"op": "stage.activity.run", "id": "life.coffee"}));
        assert_eq!(wire(json!({"op": "stage.activity.stop"})), json!({"op": "stage.activity.stop"}));
        assert_eq!(route(json!({"op": "stage.activity.run", "id": "life.nothing"})), Err("activity_not_runnable"));
    }

    /// 管理角色与动作…: local window navigation, not a host op — and the
    /// navigation survives until `lib.rs` owns a window to apply it to.
    #[test]
    fn manage_assets_navigates_the_settings_window_locally() {
        assert!(!take_pending_presence_page(), "the flag starts clear");
        // The adapter classifies the op as local navigation and never puts it
        // on the wire: `lib.rs` is what opens/lands the window.
        assert_eq!(route(json!({"op": "settings.open.presence"})), Ok(SettingsRoute::PresenceSettings));
        PENDING_PRESENCE_PAGE.with(|pending| pending.set(true));
        // The window owner consumes the request exactly once; a stale
        // re-navigation on a later snapshot would be a second page switch.
        assert!(take_pending_presence_page());
        assert!(!take_pending_presence_page());
    }

    /// 许愿机保存/检测: the Unity wish-machine form is the `generation.*`
    /// surface (`UnityGenerationConfigurationBridge`), whose save guard accepts
    /// `[op, endpoint, token]` — so the UI's `apiKey` becomes `token` and a
    /// blank endpoint is refused by name.
    #[test]
    fn wish_machine_save_and_check_land_on_generation_not_space_prop() {
        assert_eq!(wire(json!({"op": "space.prop.save", "endpoint": "https://example.invalid", "apiKey": "k"})),
            json!({"op": "generation.save", "endpoint": "https://example.invalid", "token": "k"}));
        assert_eq!(wire(json!({"op": "space.prop.check", "endpoint": "https://example.invalid"})),
            json!({"op": "generation.check"}));
        assert_eq!(route(json!({"op": "space.prop.save", "endpoint": "  ", "apiKey": "k"})), Err("generation_endpoint_required"));
    }

    /// 检测连接 needs a *saved* configuration: `generation.check` reads the
    /// active configuration and its health probe, so an unconfigured machine
    /// must say so instead of querying nothing.
    #[test]
    fn wish_machine_check_refuses_when_nothing_is_saved() {
        let mut unconfigured = envelope();
        unconfigured["settings"]["generation"] = json!({"configured": false, "checking": false});
        let mut draft = None;
        assert_eq!(translate_settings_command(&json!({"op": "space.prop.check"}), &unconfigured, &mut draft),
            Err("generation_not_configured"));
    }

    /// 取消配置 is a **local edit cancel**. It never reaches a host op, so it
    /// cannot clear `generation.save`'s stored endpoint/token: the product host
    /// only stops the in-flight check and clears its notice
    /// (`ProductSettingsParity.swift:204-207`), and this window does even less.
    #[test]
    fn cancelling_a_configuration_is_local_and_cannot_erase_saved_credentials() {
        assert_eq!(route(json!({"op": "space.prop.cancel"})), Ok(SettingsRoute::LocalEditCancel));
        assert_eq!(route(json!({"op": "space.prop.cancel", "clearNotice": true})), Ok(SettingsRoute::LocalEditCancel));
        // The only credential-destroying op in this surface is an explicit
        // clear, which is not what the UI emits for a cancel.
        assert!(STAGE_OPS.iter().all(|op| *op != "generation.clear"));
    }

    /// The published whitelist is what makes the controls appear: without the
    /// `STAGE_OPS` half the UI would still hide all twelve (`supported_ops`
    /// gating), which is exactly the "hide it instead of wiring it" ending the
    /// report's §5.1 recorded.
    #[test]
    fn every_stage_op_is_published_and_a_disabled_one_hides_its_control() {
        let host = settings_supported_ops(&["settings.load".to_owned()]);
        for op in STAGE_OPS {
            assert!(host.iter().any(|candidate| candidate == op), "{op} must be published");
        }
        // Duplicate entries would be a double-add bug on the next snapshot.
        let mut sorted = host.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), host.len());
        // The gate itself still works: an op the window does not publish is a
        // hidden control, and the twelve are only visible because they are here.
        assert!(!host.iter().any(|candidate| candidate == "stage.not.published"));
    }

    /// Every stage op must have its own arm; falling through to the generic
    /// pass-through would put a UI-only op on the wire.
    #[test]
    fn no_stage_op_falls_through_the_translation() {
        let cases = [
            json!({"op": "stage.world.enter", "id": "world.living-pod"}),
            json!({"op": "stage.scene.activate", "id": "snow"}),
            json!({"op": "stage.avatar.position", "axis": "X", "value": 1.0}),
            json!({"op": "stage.avatar.reset"}),
            json!({"op": "stage.motion.refresh"}),
            json!({"op": "stage.motion.activate", "id": "gmgn.motion.wave"}),
            json!({"op": "stage.activity.run", "id": "life.coffee"}),
            json!({"op": "stage.activity.stop"}),
            json!({"op": "settings.open.presence"}),
            json!({"op": "space.prop.save", "endpoint": "https://example.invalid", "apiKey": "k"}),
            json!({"op": "space.prop.check"}),
            json!({"op": "space.prop.cancel"}),
        ];
        assert_eq!(cases.len(), STAGE_OPS.len(), "every published op needs a case here");
        for command in cases {
            let op = command["op"].as_str().unwrap().to_owned();
            assert!(STAGE_OPS.contains(&op.as_str()), "{op} missing from STAGE_OPS");
            let mut draft = None;
            let routed = translate_settings_command(&command, &envelope(), &mut draft)
                .unwrap_or_else(|code| panic!("{op} was refused: {code}"));
            // A UI op may keep its name only when a real host arm owns that
            // name; everything else has to be rewritten onto one.
            const NAMED_HOST_ARMS: [&str; 4] = [
                "stage.world.enter", "stage.scene.activate", "stage.activity.run", "stage.activity.stop",
            ];
            match routed {
                SettingsRoute::Host(wire) => assert!(
                    NAMED_HOST_ARMS.contains(&op.as_str()) || wire["op"].as_str() != Some(op.as_str()),
                    "{op} must be translated onto a production op, not forwarded as-is"),
                SettingsRoute::PresenceSettings | SettingsRoute::LocalEditCancel => {}
            }
        }
    }
}
